# claude-thoughts

Infrastructure repo for Claude Code's persistent semantic memory layer.

## What this repo does

This repo manages two memory backends that give Claude Code persistent context across sessions:
- **memsearch** (per-repo, automatic) — plugin that auto-captures and auto-recalls via hooks
- **Qdrant** (cross-repo, manual) — vector DB + MCP server for explicit storage/search

Both run simultaneously by default. `switch-backend.sh` toggles each independently.

## Key files

- `switch-backend.sh` — the main control script. Patches `~/.claude/CLAUDE.md` and `~/.claude/settings.json`
- `both/CLAUDE-memory.md` — injected into CLAUDE.md when both backends are active
- `qdrant/CLAUDE-memory.md` — injected when Qdrant-only
- `memsearch/CLAUDE-memory.md` — injected when memsearch-only
- `qdrant/compose.yaml` — Qdrant v1.17.1 container definition
- `qdrant/hooks/` — SessionStart (health check + auto-recovery) and Stop (mandatory store reminder)
- `memsearch/setup.sh` — first-time install: pip package, ONNX model, Claude Code plugin

## How the switch script works

It does three things per enable/disable:
1. Replaces the memory section in `~/.claude/CLAUDE.md` between HTML comment markers
2. Uses `jq` to add/remove Qdrant hook entries in `~/.claude/settings.json`
3. Calls `claude plugin enable/disable memsearch`

The CLAUDE.md section it injects tells Claude how to use whichever backends are active.

## When editing this repo

- Test `switch-backend.sh` changes against a copy of `~/.claude/CLAUDE.md` before running live
- The `ensure_markers` function handles first-run migration (wraps any existing memory section with markers)
- Qdrant hooks are referenced by their full path (`~/.claude/hooks/session-start-memory.sh`) in settings.json — if you rename them, update both the hook files and the jq selectors in the script
- memsearch plugin is identified as `memsearch@memsearch-plugins` in settings.json
