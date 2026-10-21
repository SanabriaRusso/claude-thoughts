# claude-thoughts

Persistent semantic memory and document retrieval for Claude Code. Two memory backends plus a RAG pipeline for ingesting reference documents.

## How it works

| | memsearch | Qdrant | RAG |
|---|-----------|--------|-----|
| **Role** | Per-repo auto-capture | Cross-repo global store | Document retrieval |
| **Capture** | Automatic (Stop hook) | Manual (MCP tool calls) | CLI ingestion |
| **Recall** | Automatic (context injection) | Manual (MCP search) | Manual (MCP search) |
| **Storage** | Markdown files + Milvus Lite | Podman volume (vector DB) | Podman volume (vector DB) |
| **Embeddings** | ONNX bge-m3 (~558MB, local) | fastembed MiniLM (~30MB, local) | fastembed nomic-embed (768d, local) |
| **Infra** | None (plugin) | Podman container | Podman container (shared Qdrant) |

**memsearch** captures every session automatically and recalls relevant context on each prompt. **Qdrant** stores high-signal items (architecture decisions, gotchas, cross-repo knowledge) explicitly via MCP, searchable across all projects. **RAG** makes ingested reference documents (books, papers, guides) searchable — see [rag/README.md](rag/README.md).

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Claude Code Session                        │
│                                                                     │
│  ┌───────────────────────────────┐  ┌────────────────────────────┐  │
│  │     memsearch (automatic)     │  │     Qdrant (manual)        │  │
│  │         per-repo scope        │  │     cross-repo scope       │  │
│  └──────────┬────────────────────┘  └──────────┬─────────────────┘  │
└─────────────┼───────────────────────────────────┼───────────────────┘
              │                                   │
     ┌────────┴────────┐                 ┌────────┴────────┐
     │  CAPTURE         │                │  CAPTURE         │
     │  Stop hook       │                │  MCP tool call   │
     │  (auto on each   │                │  (explicit by    │
     │   response)      │                │   Claude)        │
     └────────┬─────────┘                └────────┬─────────┘
              │                                   │
              │ Haiku summarizes                  │ fastembed encodes
              │ response → bullets                │ text → vectors
              │                                   │
     ┌────────▼─────────┐                ┌────────▼─────────┐
     │  STORAGE          │                │  STORAGE          │
     │                   │                │                   │
     │  .memsearch/      │                │  Qdrant container │
     │  memory/          │                │  (podman)         │
     │  YYYY-MM-DD.md    │                │                   │
     │       +           │                │  Collection:      │
     │  Milvus Lite      │                │  claude-memory    │
     │  (vector index)   │                │  (vector DB)      │
     └────────┬─────────┘                └────────┬─────────┘
              │                                   │
              │ bge-m3 ONNX                       │ fastembed
              │ (~558 MB, local)                  │ (~30 MB, local)
              │                                   │
     ┌────────▼─────────┐                ┌────────▼─────────┐
     │  RECALL           │                │  RECALL           │
     │                   │                │                   │
     │  Auto: top-3      │                │  SessionStart     │
     │  memories injected│                │  hook: health     │
     │  into context     │                │  check + recovery │
     │                   │                │                   │
     │  Manual:          │                │  Manual:          │
     │  /memory-recall   │                │  qdrant-find      │
     │  <query>          │                │  MCP search       │
     └──────────────────┘                └──────────────────┘

─────────────────────── Control plane ───────────────────────

     ┌──────────────────────────────────────────────────┐
     │              switch-backend.sh                    │
     │                                                   │
     │  Patches three things per enable/disable:         │
     │                                                   │
     │  1. ~/.claude/CLAUDE.md                           │
     │     Memory instructions between markers           │
     │                                                   │
     │  2. ~/.claude/settings.json                       │
     │     SessionStart + Stop hooks (Qdrant + worktree) │
     │                                                   │
     │  3. memsearch plugin                              │
     │     claude plugin enable/disable                  │
     │                                                   │
     │  4. ~/.claude.json (RAG only)                     │
     │     MCP server "claude-rag" entry                 │
     └──────────────────────────────────────────────────┘
```

## Quick start

### Both backends (recommended)

```bash
# 1. Install memsearch plugin
./memsearch/setup.sh

# 2. Start Qdrant
cd qdrant && podman compose up -d && cd ..
./switch-backend.sh enable qdrant
```

Configure the Qdrant MCP server — see [qdrant/README.md](qdrant/README.md).

### Add document RAG

```bash
# Requires Qdrant to be running (see above)
./rag/setup.sh
./rag/ingest add ~/books/my-book.pdf --title "Book Title" --topic "subject"
```

See [rag/README.md](rag/README.md) for details.

### memsearch only

```bash
./memsearch/setup.sh
```

### Qdrant only

```bash
cd qdrant && podman compose up -d && cd ..
./switch-backend.sh enable qdrant
./switch-backend.sh disable memsearch
```

## Managing backends

```bash
./switch-backend.sh status              # show what's on
./switch-backend.sh enable  qdrant      # turn on Qdrant memory
./switch-backend.sh disable qdrant      # turn off Qdrant memory
./switch-backend.sh enable  memsearch   # turn on memsearch
./switch-backend.sh disable memsearch   # turn off memsearch
./switch-backend.sh enable  rag         # turn on document RAG
./switch-backend.sh disable rag         # turn off document RAG
```

The switch script manages per backend:
- **CLAUDE.md** — patches `~/.claude/CLAUDE.md` with the appropriate instructions
- **Qdrant hooks** — adds/removes SessionStart and Stop hooks in `~/.claude/settings.json`
- **memsearch plugin** — enables/disables the Claude Code plugin
- **RAG MCP server** — adds/removes `claude-rag` entry in `~/.claude.json`

Restart Claude Code after switching.

## Disk usage: keep uvx off the hot path

Every Python component here (memsearch, the `claude-memory` and `claude-rag` MCP servers)
must run from an installed binary, never through `uvx`. Otherwise `~/.cache/uv/archive-v0`
grows without bound: one machine reached 160 GB and filled its disk.

**Why it grows.** Each `uvx` run uses a cached environment. When a dependency changes,
uvx builds a new one (~400 MB for these packages) and keeps the old one. Two things here
run through uvx unless you prevent it:

- **memsearch hooks** look for `memsearch` on `PATH`. If it isn't there, they fall back to
  `uvx --upgrade --from 'memsearch[onnx]' memsearch`, which re-resolves on every session start.
- **Qdrant MCP servers** registered as `uvx mcp-server-qdrant` start two uvx processes
  per Claude session.

**Why you can't just prune.** A running `uvx` process holds `~/.cache/uv/.lock` for its whole
lifetime. While any Claude session has a uvx-launched MCP server open, `uv cache prune`
waits 300 s and then fails with `Timeout ... waiting for lock`.

**Check:**

```bash
./switch-backend.sh status        # warns about uvx/npx MCP entries and memsearch missing from PATH
du -sh ~/.cache/uv/archive-v0
lsof ~/.cache/uv/.lock            # which processes hold the cache lock
```

**Fix:**

```bash
uv tool install "memsearch[onnx]"             # memsearch/setup.sh does this
./switch-backend.sh enable qdrant             # rewrites a uvx/npx claude-memory entry
./switch-backend.sh enable rag                # rewrites a uvx/npx claude-rag entry
```

Both `enable` commands install `mcp-server-qdrant` as a uv tool and point the MCP entry at
its absolute path. They leave the entry's `env` untouched.

**Reclaim space:** restart every Claude session started before the fix so the old uvx
processes exit, then run `uv cache prune`. It removes only unreferenced entries.
`uv cache prune --force` skips the lock check, but it can delete environments that
still-running old sessions use; reconnect those with `/mcp`. `uv cache clean` wipes the
whole cache. That is safe for project venvs and `uv tool` installs, but everything gets
downloaded again.

## `/wrap-session` skill

Persists this session's high-signal knowledge (decisions, gotchas, lessons, cross-repo integration points, standing context) to the cross-repo `claude-memory` collection. Three ways to trigger it:

- **Say the session is ending** — "let's wrap the session", "done for today", "signing off". The UserPromptSubmit hook nudges Claude, and the skill is model-invocable, so Claude runs it, or delegates it to a fork subagent that inherits the conversation.
- **Type `/wrap-session`** yourself.
- **From an agent without the conversation** — `/wrap-session <digest>`; the digest is surveyed in place of the conversation.

What happens (`skills/wrap-session/SKILL.md` drives `scripts/memory.py`):

1. **Preflight** (`memory.sh preflight`): repo name from `git rev-parse --git-common-dir` (correct inside worktrees), Qdrant health, collection and vector check, point counts, today's memsearch capture, a scratch `workdir`.
2. **Survey**: the conversation, the caller's digest, today's `.memsearch/memory/<date>.md` (the per-turn record, which survives context compaction), `tasks/lessons.md`.
3. **Draft** `candidates.json` with `{information, metadata: {repo, topic, category, related_repos?, pr?, supersedes?}}`. Unknown metadata keys are rejected.
4. **Check** (`memory.sh check`): schema, secret scan, the exact indexed prefix, and the nearest existing memories with point IDs and scores — `DUPLICATE` at ≥ 0.90, `OVERLAP` at ≥ 0.70. Claude drops duplicates or lists what the new memory supersedes.
5. **Store** (`memory.sh store`): re-validates, embeds with the same MiniLM model the MCP server uses, upserts, reads every point back, deletes superseded points only after that, sweeps for null metadata, writes a receipt, marks the session as stored.
6. **Final sweep** with `post-qdrant-store-verify.sh`, the report table, "Session wrapped. Safe to quit."

Why a script: the MCP find tool returns no point IDs and cannot filter by repo, so dedup used to be ID-less and supersession text-only (stale and current memories surfaced together). And the embedder reads only the **first 128 tokens (≈350 characters)** of a memory — everything after that is stored but never searched — so `check` shows exactly what will be searchable and the skill insists on fact-first memories. `memory.sh` runs on the interpreter of the `mcp-server-qdrant` uv tool install: no new dependency, never uvx, and it works even when the MCP tools failed to register at session start.

Tests: `bash skills/wrap-session/tests/run.sh` (throwaway collection on the live Qdrant; it refuses to touch `claude-memory` and asserts the live point count is unchanged).

The skill is installed as a snapshot to `~/.claude/skills/wrap-session/` by `./switch-backend.sh enable qdrant`. Re-run that after editing it.

### Hooks

Installed to `~/.claude/hooks/` and wired into `~/.claude/settings.json` by `enable qdrant`; removed by `disable qdrant`.

| Hook | Event | What it does |
|---|---|---|
| `session-start-memory.sh` | SessionStart | Health-checks Qdrant, auto-recovers the container, reminds Claude to search |
| `user-prompt-wrap-intent.sh` | UserPromptSubmit | Detects session-end phrases, arms the Stop check, nudges Claude to run `/wrap-session` |
| `session-stop-memory.sh` | Stop | Snapshots Qdrant once per session; blocks once per session-end signal if nothing was stored since |
| `post-qdrant-store-verify.sh` | PostToolUse on `qdrant-store` | Detects stores that stranded their metadata; marks the session as stored |

Hooks nudge, they never store. Markers live in `/tmp/.claude-memory-*` (override with `CLAUDE_MEMORY_MARKER_DIR`) and are pruned after 7 days. Hook config is snapshotted when a session starts, so changes apply to the next session. Tests: `bash qdrant/hooks/tests/run.sh` and `bash tests/switch-backend-hooks.sh`.

## Worktree support

memsearch stores memories in `.memsearch/` at the repo root. By default, each git worktree gets its own independent copy — meaning memories are lost when the worktree is deleted.

A **SessionStart hook** solves this automatically. On every session launch, if Claude is running inside a git worktree, the hook:

1. Detects the worktree by comparing `git rev-parse --git-common-dir` with the current toplevel
2. Merges any existing local `.memsearch/memory/*.md` files into the main worktree's `.memsearch/`
3. Replaces the local `.memsearch/` with a symlink to the main worktree's copy

After this, all worktrees of a repo share one memory store. Creating and deleting worktrees freely has no effect on memory.

The hook is installed automatically when memsearch is enabled:

```bash
./switch-backend.sh enable memsearch   # installs plugin + worktree hook
./switch-backend.sh disable memsearch  # removes both
```

No manual setup needed. The hook is idempotent — it no-ops if already symlinked or if not in a worktree.

## Structure

```
switch-backend.sh           Manage backends independently
both/
  CLAUDE-memory.md          Memory section for dual mode (injected into CLAUDE.md)
qdrant/
  compose.yaml              Podman compose for Qdrant v1.17.1
  hooks/                    SessionStart, UserPromptSubmit, Stop and PostToolUse hooks (copied to ~/.claude/hooks/ on activation)
  hooks/tests/run.sh        Hook tests (JSON on stdin, temp marker dir)
  CLAUDE-memory.md          Memory section for Qdrant-only mode
  README.md                 Qdrant setup guide
memsearch/
  setup.sh                  First-time installation (pip + plugin + ONNX model)
  hooks/                    SessionStart hook for worktree symlink unification
  CLAUDE-memory.md          Memory section for memsearch-only mode
  README.md                 memsearch setup guide
skills/
  wrap-session/
    SKILL.md                /wrap-session — model- and user-invocable; persists high-signal items to Qdrant before quitting (deployed to ~/.claude/skills/ when Qdrant is enabled)
    scripts/memory.py       preflight | check | store — repo detection, dedup with point IDs, secret scan, verified stores, supersession
    scripts/memory.sh       Runs memory.py on the mcp-server-qdrant uv tool interpreter
    tests/run.sh            End-to-end tests against a throwaway collection
tests/
  switch-backend-hooks.sh   Hook wiring test for switch-backend.sh (temp HOME)
rag/
  ingest                    CLI wrapper (containerized ingestion)
  ingest.py                 Ingestion pipeline (runs inside container)
  Containerfile             Container image definition
  requirements.txt          Python dependencies
  setup.sh                  Build image + enable backend
  CLAUDE-rag.md             RAG instructions (injected into CLAUDE.md)
  README.md                 RAG documentation
```

## What gets patched on your system

| File | What changes |
|------|-------------|
| `~/.claude/CLAUDE.md` | Memory section between `<!-- MEMORY-BACKEND-START/END -->` markers |
| `~/.claude/CLAUDE.md` | RAG section between `<!-- RAG-BACKEND-START/END -->` markers |
| `~/.claude/settings.json` | Qdrant hook entries under `.hooks.SessionStart`, `.hooks.UserPromptSubmit`, `.hooks.Stop` and `.hooks.PostToolUse` |
| `~/.claude/hooks/{session-start-memory,user-prompt-wrap-intent,session-stop-memory,post-qdrant-store-verify,snapshot-qdrant}.sh` | Copied from `qdrant/hooks/` when Qdrant is enabled |
| `/tmp/.claude-memory-*` | Hook marker files (snapshot, wrap-intent, wrap-blocked, stored), pruned after 7 days; override the directory with `CLAUDE_MEMORY_MARKER_DIR` |
| `~/.claude/hooks/session-start-memsearch-worktree.sh` | Copied from `memsearch/hooks/` when memsearch is enabled |
| `~/.claude/skills/wrap-session/` | Snapshot of `skills/wrap-session/` copied here when Qdrant is enabled |
| `~/.claude.json` | `claude-rag` MCP server entry (when RAG is enabled); `claude-memory`/`claude-rag` entries launched via uvx/npx are repointed at the installed binary on `enable` |
| `~/.local/bin/mcp-server-qdrant` | Installed with `uv tool install` on `enable qdrant` and `enable rag`; its Python environment also runs the wrap-session scripts |
| memsearch plugin state | Toggled via `claude plugin enable/disable` |
