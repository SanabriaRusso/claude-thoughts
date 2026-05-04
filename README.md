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

## `/wrap-session` skill

The Stop hook emits a *reminder* to store memories before quitting, but reminders are best-effort — Claude may have already decided to stop by the time the hook fires, and the structure/metadata of what gets stored varies session-to-session.

`/wrap-session` is the deterministic, user-triggered counterpart. Invoke it explicitly **before quitting** any session in any repo:

```
/wrap-session
```

What it does:
1. Detects the current repo via `git rev-parse --show-toplevel` and uses the basename as the `repo` tag.
2. Verifies Qdrant is reachable (aborts with a clear message if not — memsearch still captures locally).
3. Surveys the conversation for architecture decisions, gotchas, lessons, integration points, and standing project context.
4. Deduplicates each candidate against existing memories via `mcp__claude-memory__qdrant-find`.
5. Stores each kept item via `mcp__claude-memory__qdrant-store` with mandatory `{repo, topic}` metadata.
6. Falls back to a single session-summary memory if nothing high-signal happened.
7. Reports a compact summary table of what was stored and what was skipped as duplicate.

The skill ships in this repo at `skills/wrap-session/SKILL.md` and is installed as a snapshot to `~/.claude/skills/wrap-session/` whenever Qdrant is enabled. Re-run `./switch-backend.sh enable qdrant` after editing the skill to refresh the deployed copy.

The Stop-hook reminder remains active as a fallback for sessions where you forget to run `/wrap-session`.

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
  hooks/                    Session hooks (copied to ~/.claude/hooks/ on activation)
  CLAUDE-memory.md          Memory section for Qdrant-only mode
  README.md                 Qdrant setup guide
memsearch/
  setup.sh                  First-time installation (pip + plugin + ONNX model)
  hooks/                    SessionStart hook for worktree symlink unification
  CLAUDE-memory.md          Memory section for memsearch-only mode
  README.md                 memsearch setup guide
skills/
  wrap-session/
    SKILL.md                User-invocable /wrap-session — persists high-signal items to Qdrant before quitting (deployed to ~/.claude/skills/ when Qdrant is enabled)
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
| `~/.claude/settings.json` | Qdrant hook entries under `.hooks.SessionStart` and `.hooks.Stop` |
| `~/.claude/hooks/session-{start,stop}-memory.sh` | Copied from `qdrant/hooks/` when Qdrant is enabled |
| `~/.claude/hooks/session-start-memsearch-worktree.sh` | Copied from `memsearch/hooks/` when memsearch is enabled |
| `~/.claude/skills/wrap-session/` | Snapshot of `skills/wrap-session/` copied here when Qdrant is enabled |
| `~/.claude.json` | `claude-rag` MCP server entry (when RAG is enabled) |
| memsearch plugin state | Toggled via `claude plugin enable/disable` |
