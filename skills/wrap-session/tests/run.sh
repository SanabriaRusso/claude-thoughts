#!/bin/bash
# tests/run.sh — end-to-end tests for skills/wrap-session/scripts/memory.py.
#
# Runs against a throwaway collection on the live Qdrant (same named-vector config as
# claude-memory). Safety: memory.py refuses to touch `claude-memory` when
# WRAP_SESSION_TEST=1, and the live point count is asserted unchanged at the end.
# Needs: Qdrant on QDRANT_URL, jq, curl, git, and the mcp-server-qdrant uv tool env.
#
# Usage: bash skills/wrap-session/tests/run.sh
# shellcheck disable=SC2016  # $var inside single quotes below are jq variables, not shell
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MEMORY="$HERE/../scripts/memory.sh"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
LIVE="claude-memory"
TEST_COLL="claude-memory-test-$(date +%s)-$$"
TMP="$(mktemp -d)"
WT="$TMP/wt"
export QDRANT_URL WRAP_SESSION_TEST=1 COLLECTION_NAME="$TEST_COLL" \
  CLAUDE_MEMORY_MARKER_DIR="$TMP/markers" CLAUDE_CODE_SESSION_ID="test-$$" TMPDIR="$TMP"
mkdir -p "$CLAUDE_MEMORY_MARKER_DIR"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
expect_exit() { # desc expected actual [outfile]
  if [ "$2" = "$3" ]; then ok "$1 (exit $3)"; else bad "$1 (expected exit $2, got $3)"; [ -n "${4:-}" ] && sed 's/^/    | /' "$4" | head -30; fi
}
expect_grep() { # desc pattern file
  if grep -qE -- "$2" "$3"; then ok "$1"; else bad "$1 (pattern '$2' not in output)"; sed 's/^/    | /' "$3" | head -30; fi
}
expect_true() { # desc cmd...
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
run() { # outfile cmd...  -> prints exit code
  local out="$1"; shift
  "$@" >"$out" 2>&1; echo $?
}
cleanup() {
  git -C "$REPO_ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true
  curl -s -X DELETE "$QDRANT_URL/collections/$TEST_COLL" >/dev/null 2>&1 || true
  rm -rf "$TMP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# ─── preconditions ──────────────────────────────────────────────────────────
curl -sf "$QDRANT_URL/healthz" >/dev/null || { echo "Qdrant not reachable at $QDRANT_URL"; exit 1; }
live_before=$(curl -s "$QDRANT_URL/collections/$LIVE" | jq -r '.result.points_count')
for c in $(curl -s "$QDRANT_URL/collections" | jq -r '.result.collections[].name' | grep '^claude-memory-test-'); do
  curl -s -X DELETE "$QDRANT_URL/collections/$c" >/dev/null   # stale collection from a killed run
done
curl -sf -X PUT "$QDRANT_URL/collections/$TEST_COLL" -H 'Content-Type: application/json' \
  -d '{"vectors":{"fast-all-minilm-l6-v2":{"size":384,"distance":"Cosine"}}}' >/dev/null \
  || { echo "cannot create $TEST_COLL"; exit 1; }
echo "test collection: $TEST_COLL"

TEXT_A="The Stop hook in claude-thoughts fires after every assistant turn, so its once-per-session reminder lands at the end of the first turn and never at session end. The marker file keyed on the session id is what makes it one-shot."
TEXT_B="fastembed's all-MiniLM-L6-v2 tokenizer, as used by mcp-server-qdrant for the claude-memory collection, truncates every document at 128 tokens, about 400 characters. Only the opening sentences of a memory contribute to its vector."

# ─── 1. preflight ───────────────────────────────────────────────────────────
rc=$(run "$TMP/pre.json" "$MEMORY" --json preflight)
expect_exit "preflight runs" 0 "$rc" "$TMP/pre.json"
expect_true "preflight detects repo claude-thoughts" jq -e '.repo == "claude-thoughts"' "$TMP/pre.json"
expect_true "preflight reports qdrant/collection/vector ok" jq -e '.qdrant_ok and .collection_ok and .vector_name_ok' "$TMP/pre.json"
expect_true "preflight targets the test collection" jq -e --arg c "$TEST_COLL" '.collection == $c and .points_total == 0' "$TMP/pre.json"
expect_true "preflight creates a workdir" test -d "$(jq -r '.workdir' "$TMP/pre.json")"
expect_true "preflight workdir path contains no 'git'" bash -c "! grep -q git <<<\"$(jq -r '.workdir' "$TMP/pre.json")\""

# ─── 2. repo detection from a worktree ──────────────────────────────────────
if git -C "$REPO_ROOT" worktree add --detach "$WT" HEAD >/dev/null 2>&1; then
  rc=$(run "$TMP/pre-wt.json" bash -c "cd '$WT' && '$MEMORY' --json preflight")
  expect_exit "preflight from a worktree runs" 0 "$rc" "$TMP/pre-wt.json"
  expect_true "preflight from a worktree still reports repo claude-thoughts" jq -e '.repo == "claude-thoughts"' "$TMP/pre-wt.json"
else
  bad "could not create a temporary worktree"
fi

# ─── 3. safety and environment failures ─────────────────────────────────────
rc=$(run "$TMP/live.txt" env COLLECTION_NAME=claude-memory "$MEMORY" check "$TMP/pre.json")
expect_exit "WRAP_SESSION_TEST=1 refuses the live collection" 2 "$rc" "$TMP/live.txt"
rc=$(run "$TMP/noint.txt" env WRAP_SESSION_PYTHON=/nonexistent/python "$MEMORY" preflight)
expect_exit "memory.sh exits 3 when the interpreter is missing" 3 "$rc" "$TMP/noint.txt"
rc=$(run "$TMP/down.txt" env QDRANT_URL=http://127.0.0.1:1 "$MEMORY" preflight)
expect_exit "preflight exits 2 when Qdrant is down" 2 "$rc" "$TMP/down.txt"
expect_grep "preflight names the Qdrant-down remedy" "Qdrant is down" "$TMP/down.txt"
rc=$(run "$TMP/nocoll.txt" env COLLECTION_NAME="claude-memory-test-missing-$$" "$MEMORY" preflight)
expect_exit "preflight exits 2 when the collection is missing" 2 "$rc" "$TMP/nocoll.txt"

# ─── 4. seed store (incl. a foreign repo) ───────────────────────────────────
cat > "$TMP/seed.json" <<EOF
[
  {"information": "$TEXT_A", "metadata": {"topic": "stop-hook-first-turn", "category": "gotcha"}},
  {"information": "$TEXT_B", "metadata": {"topic": "embedding-truncation", "category": "gotcha", "related_repos": ["gitops-infrastructure"]}},
  {"information": "In other-repo the deploy workflow needs the OPERATION=apply input; plan-only runs are the default.", "metadata": {"repo": "other-repo", "topic": "deploy-workflow-apply-input", "category": "integration"}}
]
EOF
rc=$(run "$TMP/seed-check.txt" "$MEMORY" check "$TMP/seed.json")
expect_exit "check on a clean file exits 0" 0 "$rc" "$TMP/seed-check.txt"
expect_grep "check warns on a foreign repo but allows it" "repo=other-repo differs from the detected repo" "$TMP/seed-check.txt"
expect_grep "check prints the indexed prefix" "indexed prefix" "$TMP/seed-check.txt"
rc=$(run "$TMP/seed-store.json" "$MEMORY" --json store "$TMP/seed.json")
expect_exit "store on a clean file exits 0" 0 "$rc" "$TMP/seed-store.json"
expect_true "store reports 3 stored points" jq -e '.stored | length == 3' "$TMP/seed-store.json"
expect_true "store keeps the foreign repo tag" jq -e '.stored[2].repo == "other-repo"' "$TMP/seed-store.json"
expect_true "store writes a receipt" test -f "$TMP/seed.receipt.json"
expect_true "store touches the per-session stored marker" test -f "$CLAUDE_MEMORY_MARKER_DIR/.claude-memory-stored-test-$$"
ID_A=$(jq -r '.stored[0].id' "$TMP/seed-store.json")
expect_true "stored point reads back with metadata and today's date" \
  bash -c "curl -s '$QDRANT_URL/collections/$TEST_COLL/points/$ID_A' | jq -e '.result.payload.metadata.topic == \"stop-hook-first-turn\" and (.result.payload.metadata.date | test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}$\"))'"
rc=$(run "$TMP/seed-again.txt" "$MEMORY" store "$TMP/seed.json")
expect_exit "second store of the same file is refused by the receipt" 7 "$rc" "$TMP/seed-again.txt"

# ─── 5. duplicates / overlaps ───────────────────────────────────────────────
cat > "$TMP/dup.json" <<EOF
[{"information": "$TEXT_A", "metadata": {"topic": "stop-hook-first-turn-again", "category": "gotcha"}}]
EOF
rc=$(run "$TMP/dup-check.json" "$MEMORY" --json check "$TMP/dup.json")
expect_true "identical text is labelled DUPLICATE with the existing id" \
  jq -e --arg id "$ID_A" '.results[0].same_repo[0].label == "DUPLICATE" and .results[0].same_repo[0].id == $id' "$TMP/dup-check.json"
rc=$(run "$TMP/dup-store.txt" "$MEMORY" store "$TMP/dup.json")
expect_exit "store refuses a DUPLICATE that is not superseded" 6 "$rc" "$TMP/dup-store.txt"
expect_grep "refusal names the duplicated id" "$ID_A" "$TMP/dup-store.txt"

cat > "$TMP/para.json" <<EOF
[
  {"information": "The MiniLM embedder behind mcp-server-qdrant truncates each claude-memory document at 128 tokens (about 400 characters), so only a memory's opening sentences shape its vector.", "metadata": {"topic": "embedding-window", "category": "gotcha"}},
  {"information": "Homebrew nc on macOS is GNU netcat 0.7.1, where -G means source routing rather than a timeout; use -z -w 5 for a reachability probe.", "metadata": {"topic": "nc-timeout-flag", "category": "gotcha"}}
]
EOF
rc=$(run "$TMP/para-check.json" "$MEMORY" --json check "$TMP/para.json")
expect_exit "check on paraphrase + unrelated text exits 0" 0 "$rc" "$TMP/para-check.json"
expect_true "reworded memory lands in the OVERLAP band against the original" \
  jq -e '.results[0].same_repo[0].label == "OVERLAP" and .results[0].same_repo[0].topic == "embedding-truncation"' "$TMP/para-check.json"
expect_true "unrelated text scores < 0.70 and carries no label" \
  jq -e '(.results[1].same_repo | length == 0) or (.results[1].same_repo[0].score < 0.70 and .results[1].same_repo[0].label == "")' "$TMP/para-check.json"

cat > "$TMP/batchdup.json" <<EOF
[
  {"information": "Same text twice in one file to test the in-batch check: podman machine start hangs with --log-level=debug when stdout is a terminal.", "metadata": {"topic": "podman-debug-hang-a", "category": "gotcha"}},
  {"information": "Same text twice in one file to test the in-batch check: podman machine start hangs with --log-level=debug when stdout is a terminal.", "metadata": {"topic": "podman-debug-hang-b", "category": "gotcha"}}
]
EOF
rc=$(run "$TMP/batchdup.txt" "$MEMORY" store "$TMP/batchdup.json")
expect_exit "store refuses duplicates within the same file" 6 "$rc" "$TMP/batchdup.txt"
expect_grep "in-file duplicate is named" "DUPLICATE within this file" "$TMP/batchdup.txt"

# ─── 6. supersede ───────────────────────────────────────────────────────────
cat > "$TMP/sup.json" <<EOF
[{"information": "$TEXT_A Fixed in wrap-session v2: the Stop hook now blocks once per intent instead of reminding on the first turn.", "metadata": {"topic": "stop-hook-first-turn", "category": "gotcha", "supersedes": ["$ID_A"]}}]
EOF
rc=$(run "$TMP/sup-store.json" "$MEMORY" --json store "$TMP/sup.json")
expect_exit "store with supersedes exits 0" 0 "$rc" "$TMP/sup-store.json"
expect_true "superseded id is reported as deleted" jq -e --arg id "$ID_A" '.deleted[0].id == $id' "$TMP/sup-store.json"
expect_true "superseded point is gone" bash -c "curl -s -o /dev/null -w '%{http_code}' '$QDRANT_URL/collections/$TEST_COLL/points/$ID_A' | grep -q 404"
ID_NEW=$(jq -r '.stored[0].id' "$TMP/sup-store.json")
expect_true "replacement point reads back with the reused topic" \
  bash -c "curl -s '$QDRANT_URL/collections/$TEST_COLL/points/$ID_NEW' | jq -e '.result.payload.metadata.topic == \"stop-hook-first-turn\"'"
cat > "$TMP/badsup.json" <<EOF
[{"information": "A perfectly fine memory about the krunkit dylibs missing after a macOS upgrade, which breaks podman machine start until the package is reinstalled.", "metadata": {"topic": "krunkit-dylibs", "category": "gotcha", "supersedes": ["00000000-0000-0000-0000-000000000000"]}}]
EOF
rc=$(run "$TMP/badsup.txt" "$MEMORY" store "$TMP/badsup.json")
expect_exit "store refuses a supersedes id that does not exist" 5 "$rc" "$TMP/badsup.txt"
expect_grep "missing supersedes id is named" "does not exist" "$TMP/badsup.txt"

# ─── 7. secrets and schema ──────────────────────────────────────────────────
cat > "$TMP/secret.json" <<EOF
[{"information": "The deploy job authenticates with token ghp_abcdefghijklmnopqrstuvwxyz0123456 stored in CI.", "metadata": {"topic": "ci-token-leak", "category": "context"}}]
EOF
rc=$(run "$TMP/secret-check.txt" "$MEMORY" check "$TMP/secret.json")
expect_exit "check exits 4 on a secret" 4 "$rc" "$TMP/secret-check.txt"
expect_grep "check names the secret pattern" "SECRET: github token" "$TMP/secret-check.txt"
rc=$(run "$TMP/secret-store.txt" "$MEMORY" store "$TMP/secret.json")
expect_exit "store exits 4 on a secret" 4 "$rc" "$TMP/secret-store.txt"
cat > "$TMP/redacted.json" <<EOF
[{"information": "The deploy job authenticates with token=<REDACTED> stored in CI; rotate it via the GitHub settings page.", "metadata": {"topic": "ci-token-rotation", "category": "context"}}]
EOF
rc=$(run "$TMP/redacted.txt" "$MEMORY" check "$TMP/redacted.json")
expect_exit "a <REDACTED> value is not flagged as a secret" 0 "$rc" "$TMP/redacted.txt"

cat > "$TMP/bad.json" <<EOF
[
  {"information": "unknown key", "metadata": {"topic": "ok-topic", "category": "gotcha", "bogus": 1}},
  {"information": "bad topic", "metadata": {"topic": "Bad Topic", "category": "gotcha"}},
  {"information": "bad category", "metadata": {"topic": "ok-topic-2", "category": "misc"}},
  {"information": "bad date and list", "metadata": {"topic": "ok-topic-3", "category": "gotcha", "date": "yesterday", "pr": "not-a-list"}}
]
EOF
rc=$(run "$TMP/bad-check.txt" "$MEMORY" check "$TMP/bad.json")
expect_exit "check exits 5 on schema errors" 5 "$rc" "$TMP/bad-check.txt"
expect_true "every schema error is reported" bash -c "[ \"\$(grep -c 'SCHEMA ERROR' '$TMP/bad-check.txt')\" -ge 5 ]"
rc=$(run "$TMP/bad-store.txt" "$MEMORY" store "$TMP/bad.json")
expect_exit "store exits 5 on schema errors" 5 "$rc" "$TMP/bad-store.txt"

# ─── 8. indexed-prefix preview on a long text ───────────────────────────────
LONG=$(python3 -c "import random; random.seed(7); w='alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango'.split(); print(' '.join(random.choice(w) for _ in range(300)))")
cat > "$TMP/long.json" <<EOF
[{"information": "A long memory to measure the embedding window. $LONG", "metadata": {"topic": "long-text-window", "category": "context"}}]
EOF
rc=$(run "$TMP/long-check.json" "$MEMORY" --json check "$TMP/long.json")
expect_exit "check on a long text exits 0" 0 "$rc" "$TMP/long-check.json"
expect_true "long text is flagged truncated with an exact (not approximate) prefix" jq -e '.results[0].truncated == true and .results[0].prefix_approx == false' "$TMP/long-check.json"
expect_true "indexed prefix is a strict prefix of the text" \
  jq -e '.results[0].prefix as $p | ($p | length) > 200 and ($p | length) < (.candidates[0].information | length) and (.candidates[0].information | startswith($p))' "$TMP/long-check.json"
expect_true "a short text is not flagged truncated" jq -e '.results[0].truncated == false' "$TMP/para-check.json"

# ─── 9. orphan sweep after store ────────────────────────────────────────────
ZEROS=$(python3 -c "print('[' + ','.join(['0.1']*384) + ']')")
curl -sf -X PUT "$QDRANT_URL/collections/$TEST_COLL/points?wait=true" -H 'Content-Type: application/json' \
  -d "{\"points\":[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"vector\":{\"fast-all-minilm-l6-v2\":$ZEROS},\"payload\":{\"document\":\"stranded {\\\"repo\\\": \\\"x\\\"}\",\"metadata\":null}}]}" >/dev/null
cat > "$TMP/after-orphan.json" <<EOF
[{"information": "gcloud config configurations activate silently repoints the GKE auth plugin at the new account, so kubectl contexts created under the old one start failing with reauthentication errors.", "metadata": {"topic": "gcloud-config-activate", "category": "gotcha"}}]
EOF
rc=$(run "$TMP/orphan.txt" "$MEMORY" store "$TMP/after-orphan.json")
expect_exit "store exits 8 when the post-store sweep finds null-metadata points" 8 "$rc" "$TMP/orphan.txt"
expect_grep "sweep names the stranded point" "11111111-1111-1111-1111-111111111111" "$TMP/orphan.txt"

# ─── 10. live collection untouched ──────────────────────────────────────────
live_after=$(curl -s "$QDRANT_URL/collections/$LIVE" | jq -r '.result.points_count')
if [ "$live_before" = "$live_after" ]; then ok "live claude-memory point count unchanged ($live_after)"; else bad "live claude-memory changed: $live_before -> $live_after"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
