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

Install the server as a uv tool, then register it by absolute path:

```bash
uv tool install --python 3.13 mcp-server-qdrant
claude mcp add claude-memory \
  --scope user \
  -- "$(uv tool dir --bin)/mcp-server-qdrant"
```

> Don't launch it with `uvx` (or `npx`). Every Claude session would start it through
> uvx, which leaves a ~400 MB environment in `~/.cache/uv` whenever a dependency
> changes and holds the uv cache lock while it runs. See
> [Disk usage](../README.md#disk-usage-keep-uvx-off-the-hot-path). The absolute path
> matters because Claude Code may not have `~/.local/bin` on its `PATH`.
> `./switch-backend.sh enable qdrant` rewrites an existing uvx/npx entry for you.

Edit `~/.claude.json` and add env vars to the `claude-memory` entry:

```json
{
  "mcpServers": {
    "claude-memory": {
      "command": "/Users/<you>/.local/bin/mcp-server-qdrant",
      "args": [],
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
- **Ports**: `127.0.0.1:6333` (REST), `127.0.0.1:6334` (gRPC)

### Snapshots

The Stop hook automatically dumps every collection to `~/qdrant-dumps/claude-memory-<TS>/`
after each session, keeping the 3 most recent runs. This protects against podman machine
resets that would otherwise wipe `qdrant-data`.

- **Opt out**: `export QDRANT_SNAPSHOTS_ENABLED=0`
- **Tunables**: `QDRANT_DUMP_DIR`, `QDRANT_DUMP_KEEP`
- **Log**: `~/qdrant-dumps/.snapshot.log`
- **Restore**: see [RESTORE.md](RESTORE.md)

For a full volume export instead: `podman volume export claude-thoughts_qdrant-data > backup.tar`

## Stopping

```bash
cd claude-thoughts/qdrant
podman compose down          # stop, keep data
podman compose down -v       # stop and delete all stored memories
```
