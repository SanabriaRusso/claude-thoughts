#!/bin/bash
# Tests that switch-backend.sh wires and unwires the four Qdrant hooks.
#
# Runs the script against a temporary HOME, with stub `uv` and `claude` first on
# PATH, so the real ~/.claude, uv tools and Claude CLI are never touched.
#
# Usage: bash tests/switch-backend-hooks.sh

set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"
STUB="$T/stub"
UV_BIN="$T/uv-bin"
HOOK_NAMES="session-start-memory session-stop-memory post-qdrant-store-verify user-prompt-wrap-intent"

cleanup() {
  rm -rf "$T" || true
}
trap cleanup EXIT

passed=0
failed=0
pass() { echo "PASS: $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
check() { # check <description> <command...>
  local desc=$1; shift
  if "$@" >/dev/null; then pass "$desc"; else fail "$desc"; fi
}

mkdir -p "$STUB" "$UV_BIN"
# Stub uv: `uv tool dir --bin` prints UV_BIN; `uv tool install …` creates the
# binary there plus the tool's Python interpreter under $HOME (the path the
# wrap-session skill runs on). Single quotes are deliberate: these lines are the
# stub's source and expand when the stub runs.
# shellcheck disable=SC2016
printf '%s\n' '#!/bin/bash' \
  'if [ "$1 $2 ${3:-}" = "tool dir --bin" ]; then echo "'"$UV_BIN"'"; exit 0; fi' \
  'if [ "$1 $2" = "tool install" ]; then' \
  '  printf "#!/bin/sh\n" > "'"$UV_BIN"'/mcp-server-qdrant"; chmod +x "'"$UV_BIN"'/mcp-server-qdrant"' \
  '  mkdir -p "$HOME/.local/share/uv/tools/mcp-server-qdrant/bin"' \
  '  printf "#!/bin/sh\n" > "$HOME/.local/share/uv/tools/mcp-server-qdrant/bin/python"' \
  '  chmod +x "$HOME/.local/share/uv/tools/mcp-server-qdrant/bin/python"' \
  '  echo "$*" >> "'"$T"'/uv-install.log"; exit 0' \
  'fi' \
  'echo "stub uv: unexpected args: $*" >&2; exit 1' > "$STUB/uv"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$STUB/claude"
chmod +x "$STUB/uv" "$STUB/claude"

# new_home <dir> <settings json>
new_home() {
  mkdir -p "$1/.claude"
  printf '%s\n' "$2" > "$1/.claude/settings.json"
  printf '%s\n' '# test CLAUDE.md' '' '<!-- MEMORY-BACKEND-START -->' 'old section' \
    '<!-- MEMORY-BACKEND-END -->' '' '## General Preferences' > "$1/.claude/CLAUDE.md"
}

# sb <home> <args...> -> sets OUT and RC
sb() {
  local home=$1; shift
  OUT=$(env HOME="$home" PATH="$STUB:$PATH" bash "$REPO/switch-backend.sh" "$@" 2>&1)
  RC=$?
}

# count <settings> <event> <hook>: entries in that event running ~/.claude/hooks/<hook>.sh
count() {
  jq --arg e "$2" --arg h "$3" \
    '[.hooks[$e] // [] | .[] | .hooks[]? | select(.command == "~/.claude/hooks/\($h).sh")] | length' "$1"
}

event_of() {
  case "$1" in
    session-start-memory) echo SessionStart ;;
    session-stop-memory) echo Stop ;;
    post-qdrant-store-verify) echo PostToolUse ;;
    user-prompt-wrap-intent) echo UserPromptSubmit ;;
  esac
}

# ─── Fresh install round-trip from {} ───────────────────────────────────────

H="$T/home-fresh"
new_home "$H" '{}'
S="$H/.claude/settings.json"

sb "$H" enable qdrant
check "enable qdrant exits 0" test "$RC" -eq 0
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT"
check "enable installs mcp-server-qdrant via uv tool install" grep -q 'tool install' "$T/uv-install.log"

for h in $HOOK_NAMES; do
  check "enable wires $h under $(event_of "$h") once" test "$(count "$S" "$(event_of "$h")" "$h")" = 1
  check "enable copies $h.sh as executable" test -x "$H/.claude/hooks/$h.sh"
done
check "PostToolUse entry has the qdrant-store matcher" \
  jq -e '.hooks.PostToolUse[0].matcher == "mcp__claude-memory__qdrant-store" and .hooks.PostToolUse[0].hooks[0].timeout == 10' "$S"
check "UserPromptSubmit entry has timeout 5" jq -e '.hooks.UserPromptSubmit[0].hooks[0].timeout == 5' "$S"
check "settings.json is valid JSON" jq -e . "$S"

if [ -d "$REPO/skills/wrap-session/scripts" ]; then
  nonexec=$(find "$H/.claude/skills/wrap-session/scripts" -maxdepth 1 -name '*.sh' ! -perm -u+x | wc -l | tr -d ' ')
  check "skill scripts/*.sh are executable" test "$nonexec" = 0
else
  pass "skill has no scripts/ yet; chmod step is a no-op"
fi

before=$(jq -S . "$S")
sb "$H" enable qdrant
check "second enable exits 0" test "$RC" -eq 0
check "second enable adds no duplicate entries" test "$(jq -S . "$S")" = "$before"

sb "$H" status
check "status exits 0" test "$RC" -eq 0
for h in $HOOK_NAMES; do
  check "status reports $h installed" grep -qF "hook $h: installed" <<< "$OUT"
done
check "status reports the wrap-session interpreter ok" grep -qF "wrap-session interpreter: ok" <<< "$OUT"

rm -f "$H/.claude/hooks/user-prompt-wrap-intent.sh"
sb "$H" status
check "status reports a hook MISSING when its file is gone" \
  grep -qF "hook user-prompt-wrap-intent: MISSING" <<< "$OUT"
rm -f "$H/.local/share/uv/tools/mcp-server-qdrant/bin/python"
sb "$H" status
check "status reports the interpreter MISSING when it is gone" \
  grep -qF "wrap-session interpreter: MISSING" <<< "$OUT"

sb "$H" disable qdrant
check "disable qdrant exits 0" test "$RC" -eq 0
for h in $HOOK_NAMES; do
  check "disable removes $h" test "$(count "$S" "$(event_of "$h")" "$h")" = 0
done
check "settings.json round-trips to {}" test "$(jq -c . "$S")" = '{}'
check "status no longer lists hooks" test "$(grep -c 'hook ' <<< "$OUT")" = 0

# ─── Existing settings: hand-added verifier and unrelated user hooks ────────

H="$T/home-existing"
ORIG='{"model":"opus","hooks":{"PostToolUse":[{"matcher":"Write","hooks":[{"type":"command","command":"~/bin/fmt.sh"}]},{"matcher":"mcp__claude-memory__qdrant-store","hooks":[{"type":"command","command":"~/.claude/hooks/post-qdrant-store-verify.sh","timeout":10}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"~/bin/prompt-log.sh"}]}]}}'
new_home "$H" "$ORIG"
S="$H/.claude/settings.json"

sb "$H" enable qdrant
check "enable over existing settings exits 0" test "$RC" -eq 0
check "hand-added PostToolUse verifier is not duplicated" \
  test "$(count "$S" PostToolUse post-qdrant-store-verify)" = 1
check "unrelated PostToolUse hook kept" jq -e '[.hooks.PostToolUse[].hooks[].command] | index("~/bin/fmt.sh") != null' "$S"
check "intent hook appended after the user's UserPromptSubmit hook" \
  jq -e '[.hooks.UserPromptSubmit[].hooks[].command] == ["~/bin/prompt-log.sh", "~/.claude/hooks/user-prompt-wrap-intent.sh"]' "$S"

sb "$H" disable qdrant
check "disable over existing settings exits 0" test "$RC" -eq 0
check "disable keeps only the user's own settings and hooks" \
  test "$(jq -cS . "$S")" = "$(jq -cS 'del(.hooks.PostToolUse[1])' <<< "$ORIG")"

echo ""
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
