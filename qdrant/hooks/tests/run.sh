#!/bin/bash
# Tests for the Qdrant memory hooks: user-prompt-wrap-intent.sh,
# session-stop-memory.sh and post-qdrant-store-verify.sh.
#
# Drives each hook with JSON on stdin. Markers go to a temp dir via
# CLAUDE_MEMORY_MARKER_DIR; snapshots are off. Needs a running Qdrant at
# QDRANT_URL (default http://localhost:6333): the PostToolUse cases create and
# delete a throwaway collection there. "Qdrant down" cases use an unreachable URL.
#
# Usage: bash qdrant/hooks/tests/run.sh

set -uo pipefail

HOOKS="$(cd "$(dirname "$0")/.." && pwd)"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
DOWN_URL="http://127.0.0.1:1"
MD="$(mktemp -d)"
ERR="$(mktemp)"
COLL="claude-memory-hooktest-$(date +%s)-$$"
COLL_CREATED=false

cleanup() {
  rm -rf "$MD" || true
  rm -f "$ERR" || true
  if [ "$COLL_CREATED" = true ]; then
    curl -sf -X DELETE "$QDRANT_URL/collections/$COLL" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

passed=0
failed=0
pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
check() { # check <description> <command...>
  local desc=$1; shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# run <hook> <json> [VAR=value ...] -> sets OUT and RC
run() {
  local hook=$1 json=$2; shift 2
  OUT=$(printf '%s' "$json" | env CLAUDE_MEMORY_MARKER_DIR="$MD" QDRANT_SNAPSHOTS_ENABLED=0 \
        QDRANT_URL="$QDRANT_URL" "$@" bash "$HOOKS/$hook.sh" 2>"$ERR")
  RC=$?
}

# age <file> <seconds>: set mtime to <seconds> ago (creates the file).
age() { touch -t "$(date -v-"$2"S +%Y%m%d%H%M.%S)" "$1"; }

prompt_json() { jq -cn --arg p "$1" --arg s "$2" '{prompt: $p, session_id: $s}'; }
stop_json() { # stop_json <sid> [stop_hook_active] [background_tasks json]
  if [ $# -ge 3 ]; then
    jq -cn --arg s "$1" --argjson a "${2:-false}" --argjson b "$3" \
      '{session_id: $s, stop_hook_active: $a, background_tasks: $b}'
  else
    jq -cn --arg s "$1" --argjson a "${2:-false}" '{session_id: $s, stop_hook_active: $a}'
  fi
}

if ! curl -sf "$QDRANT_URL/healthz" >/dev/null 2>&1; then
  echo "FAIL: Qdrant is not reachable at $QDRANT_URL; these tests need it running"
  echo "0 passed, 1 failed"
  exit 1
fi

NUDGE='[claude-memory] Session-end signal detected. Before finishing, run the wrap-session skill (Skill: wrap-session) or delegate it to a fork subagent. If the user did not mean to end the session, ignore this.'
BLOCK='{"decision":"block","reason":"[claude-memory] The user signalled the session is ending but nothing was stored to Qdrant. Run the wrap-session skill now, then finish. If the user did not mean to end the session, say so and finish."}'

# ─── user-prompt-wrap-intent.sh ─────────────────────────────────────────────

i=0
for p in "let's wrap up the session" "wrap the session please" "wrap session" "/wrap-session" \
         "OK, WRAP UP SESSION" "I'm done for today" "done for the day, thanks" \
         "let's call it a day" "call it a night" "end the session" "please end this session" \
         "before I quit, store what we learned" "before we close" "before we leave" \
         "that's all for today" "thats it for today" "I'm signing off" "sign off now" \
         "Signing off. Sign off on the design later"; do
  i=$((i + 1))
  sid="intent-pos-$i"
  run user-prompt-wrap-intent "$(prompt_json "$p" "$sid")"
  if [ "$RC" -eq 0 ] && [ "$OUT" = "$NUDGE" ] && [ -f "$MD/.claude-memory-wrap-intent-$sid" ]; then
    pass "intent matches: $p"
  else
    fail "intent matches: $p (rc=$RC out=$OUT)"
  fi
done

i=0
for p in "wrap up this PR" "sign off on the design" "please wrap this function in a try block" \
         "what did we end up doing in the session handler?" "are we done for now?" ""; do
  i=$((i + 1))
  sid="intent-neg-$i"
  run user-prompt-wrap-intent "$(prompt_json "$p" "$sid")"
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -e "$MD/.claude-memory-wrap-intent-$sid" ]; then
    pass "intent ignores: '$p'"
  else
    fail "intent ignores: '$p' (rc=$RC out=$OUT)"
  fi
done

run user-prompt-wrap-intent "$(prompt_json "let's wrap up the session" "")"
check "intent: empty session_id is silent" test "$RC" -eq 0 -a -z "$OUT"
check "intent: empty session_id touches no marker" test ! -e "$MD/.claude-memory-wrap-intent-"

run user-prompt-wrap-intent "$(prompt_json "let's wrap up the session" "intent-down")" QDRANT_URL="$DOWN_URL"
check "intent: Qdrant down is silent" test "$RC" -eq 0 -a -z "$OUT"
check "intent: Qdrant down touches no marker" test ! -e "$MD/.claude-memory-wrap-intent-intent-down"

age "$MD/.claude-memory-wrap-intent-retouch" 120
age "$MD/ref-retouch" 60
run user-prompt-wrap-intent "$(prompt_json "done for today" "retouch")"
check "intent: a repeat match re-touches the marker" test "$MD/.claude-memory-wrap-intent-retouch" -nt "$MD/ref-retouch"

# ─── session-stop-memory.sh ─────────────────────────────────────────────────

sid="stop-none"
run session-stop-memory "$(stop_json "$sid")"
check "stop: no intent is silent" test "$RC" -eq 0 -a -z "$OUT"
check "stop: snapshot marker written" test -f "$MD/.claude-memory-snapshot-$sid"
age "$MD/.claude-memory-snapshot-$sid" 3600
age "$MD/ref-snap" 1800
run session-stop-memory "$(stop_json "$sid")"
check "stop: snapshot marker written only once" test ! "$MD/.claude-memory-snapshot-$sid" -nt "$MD/ref-snap"

sid="stop-block"
age "$MD/.claude-memory-wrap-intent-$sid" 60
run session-stop-memory "$(stop_json "$sid")"
check "stop: intent + nothing stored blocks (background_tasks absent)" test "$RC" -eq 0 -a "$OUT" = "$BLOCK"
check "stop: printed block is valid JSON" jq -e '.decision == "block"' <<< "$OUT" >/dev/null
check "stop: block touches the blocked marker" test -f "$MD/.claude-memory-wrap-blocked-$sid"
run session-stop-memory "$(stop_json "$sid")"
check "stop: next Stop after a block is silent" test "$RC" -eq 0 -a -z "$OUT"
# Re-touched intent (the user signalled again) must block again.
age "$MD/.claude-memory-wrap-blocked-$sid" 30
touch "$MD/.claude-memory-wrap-intent-$sid"
run session-stop-memory "$(stop_json "$sid" false '[]')"
check "stop: re-touched intent blocks again (empty background_tasks)" test "$RC" -eq 0 -a "$OUT" = "$BLOCK"
run session-stop-memory "$(stop_json "$sid")"
check "stop: and only once" test "$RC" -eq 0 -a -z "$OUT"

sid="stop-stored"
age "$MD/.claude-memory-wrap-intent-$sid" 60
age "$MD/.claude-memory-stored-$sid" 10
run session-stop-memory "$(stop_json "$sid")"
check "stop: stored newer than intent is silent" test "$RC" -eq 0 -a -z "$OUT"
check "stop: stored newer than intent touches no blocked marker" test ! -e "$MD/.claude-memory-wrap-blocked-$sid"

sid="stop-stored-older"
age "$MD/.claude-memory-stored-$sid" 60
age "$MD/.claude-memory-wrap-intent-$sid" 10
run session-stop-memory "$(stop_json "$sid")"
check "stop: stored older than intent still blocks" test "$RC" -eq 0 -a "$OUT" = "$BLOCK"

sid="stop-active"
age "$MD/.claude-memory-wrap-intent-$sid" 60
run session-stop-memory "$(stop_json "$sid" true)"
check "stop: stop_hook_active true is silent" test "$RC" -eq 0 -a -z "$OUT"
check "stop: stop_hook_active true touches no blocked marker" test ! -e "$MD/.claude-memory-wrap-blocked-$sid"

sid="stop-bg"
age "$MD/.claude-memory-wrap-intent-$sid" 60
run session-stop-memory "$(stop_json "$sid" false '[{"id":"fork-1","status":"running"}]')"
check "stop: non-empty background_tasks is silent" test "$RC" -eq 0 -a -z "$OUT"
check "stop: non-empty background_tasks does not consume the check" test ! -e "$MD/.claude-memory-wrap-blocked-$sid"
run session-stop-memory "$(stop_json "$sid" false '[]')"
check "stop: blocks once background_tasks is empty" test "$RC" -eq 0 -a "$OUT" = "$BLOCK"

sid="stop-down"
age "$MD/.claude-memory-wrap-intent-$sid" 60
run session-stop-memory "$(stop_json "$sid")" QDRANT_URL="$DOWN_URL"
check "stop: Qdrant down is silent" test "$RC" -eq 0 -a -z "$OUT"
check "stop: Qdrant down touches no blocked marker" test ! -e "$MD/.claude-memory-wrap-blocked-$sid"
check "stop: Qdrant down writes no snapshot marker" test ! -e "$MD/.claude-memory-snapshot-$sid"

age "$MD/.claude-memory-wrap-intent-" 60
run session-stop-memory "$(stop_json "")"
check "stop: empty session_id is silent" test "$RC" -eq 0 -a -z "$OUT"

touch "$MD/.claude-memory-reminded-abc" "$MD/.claude-memory-reminded-def"
touch -t 202001010000 "$MD/.claude-memory-snapshot-ancient"
touch "$MD/.claude-memory-snapshot-fresh"
run session-stop-memory "$(stop_json "housekeeping")" QDRANT_URL="$DOWN_URL"
check "stop: legacy reminded markers pruned (even with Qdrant down)" \
  test ! -e "$MD/.claude-memory-reminded-abc" -a ! -e "$MD/.claude-memory-reminded-def"
check "stop: markers older than 7 days pruned" test ! -e "$MD/.claude-memory-snapshot-ancient"
check "stop: recent markers kept" test -e "$MD/.claude-memory-snapshot-fresh"

# ─── post-qdrant-store-verify.sh ────────────────────────────────────────────

if curl -sf -X PUT "$QDRANT_URL/collections/$COLL" -H 'Content-Type: application/json' \
     -d '{"vectors":{"size":4,"distance":"Cosine"}}' >/dev/null; then
  COLL_CREATED=true
  pass "verify: created throwaway collection $COLL"
else
  fail "verify: created throwaway collection $COLL"
fi

run post-qdrant-store-verify '{"session_id":"verify-clean","tool_name":"mcp__claude-memory__qdrant-store"}' COLLECTION_NAME="$COLL"
check "verify: clean sweep exits 0" test "$RC" -eq 0
check "verify: clean sweep touches the stored marker" test -f "$MD/.claude-memory-stored-verify-clean"

before=$(find "$MD" -maxdepth 1 -name '.claude-memory-stored-*' | wc -l | tr -d ' ')
OUT=$(env CLAUDE_MEMORY_MARKER_DIR="$MD" COLLECTION_NAME="$COLL" QDRANT_URL="$QDRANT_URL" \
      bash "$HOOKS/post-qdrant-store-verify.sh" </dev/null 2>"$ERR")
RC=$?
after=$(find "$MD" -maxdepth 1 -name '.claude-memory-stored-*' | wc -l | tr -d ' ')
check "verify: run by hand (</dev/null) exits 0" test "$RC" -eq 0
check "verify: empty session id touches nothing" test "$before" = "$after" -a ! -e "$MD/.claude-memory-stored-"

curl -sf -X PUT "$QDRANT_URL/collections/$COLL/points?wait=true" -H 'Content-Type: application/json' \
  -d '{"points":[{"id":1,"vector":[0.1,0.2,0.3,0.4],"payload":{"document":"stranded"}}]}' >/dev/null
run post-qdrant-store-verify '{"session_id":"verify-dirty"}' COLLECTION_NAME="$COLL"
check "verify: null metadata exits 2" test "$RC" -eq 2
check "verify: null metadata reports the point" grep -q 'STORE VERIFICATION FAILED' "$ERR"
check "verify: null metadata touches no stored marker" test ! -e "$MD/.claude-memory-stored-verify-dirty"

run post-qdrant-store-verify '{"session_id":"verify-missing"}' COLLECTION_NAME="$COLL-missing"
check "verify: missing collection exits 2" test "$RC" -eq 2
check "verify: missing collection touches no stored marker" test ! -e "$MD/.claude-memory-stored-verify-missing"

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
