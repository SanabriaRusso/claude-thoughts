#!/bin/bash
# UserPromptSubmit hook: notice when the user signals the session is ending.
#
# On a match it (1) tells Claude to run the wrap-session skill and (2) touches an
# intent marker that session-stop-memory.sh checks. Re-touching on every match
# re-arms the Stop check, so a second "let's wrap up" after a dismissed nudge
# blocks again. Silent when nothing matches or Qdrant is down (storing would fail).

MARKER_DIR="${CLAUDE_MEMORY_MARKER_DIR:-/tmp}"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)

[ -z "$SESSION_ID" ] && exit 0
[ -z "$PROMPT" ] && exit 0

PATTERN="wrap( up)?( the)? session|wrap[- ]session|done for (today|the day)|call it a (day|night)|end (the|this) session|before (i|we) (quit|close|leave)|that'?s (all|it) for today"

matched=false
if printf '%s\n' "$PROMPT" | grep -qiE "$PATTERN"; then
  matched=true
# "sign off" ends a session; "sign off on the design" approves something.
# macOS grep has no -P (no lookahead), so extract each occurrence and exclude the
# " on" form with a second grep.
elif printf '%s\n' "$PROMPT" | grep -oiE 'sign(ing)? off( on)?' | grep -qviE ' on$'; then
  matched=true
fi

[ "$matched" = true ] || exit 0

curl -sf "$QDRANT_URL/healthz" >/dev/null 2>&1 || exit 0

touch "$MARKER_DIR/.claude-memory-wrap-intent-$SESSION_ID" 2>/dev/null

echo "[claude-memory] Session-end signal detected. Before finishing, run the wrap-session skill (Skill: wrap-session) or delegate it to a fork subagent. If the user did not mean to end the session, ignore this."
exit 0
