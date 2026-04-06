# Claude Code Memory Stack

Self-hosted semantic memory for Claude Code using Qdrant + the official MCP server.

## What this does

Claude Code stores and retrieves context (architecture decisions, cross-repo knowledge,
progress notes) in a local Qdrant vector DB via MCP. When you start a new session or
switch repos, Claude can semantically search for relevant prior context instead of
you re-explaining everything.

## Quick Start

### 1. Start Qdrant

```bash
cd claude-thoughts
podman compose up -d
```

Verify it's running: http://localhost:6333/dashboard

### 2. Configure Claude Code

Add the MCP server at user scope so it's available across all repos:

```bash
claude mcp add claude-memory \
  --scope user \
  -- npx -y mcp-server-qdrant@latest
```

Then edit `~/.claude.json`, find the `claude-memory` entry, and add env vars:

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

> `fastembed` runs embeddings locally (no API key needed). It downloads a
> small model (~30MB) on first use.

### 3. Session Hooks

Two hooks in `~/.claude/settings.json` automate the memory workflow:

- **SessionStart** — checks if Qdrant is reachable and reminds Claude to
  search for prior context about the current project.
- **Stop** — fires once per session when Claude finishes, reminding it to
  store any new decisions, gotchas, or lessons learned before the session ends.

Both hooks are silent when Qdrant is not running — no errors, no noise.

Scripts live in `~/.claude/hooks/`:
- `session-start-memory.sh`
- `session-stop-memory.sh`

### 4. Use it

In any Claude Code session:

```
> Before we start, check claude-memory for any prior context about our deployment pipeline
> Store a summary of this project's architecture in claude-memory
```

## Tips

- **Cross-repo context**: Prefix stored notes with `repo:<name>` and
  `topic:<area>` so retrieval works across projects.
- **Compaction insurance**: Before a long session hits the context limit,
  ask Claude to summarize and store progress in memory.
- **Data lives in**: A podman volume called `claude-thoughts_qdrant-data`.
  Back it up with `podman volume export`.

## Stopping / Cleanup

```bash
podman compose down          # stop, keep data
podman compose down -v       # stop and delete all stored memories
```
