---
name: wrap-session
description: "Use when the user is about to end a Claude Code session and wants high-signal items from the conversation persisted to the cross-repo Qdrant memory. Surveys the conversation for architecture decisions, gotchas, lessons, and integration points; deduplicates against existing memories; stores each kept item via mcp__claude-memory__qdrant-store with {repo, topic} metadata; and reports what was stored. Invoke explicitly via /wrap-session before quitting; the Stop-hook reminder remains as a fallback."
user-invocable: true
disable-model-invocation: true
---

# Wrap Session — Persist Cross-Repo Memories Before Quitting

You have been asked to wrap up the session by persisting high-signal knowledge from this conversation into the Qdrant memory store. This is the deterministic, user-triggered counterpart to the Stop-hook reminder.

## Step 1: Preflight

1. Detect the current repo (must work correctly from git worktrees):
   - Run `git rev-parse --git-common-dir`. This always points at the **main repo's** `.git` directory regardless of whether you're in a worktree (in a worktree, `--show-toplevel` would return the worktree path and yield the wrong basename).
   - Take `basename(dirname(<git-common-dir>))` as `<repo-name>`. In bash:
     ```bash
     repo_name=$(basename "$(dirname "$(cd "$(git rev-parse --git-common-dir)" && pwd)")")
     ```
   - Example from a worktree at `/Users/foo/claude-thoughts/.claude/worktrees/skills/`:
     - `--git-common-dir` → `/Users/foo/claude-thoughts/.git`
     - `dirname` → `/Users/foo/claude-thoughts`
     - `basename` → `claude-thoughts` ✓ (not `skills`)
   - If not in a git repo, ask the user for a `repo` tag to use, or abort.
2. Check Qdrant is reachable: `curl -sf http://localhost:6333/healthz`.
   - If it fails, abort with a clear message: "Qdrant is down — memories cannot be stored. memsearch (per-repo) has still captured locally. Run `~/github/claude-thoughts/switch-backend.sh status` or restart the container, then re-invoke /wrap-session."
   - Do NOT silently skip storage.
3. Confirm the target collection exists: `curl -sf http://localhost:6333/collections/claude-memory`.
   - If the response indicates the collection is missing, abort with: "Collection `claude-memory` does not exist on the Qdrant instance. Check `mcp__claude-memory__qdrant-find` MCP server config or restore from `~/qdrant-dumps/`."
   - Failing fast in preflight is preferred over per-store errors later.
4. **Repeat-invocation check**: if you have already run /wrap-session earlier in this same conversation, only survey items that were introduced AFTER the previous run. Skip Step 5 (fallback) on repeat invocations — never append a second session-summary memory.

## Step 2: Survey the conversation

Review THIS conversation (not git history, not external sources) for items in these categories. Be selective — quality over quantity.

| Category | Examples |
|----------|----------|
| **Architecture decision** | Chose approach X over Y, with rationale |
| **Gotcha / non-obvious behavior** | Tool/API/config behaves unexpectedly under condition Z |
| **Lesson from correction** | User corrected an approach; capture the rule and *why* |
| **Cross-repo integration point** | This repo depends on / interacts with another repo or external system in a non-obvious way |
| **Project context** | Standing constraints, deadlines, stakeholder asks that future sessions need |

Skip the following — they belong in memsearch or git, not Qdrant:
- Routine task summaries ("we edited file X")
- Code patterns visible from reading the repo
- Conversation chit-chat or repeated questions
- Anything already documented in CLAUDE.md or the repo's README

## Step 3: Deduplicate

For EACH candidate memory, before storing:
1. Call `mcp__claude-memory__qdrant-find` with a short natural-language query summarizing the candidate's gist.
2. If a near-duplicate already exists for the same `repo` and `topic`, skip the candidate (or merge by storing a refined version that supersedes the old one — note the supersession in the new memory's text).
3. If no duplicate, proceed to Step 4.

## Step 4: Store

**Before each store call, scrub the candidate `information` text for secrets.** Drop the candidate (or redact the offending substring) if it contains anything matching:
- API key shapes: `sk-`, `pk_`, `xoxb-`, `xoxp-`, `ghp_`, `ghs_`, `glpat-`, AWS access keys (`AKIA[0-9A-Z]{16}`), Google API keys (`AIza[0-9A-Za-z\-_]{35}`)
- Auth headers: `Bearer `, `Authorization:`, `Basic [A-Za-z0-9+/=]{20,}`
- Credential assignments: `password=`, `token=`, `secret=`, `api_key=`, `apikey=`
- Private key markers: `BEGIN PRIVATE KEY`, `BEGIN RSA`, `BEGIN OPENSSH`
- Connection strings carrying credentials: `://user:password@`, `mongodb://...:...@`, `postgres://...:...@`

If a candidate is otherwise high-signal but contains a secret-shaped substring, redact the substring (replace with `<REDACTED>`) and store the redacted version. Never store the original.

For each kept candidate, call `mcp__claude-memory__qdrant-store` with:

- **`information`**: a self-contained, third-person fact. Future sessions have NO conversation context — the memory must stand alone. Include the *why* for decisions and rules. One distinct topic per memory; never bundle.
- **`metadata`**: `{"repo": "<repo-name>", "topic": "<short-area-label>"}`
  - `repo` is mandatory and must match the basename detected in Step 1.
  - `topic` is mandatory: short kebab/lower form (e.g. `auth-middleware`, `qdrant-snapshots`, `ci-pipeline`).

### Examples of well-formed memories

> **information**: "In claude-thoughts, the Stop hook at `qdrant/hooks/session-stop-memory.sh` only emits a reminder — it does not deterministically store memories. The /wrap-session skill is the canonical user-triggered path. Why: hook fires after the model has already decided to stop, so the reminder is best-effort."
> **metadata**: `{"repo": "claude-thoughts", "topic": "session-stop-hook"}`

> **information**: "When ingesting RAG documents into the shared Qdrant container, the `claude-rag` collection uses `nomic-embed-text-v1.5` (768d) while `claude-memory` uses MiniLM (384d). Mixing collections will fail dimension checks. Why: discovered when an early prototype tried to share embeddings across both."
> **metadata**: `{"repo": "claude-thoughts", "topic": "rag-embeddings"}`

## Step 5: Fallback — minimum-one-memory

If after Steps 2–3 you have ZERO candidates worth storing, store ONE short session-summary memory instead. This matches the existing Stop-hook policy: never end a session with nothing persisted.

- **information**: 2–4 sentences: what was worked on, what was decided, what's pending.
- **metadata**: `{"repo": "<repo-name>", "topic": "session-summary"}`

## Step 6: Report

Print a compact summary table to the user:

```
Stored to Qdrant (collection: claude-memory)
─────────────────────────────────────────────
N stored  |  M skipped (duplicates)
─────────────────────────────────────────────
✓ topic-1                 — one-line gist
✓ topic-2                 — one-line gist
↷ topic-3 (duplicate)     — one-line gist
─────────────────────────────────────────────
```

Then a single closing line, e.g. "Session wrapped. Safe to quit."

## Hard rules

- **Never** store a memory without both `repo` and `topic` metadata.
- **Never** bundle multiple unrelated topics into one memory.
- **Never** silently skip when Qdrant is down — surface it.
- **Never** invent items that weren't actually in the conversation. If nothing high-signal happened, use Step 5's fallback.
- **Never** store secrets, credentials, tokens, or PII.
- The user can interrupt at any time; if they say "don't store X", drop it and continue with the rest.
