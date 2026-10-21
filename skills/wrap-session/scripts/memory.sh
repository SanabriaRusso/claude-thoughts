#!/bin/bash
# memory.sh — run memory.py with the interpreter of the mcp-server-qdrant uv tool
# install. That environment carries fastembed and the cached MiniLM model, i.e. the
# exact embedder the claude-memory MCP server uses, so points written here are
# indistinguishable from MCP-written ones. Override with WRAP_SESSION_PYTHON.
# Never launches uvx (see "Disk usage" in README.md).
PY="${WRAP_SESSION_PYTHON:-$HOME/.local/share/uv/tools/mcp-server-qdrant/bin/python}"
if [ ! -x "$PY" ]; then
  echo "memory.sh: interpreter not found at $PY" >&2
  echo "           run: ~/github/claude-thoughts/switch-backend.sh enable qdrant" >&2
  exit 3
fi
exec "$PY" -I "$(dirname "$0")/memory.py" "$@"
