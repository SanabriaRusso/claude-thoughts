---
name: wrap-session
description: "Persist this session's high-signal knowledge (decisions, gotchas, lessons, cross-repo integration points, standing context) to the cross-repo Qdrant memory before the session ends. Invoke when the user signals the session is over: 'wrap the session', 'wrap up for today', 'I'm done', 'signing off', 'before I quit'. Do NOT invoke for wrapping up a task, PR or thread while the session continues, and never without such a signal. A caller without the conversation in context must pass a digest as the argument."
user-invocable: true
argument-hint: "[session digest — only when the caller lacks the conversation context]"
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/memory.sh *)
---

# Wrap Session — persist cross-repo memories before quitting

Persist what this session learned into the Qdrant `claude-memory` collection so future sessions in any repo can find it. The work is split: you survey and write; `${CLAUDE_SKILL_DIR}/scripts/memory.sh` does everything that must be deterministic (repo detection, dedup search with point IDs, secret scan, schema, store, verification, supersession).

Facts that shape every step:
- **The embedder reads only the first 128 tokens (≈350 characters) of a memory.** Everything after that is stored but never searched. Lead with the fact; put why/how after it.
- The MCP find tool returns no point IDs and cannot filter by repo; the script's `check` does both, so supersession is by ID and dedup is real.
- Qdrant memory `mcp-tools-loaded-at-session-start-only`: the script path works even when the MCP tools did not register this session.

## Step 0: Gate

Proceed only if one of these is true: the user signalled the session is ending (quit, done for today, wrap the session, signing off), the user typed `/wrap-session`, or a parent agent delegated this skill explicitly. "Wrap up this task/PR/thread" is not a session end: say so in one line and stop.

Repeat invocation in the same session: survey only what happened after the previous run, and skip Step 7.

## Step 1: Preflight (one call)

```
${CLAUDE_SKILL_DIR}/scripts/memory.sh preflight
```

It prints the detected repo (derived from `git rev-parse --git-common-dir`, so it is correct from worktrees), Qdrant health, the collection and its vector, point counts, today's memsearch capture file, whether `tasks/lessons.md` / `tasks/todo.md` exist, and a fresh `workdir`.

- Exit 2 means Qdrant is down or the collection is missing. Relay the printed message to the user and stop. Never skip storage silently; memsearch has still captured the per-repo record.
- Exit 3 means the interpreter is missing: tell the user to run `~/github/claude-thoughts/switch-backend.sh enable qdrant`, then stop.
- If `repo` is empty (not a git repo), ask the user which `repo` tag to use and set it on every candidate.

## Step 2: Survey

Sources, in this order:
1. This conversation.
2. `$ARGUMENTS`, when the caller passed a digest (an agent without the conversation in context).
3. Today's memsearch capture (path printed by preflight): the per-turn record, which survives context compaction. Read it when the conversation has been compacted or is long.
4. `tasks/lessons.md` and the Review section of `tasks/todo.md`, when present.

Keep items in these categories only. Be selective: quality over quantity.

| `category` | What it captures |
|---|---|
| `decision` | Chose approach X over Y, with the rationale |
| `gotcha` | Tool/API/config behaves unexpectedly under condition Z |
| `lesson` | The user corrected an approach; the rule and *why* |
| `integration` | This repo depends on / interacts with another repo or system in a non-obvious way |
| `context` | Standing constraints, deadlines, stakeholder asks future sessions need |
| `session-summary` | Only for Step 7 |

Skip: routine task summaries ("we edited file X"), code patterns visible from the repo, chit-chat, anything already in CLAUDE.md or the README. Those belong to memsearch or git.

Writing rule for `information`: a self-contained, third-person fact that stands alone without this conversation. First sentence states the fact and names the repo/tool/condition; the remaining sentences give why, how to apply, dates, PR numbers. No preambles such as "UPDATE (supersedes …)" — they waste the searchable window. One topic per memory; never bundle.

## Step 3: Draft `candidates.json`

Write the file with the **Write tool** (not a shell heredoc: the worktree guard inspects heredoc bodies) at `<workdir>/candidates.json`, where `<workdir>` is the path preflight printed. That directory is used because the session scratchpad path contains `-github-`, which the worktree guard can refuse as "names git".

```json
[
  {
    "information": "Lead with the fact. Then why and how to apply it.",
    "metadata": {
      "repo": "claude-thoughts",
      "topic": "kebab-case-slug",
      "category": "gotcha",
      "related_repos": ["other-repo"],
      "pr": ["https://github.com/org/repo/pull/123"],
      "supersedes": ["<point-id from check>"]
    }
  }
]
```

- `topic`: required, `^[a-z0-9][a-z0-9-]{2,60}$`. Reuse an existing topic only when superseding it.
- `category`: required, one of the table above.
- `repo`: optional; defaults to the preflight repo. A different value is allowed (a fact about another repo) and is flagged as a warning so you can confirm it.
- `date`: filled in by `store`. `related_repos`, `pr`, `supersedes`: optional lists. Any other key is a schema error.

## Step 4: Check, then curate

```
${CLAUDE_SKILL_DIR}/scripts/memory.sh check <workdir>/candidates.json
```

Per candidate it prints schema errors, secret-shaped text, the exact indexed prefix (what the embedder will see), the three nearest existing memories in the same repo and the nearest elsewhere as `score LABEL id topic date "snippet"`, and whether the topic already exists.

Curate the file:
- `DUPLICATE` (score ≥ 0.90): drop the candidate, or, if it adds facts, keep it and put that id in `supersedes` (reuse its topic).
- `OVERLAP` (0.70–0.90): decide. If the candidate refines or corrects that memory, add its id to `supersedes` and reuse the topic; if both are genuinely distinct facts, keep both.
- `SECRET`: replace the substring with `<REDACTED>` or drop the candidate. Never store the original.
- `SCHEMA ERROR`: fix it.
- Truncated prefix that does not state the fact: rewrite the opening.

Re-run `check` only if you changed `information` text substantially; `store` re-validates everything anyway.

## Step 5: Store

```
${CLAUDE_SKILL_DIR}/scripts/memory.sh store <workdir>/candidates.json
```

`store` re-runs the schema check, the secret scan and the neighbour search, then refuses with exit 4 (secret), 5 (schema or unknown `supersedes` id), 6 (a DUPLICATE not listed in that candidate's `supersedes`, or two near-identical candidates in the file) or 7 (this file already has a receipt: write a new file for new items). Otherwise it embeds, upserts, reads every new point back to verify its metadata, deletes the superseded points only after that, runs the null-metadata sweep, writes `candidates.receipt.json`, marks this session as stored, and prints the report table. Exit 8 means the sweep found stranded points: follow the printed repair instructions.

## Step 6: Final sweep

```
~/.claude/hooks/post-qdrant-store-verify.sh </dev/null
```

Exit 0 and no output means the collection is clean. Exit 2 prints the stranded points and the repair procedure (delete + re-store while the text is still in your context). This is the same hook that runs after every MCP store; running it by hand covers the script path.

## Step 7: Minimum-one-memory fallback

If Steps 2–4 leave zero candidates, store one memory with `category: session-summary` and topic `session-summary`: 2–4 sentences on what was worked on, what was decided, what is pending. Never end a session with nothing persisted. Skip on repeat invocations.

## Step 8: Report

Relay the table `store` printed (topic, category, id per stored memory; deleted superseded ids), add one line "memsearch captured the per-repo record automatically", and close with: "Session wrapped. Safe to quit."

## Running from an agent

- **Main agent with a long context:** delegate to a fork so the neighbour tables stay out of the main context: `Agent(subagent_type: "fork", prompt: "Run the wrap-session skill (Skill tool: wrap-session) and return its report")`. The fork inherits the conversation and the tool pool; relay its report to the user.
- **Agent without the conversation** (an OMC executor, a team member, a fresh subagent): the caller passes a digest as the argument (`$ARGUMENTS`), and Step 2 surveys that digest plus the memsearch capture.
- The UserPromptSubmit hook nudges the model when the user's prompt signals a session end, and the Stop hook blocks once per such signal if nothing was stored. Both only ask for this skill to run; neither stores anything.

## Hard rules

- **Never** store a memory without `repo`, `topic` and `category` (the script enforces it).
- **Never** bundle unrelated topics into one memory.
- **Never** silently skip when Qdrant is down: surface it.
- **Never** invent items that were not in the conversation or the digest. Use Step 7 if nothing high-signal happened.
- **Never** store secrets, credentials, tokens or PII.
- **Never** treat a store as done until `store` printed its table and the final sweep was clean.
- If the user says "don't store X", drop it and continue with the rest.
