# Plan: Add memsearch as Alternative Memory Backend

## Context

The `claude-thoughts` repo currently hosts a Qdrant-based memory stack (compose.yaml + hooks + MCP server). The user evaluated alternatives and chose **memsearch** (by Zilliz) as the primary memory backend going forward. memsearch is a Python package that uses local ONNX embeddings, Milvus Lite, and stores memories as daily markdown files — zero containers needed.

**Goal:** Restructure the repo so both backends coexist in isolation, then activate memsearch.

## Implementation

### Phase 1 — Restructure repo for isolation

Create subdirectories for each backend. Move existing Qdrant files.

| Action | From | To |
|--------|------|----|
| mkdir | — | `qdrant/`, `qdrant/hooks/`, `memsearch/` |
| move | `compose.yaml` | `qdrant/compose.yaml` |
| create | — | `qdrant/README.md` (extracted from current root README) |
| copy | `~/.claude/hooks/session-start-memory.sh` | `qdrant/hooks/session-start-memory.sh` |
| copy | `~/.claude/hooks/session-stop-memory.sh` | `qdrant/hooks/session-stop-memory.sh` |
| update | `qdrant/hooks/session-start-memory.sh` | Change `COMPOSE_DIR` to `$HOME/github/claude-thoughts/qdrant` |
| create | — | `qdrant/CLAUDE-memory.md` (Qdrant-specific memory section for CLAUDE.md) |

### Phase 2 — Add memsearch backend

| File | Purpose |
|------|---------|
| `memsearch/README.md` | Setup guide for memsearch |
| `memsearch/setup.sh` | Installation script: pip install, configure ONNX, model warmup |
| `memsearch/CLAUDE-memory.md` | memsearch-specific memory section for CLAUDE.md |

**`memsearch/setup.sh` logic:**
1. Install `memsearch[onnx]` via pip/pipx/uv (whichever available)
2. Set embedding provider to onnx: `memsearch config set embedding.provider onnx`
3. Attempt Claude Code plugin install: `claude plugin marketplace add zilliztech/memsearch && claude plugin install memsearch` (with graceful fallback if `/plugin` commands don't exist yet)
4. Pre-warm ONNX model (~558MB one-time download)
5. Call `switch-backend.sh memsearch`

### Phase 3 — Switching mechanism

**`switch-backend.sh`** at repo root. Takes one arg: `qdrant` or `memsearch`.

Does three things:
1. **Patches `~/.claude/CLAUDE.md`** — replaces the memory section (lines 45-72, between `## Semantic Memory` and `## General Preferences`) with the selected backend's `CLAUDE-memory.md` content. Uses HTML comment markers (`<!-- MEMORY-BACKEND-START/END -->`) for reliable replacement.
2. **Toggles Qdrant hooks in `~/.claude/settings.json`** — uses `jq` to add/remove the SessionStart and Stop hook entries that reference `session-start-memory.sh` / `session-stop-memory.sh`.
3. **Toggles memsearch plugin** — `claude plugin enable/disable memsearch` if the plugin command exists, otherwise no-op (memsearch's hooks won't fire without the plugin).
4. **Writes `.active-backend`** file at repo root for reference.

**Hook coexistence:** Qdrant hooks live in `~/.claude/settings.json` as manually registered commands. memsearch hooks live inside the plugin system. The switch script ensures only one set is active at a time.

### Phase 4 — Update shared files

- **Root `README.md`** — rewrite as overview of both backends + comparison table + switching instructions
- **`.gitignore`** — add `.memsearch/`, `*.db`, `.active-backend`

### Phase 5 — Activate memsearch (runtime)

This phase involves running commands on the user's system:
1. Run `memsearch/setup.sh` to install memsearch
2. The setup script calls `switch-backend.sh memsearch` which patches CLAUDE.md and removes Qdrant hooks
3. User restarts Claude Code to pick up changes

## Critical files

| File | Status | Notes |
|------|--------|-------|
| `qdrant/compose.yaml` | moved | From root `compose.yaml` |
| `qdrant/hooks/session-start-memory.sh` | new | Updated COMPOSE_DIR path |
| `qdrant/hooks/session-stop-memory.sh` | new | Reference copy from `~/.claude/hooks/` |
| `qdrant/README.md` | new | Qdrant-specific setup guide |
| `qdrant/CLAUDE-memory.md` | new | Qdrant memory section with markers |
| `memsearch/setup.sh` | new | Installation + config script |
| `memsearch/README.md` | new | memsearch setup guide |
| `memsearch/CLAUDE-memory.md` | new | memsearch memory section with markers |
| `switch-backend.sh` | new | Backend switching orchestrator |
| `README.md` | rewritten | Overview of both backends |
| `.gitignore` | updated | Add memsearch patterns |
| `~/.claude/CLAUDE.md` | patched | Memory section gets markers + memsearch content |
| `~/.claude/settings.json` | patched | Qdrant hooks removed when memsearch active |

## Verification

1. `ls qdrant/` shows compose.yaml, hooks/, README.md, CLAUDE-memory.md
2. `ls memsearch/` shows setup.sh (executable), README.md, CLAUDE-memory.md
3. `cat .active-backend` shows `memsearch` after activation
4. `grep MEMORY-BACKEND ~/.claude/CLAUDE.md` shows markers present
5. `jq '.hooks' ~/.claude/settings.json` shows no memory hooks (memsearch mode)
6. `./switch-backend.sh qdrant` restores Qdrant hooks and CLAUDE.md section
7. `./switch-backend.sh memsearch` removes them again
8. After restart, new Claude Code session captures memories to `.memsearch/memory/`
