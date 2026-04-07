# claude-thoughts

Persistent semantic memory for Claude Code. Two backends, one switch.

## Backends

| | Qdrant | memsearch |
|---|--------|-----------|
| **Type** | Vector DB (container) | Python plugin (local) |
| **Infra** | Podman/Docker | None |
| **Embeddings** | fastembed (~30MB) | ONNX bge-m3 (~558MB) |
| **Storage** | Podman volume | Markdown files + Milvus Lite |
| **Capture** | Manual (MCP tool calls) | Automatic (Stop hook) |
| **Recall** | Manual (MCP search) | Automatic (context injection) |
| **Data portability** | Export via podman volume | Git-trackable `.md` files |
| **License** | Apache-2.0 (server) | MIT |

## Quick start

### Option A: memsearch (recommended)

```bash
./memsearch/setup.sh
```

### Option B: Qdrant

```bash
cd qdrant && podman compose up -d && cd ..
./switch-backend.sh qdrant
```

Then configure the MCP server — see [qdrant/README.md](qdrant/README.md).

## Switching backends

```bash
./switch-backend.sh memsearch   # activate memsearch
./switch-backend.sh qdrant      # activate qdrant
```

The switch script:
- Patches `~/.claude/CLAUDE.md` with the selected backend's memory instructions
- Adds/removes Qdrant session hooks in `~/.claude/settings.json`
- Enables/disables the memsearch plugin

Restart Claude Code after switching.

## Structure

```
qdrant/                 Qdrant vector DB backend
  compose.yaml          Podman compose for Qdrant v1.17.1
  hooks/                Session hooks (copied to ~/.claude/hooks/ on activation)
  CLAUDE-memory.md      Memory section injected into CLAUDE.md
  README.md             Qdrant-specific setup guide

memsearch/              memsearch plugin backend
  setup.sh              First-time installation script
  CLAUDE-memory.md      Memory section injected into CLAUDE.md
  README.md             memsearch-specific setup guide

switch-backend.sh       Toggle between backends
```
