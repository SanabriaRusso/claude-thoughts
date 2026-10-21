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
- `qdrant/hooks/` — SessionStart (health check + auto-recovery), UserPromptSubmit (session-end phrase → nudge to run `/wrap-session`), Stop (snapshot once per session; one block per session-end signal if nothing was stored), PostToolUse (verifies `qdrant-store` metadata); `tests/run.sh` drives them with JSON on stdin
- `skills/wrap-session/` — the `/wrap-session` skill: `SKILL.md`, `scripts/memory.py` (preflight | check | store: repo detection, dedup with point IDs, secret scan, verified stores, supersession), `tests/run.sh` (throwaway collection on the live Qdrant)
- `tests/switch-backend-hooks.sh` — hook wiring test for `switch-backend.sh` against a temp HOME
- `memsearch/setup.sh` — first-time install: pip package, ONNX model, Claude Code plugin
- `memsearch/hooks/` — SessionStart hook that symlinks `.memsearch/` in worktrees to the main repo's copy

## How the switch script works

It does three things per enable/disable:
1. Replaces the memory section in `~/.claude/CLAUDE.md` between HTML comment markers
2. Uses `jq` to add/remove hook entries in `~/.claude/settings.json` (Qdrant: SessionStart, UserPromptSubmit, Stop, PostToolUse; memsearch: SessionStart worktree symlink)
3. Calls `claude plugin enable/disable memsearch`

The CLAUDE.md section it injects tells Claude how to use whichever backends are active.

## When editing this repo

- Test `switch-backend.sh` changes against a copy of `~/.claude/CLAUDE.md` before running live
- The `ensure_markers` function handles first-run migration (wraps any existing memory section with markers)
- Qdrant hooks are referenced by their full path (`~/.claude/hooks/session-start-memory.sh`, `user-prompt-wrap-intent.sh`, `session-stop-memory.sh`, `post-qdrant-store-verify.sh`) in settings.json — if you rename them, update both the hook files and the jq selectors in the script
- `skills/wrap-session/scripts/memory.sh` runs on the `mcp-server-qdrant` uv tool interpreter (fastembed + the cached MiniLM model); the embedder truncates at 128 tokens, which is why the skill insists on fact-first memories
- Hook config is snapshotted when a Claude session starts: after `enable qdrant`, hook changes show up in the next session
- memsearch plugin is identified as `memsearch@memsearch-plugins` in settings.json
