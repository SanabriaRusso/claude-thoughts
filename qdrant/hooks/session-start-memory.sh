#!/bin/bash
# SessionStart hook: ensure Qdrant is running, attempt recovery if not.
# Reports status to Claude so it can act accordingly.

CONTAINER="claude-memory-qdrant"
COMPOSE_DIR="$HOME/github/claude-thoughts/qdrant"
HEALTH_URL="http://localhost:6333/healthz"

check_health() {
  curl -sf "$HEALTH_URL" > /dev/null 2>&1
}

# 1. Already running — happy path
if check_health; then
  cat << 'EOF'
[claude-memory] Qdrant is running. Search claude-memory MCP for prior context about the current project before starting work. Use semantic search with relevant keywords, repo and topic tags.
EOF
  exit 0
fi

# 2. Container exists but stopped — try podman start
if podman container exists "$CONTAINER" 2>/dev/null; then
  podman start "$CONTAINER" > /dev/null 2>&1
  sleep 2
  if check_health; then
    cat << 'EOF'
[claude-memory] Qdrant was stopped — recovered via podman start. Search claude-memory MCP for prior context about the current project before starting work.
EOF
    exit 0
  fi
fi

# 3. Container doesn't exist — try podman-compose up
if [ -f "$COMPOSE_DIR/compose.yaml" ]; then
  (cd "$COMPOSE_DIR" && podman-compose up -d 2>/dev/null)
  sleep 3
  if check_health; then
    cat << 'EOF'
[claude-memory] Qdrant container was missing — recreated via podman-compose. Search claude-memory MCP for prior context about the current project before starting work.
EOF
    exit 0
  fi
fi

# 4. All recovery failed
cat << 'EOF'
[claude-memory] WARNING: Qdrant is not reachable and automatic recovery failed. Memory storage will not work this session. Inform the user immediately and ask if they want to troubleshoot or proceed without semantic memory.
EOF
