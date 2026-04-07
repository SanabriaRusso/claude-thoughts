# Qdrant Memory Backend

Self-hosted semantic memory for Claude Code using Qdrant + the official MCP server.

## How it works

Claude Code stores and retrieves context (architecture decisions, cross-repo knowledge,
progress notes) in a local Qdrant vector DB via MCP. Session hooks automate the workflow:
SessionStart checks/recovers Qdrant and reminds Claude to search; Stop enforces memory
storage before the session ends.

## Setup

### 1. Start Qdrant

```bash
cd claude-thoughts/qdrant
podman compose up -d
```

Verify: http://localhost:6333/dashboard

### 2. Configure MCP server

```bash
claude mcp add claude-memory \
  --scope user \
  -- npx -y mcp-server-qdrant@latest
```

Edit `~/.claude.json` and add env vars to the `claude-memory` entry:

```json
{
  "mcpServers": {
    "claude-memory": {
      "command": "npx",
      "args": ["-y", "mcp-server-qdrant@latest"],
      "env": {
        "QDRANT_URL": "http://localhost:6333",
        "COLLECTION_NAME": "claude-memory",
        "EMBEDDING_PROVIDER": "fastembed"
      }
    }
  }
}
```

> `fastembed` runs embeddings locally (~30MB model on first use, no API key).

### 3. Activate

From the repo root:

```bash
./switch-backend.sh qdrant
```

This installs the session hooks and patches `~/.claude/CLAUDE.md` with Qdrant-specific instructions.

### 4. Use it

In any Claude Code session:

```
> Check claude-memory for prior context about our deployment pipeline
> Store a summary of this architecture decision in claude-memory
```

## Data

- **Volume**: `claude-thoughts_qdrant-data` (podman named volume)
- **Backup**: `podman volume export claude-thoughts_qdrant-data > backup.tar`
- **Ports**: `127.0.0.1:6333` (REST), `127.0.0.1:6334` (gRPC)

## Stopping

```bash
cd claude-thoughts/qdrant
podman compose down          # stop, keep data
podman compose down -v       # stop and delete all stored memories
```
