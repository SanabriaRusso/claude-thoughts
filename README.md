# claude-thoughts

Persistent semantic memory for Claude Code. Two backends, both on by default.

## How it works

| | memsearch | Qdrant |
|---|-----------|--------|
| **Role** | Per-repo auto-capture | Cross-repo global store |
| **Capture** | Automatic (Stop hook) | Manual (MCP tool calls) |
| **Recall** | Automatic (context injection) | Manual (MCP search) |
| **Storage** | Markdown files + Milvus Lite | Podman volume (vector DB) |
| **Embeddings** | ONNX bge-m3 (~558MB, local) | fastembed (~30MB, local) |
| **Infra** | None (plugin) | Podman container |
| **License** | MIT | Apache-2.0 |

**memsearch** captures every session automatically and recalls relevant context on each prompt. **Qdrant** stores high-signal items (architecture decisions, gotchas, cross-repo knowledge) explicitly via MCP, searchable across all projects.

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
     │     SessionStart + Stop hooks for Qdrant          │
     │                                                   │
     │  3. memsearch plugin                              │
     │     claude plugin enable/disable                  │
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
./switch-backend.sh enable  qdrant      # turn on Qdrant
./switch-backend.sh disable qdrant      # turn off Qdrant
./switch-backend.sh enable  memsearch   # turn on memsearch
./switch-backend.sh disable memsearch   # turn off memsearch
```

The switch script manages three things per backend:
- **CLAUDE.md** — patches `~/.claude/CLAUDE.md` with the appropriate memory section (dual, single, or disabled)
- **Qdrant hooks** — adds/removes SessionStart and Stop hooks in `~/.claude/settings.json`
- **memsearch plugin** — enables/disables the Claude Code plugin

Restart Claude Code after switching.

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
  CLAUDE-memory.md          Memory section for memsearch-only mode
  README.md                 memsearch setup guide
```

## What gets patched on your system

| File | What changes |
|------|-------------|
| `~/.claude/CLAUDE.md` | Memory section between `<!-- MEMORY-BACKEND-START/END -->` markers |
| `~/.claude/settings.json` | Qdrant hook entries under `.hooks.SessionStart` and `.hooks.Stop` |
| `~/.claude/hooks/session-{start,stop}-memory.sh` | Copied from `qdrant/hooks/` when Qdrant is enabled |
| memsearch plugin state | Toggled via `claude plugin enable/disable` |
