#!/bin/bash
# Stop hook: REQUIRE Claude to store memories before session ends.
# Fires once per session. Silent when Qdrant is down (nothing we can do at exit).

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
MARKER="/tmp/.claude-memory-reminded-${SESSION_ID:-unknown}"

# Skip if already reminded this session
if [ -f "$MARKER" ]; then
  exit 0
fi

# Skip silently if Qdrant is down (can't store anyway)
if ! curl -sf http://localhost:6333/healthz > /dev/null 2>&1; then
  exit 0
fi

touch "$MARKER"
cat << 'EOF'
[claude-memory] MANDATORY: Before ending this session, you MUST call mcp__claude-memory__qdrant-store for EACH of the following that applies:
- Architecture decisions made or discussed
- Gotchas, bugs, or non-obvious behaviors discovered
- Lessons learned or corrections received
- Cross-repo knowledge or integration points
- Project context that helps future sessions
Always include metadata: {"repo": "<project-name>", "topic": "<area>"}
If nothing significant happened, store a brief session summary of what was worked on.
This is a BLOCKING REQUIREMENT — do NOT finish without storing at least one memory.
EOF
