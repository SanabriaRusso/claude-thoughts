#!/bin/bash
# Stop hook: snapshot Qdrant once per session, and block a session end that
# nothing was stored for.
#
# Stop fires after EVERY response, not only at session end, so a reminder here
# cannot tell "end of turn" from "end of session". The session-end signal comes
# from user-prompt-wrap-intent.sh, which touches an intent marker when the user
# says they are wrapping up. This hook blocks once per intent, only when nothing
# was stored since then:
#   - stop_hook_active is false (we are not already continuing because of a block)
#   - the intent marker is newer than the blocked marker (one block per intent;
#     a re-touched intent re-arms it)
#   - the intent marker is newer than the stored marker (touched by
#     post-qdrant-store-verify.sh and by the wrap-session skill's memory.py)
#   - no background tasks are running (a wrap-session fork may still be storing;
#     the check is not consumed and re-evaluates on the next Stop)
# Silent when Qdrant is down (nothing can be stored anyway).

MARKER_DIR="${CLAUDE_MEMORY_MARKER_DIR:-/tmp}"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
BACKGROUND_TASKS=$(echo "$INPUT" | jq -r '(.background_tasks // []) | length' 2>/dev/null)

# Housekeeping: drop the legacy one-shot reminder markers and anything stale.
rm -f "$MARKER_DIR"/.claude-memory-reminded-* 2>/dev/null
find "$MARKER_DIR" -maxdepth 1 -type f -name '.claude-memory-*' -mtime +7 -delete 2>/dev/null

curl -sf "$QDRANT_URL/healthz" >/dev/null 2>&1 || exit 0

# Fire-and-forget snapshot of all Qdrant collections, once per session
# (opt out: QDRANT_SNAPSHOTS_ENABLED=0, honored by snapshot-qdrant.sh).
# Detach with setsid+nohup so the snapshot survives if Claude Code reaps this hook's process group.
SNAPSHOT_MARKER="$MARKER_DIR/.claude-memory-snapshot-${SESSION_ID:-unknown}"
if [ ! -f "$SNAPSHOT_MARKER" ]; then
  touch "$SNAPSHOT_MARKER" 2>/dev/null
  SNAPSHOT_SCRIPT="$(dirname "$0")/snapshot-qdrant.sh"
  if [ -x "$SNAPSHOT_SCRIPT" ]; then
    if command -v setsid >/dev/null 2>&1; then
      setsid nohup "$SNAPSHOT_SCRIPT" </dev/null >/dev/null 2>&1 &
    else
      nohup "$SNAPSHOT_SCRIPT" </dev/null >/dev/null 2>&1 &
    fi
    disown 2>/dev/null || true
  fi
fi

[ -z "$SESSION_ID" ] && exit 0
[ "$STOP_HOOK_ACTIVE" = "true" ] && exit 0

INTENT="$MARKER_DIR/.claude-memory-wrap-intent-$SESSION_ID"
BLOCKED="$MARKER_DIR/.claude-memory-wrap-blocked-$SESSION_ID"
STORED="$MARKER_DIR/.claude-memory-stored-$SESSION_ID"

[ -f "$INTENT" ] || exit 0
# -nt is true when the second file is missing, so a missing marker counts as older.
[ "$INTENT" -nt "$BLOCKED" ] || exit 0
[ "$INTENT" -nt "$STORED" ] || exit 0
# Leave the blocked marker untouched so the check runs again on the next Stop.
[ "${BACKGROUND_TASKS:-0}" = "0" ] || exit 0

touch "$BLOCKED" 2>/dev/null
printf '%s\n' '{"decision":"block","reason":"[claude-memory] The user signalled the session is ending but nothing was stored to Qdrant. Run the wrap-session skill now, then finish. If the user did not mean to end the session, say so and finish."}'
exit 0
