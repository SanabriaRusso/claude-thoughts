#!/bin/bash
# PostToolUse hook: verify a qdrant-store call actually landed its metadata.
#
# WHY: mcp__claude-memory__qdrant-store takes `information` and `metadata` as two
# separate parameters. If the tool call is serialized wrong, the metadata JSON
# arrives embedded in the `information` string and `metadata` arrives absent —
# the server stores the blob as the document, writes NULL metadata, and returns
# success. The memory is then unreachable by any repo/topic-scoped query, and
# nothing surfaces the failure. Six such points accumulated before anyone noticed.
#
# This cannot be prevented by instructing the model: the fault is in the tool call
# serialization, not in a decision. Detection after the fact is the only guard, so
# it lives here rather than in prose in the /wrap-session skill.
#
# Fires after every store from any session/skill. Exit 2 feeds stderr back to the
# model so it repairs while the memory text is still in context.

QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
COLLECTION="${COLLECTION_NAME:-claude-memory}"

# Skip silently if the toolchain isn't there — never block a store on our own deps.
command -v curl >/dev/null 2>&1 || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

# Skip silently if Qdrant is unreachable. If it were down the store would have
# failed loudly on its own; nothing useful to add here.
curl -sf "$QDRANT_URL/healthz" >/dev/null 2>&1 || exit 0

# Collection-wide sweep rather than "the point we just wrote": the store tool does
# not return a point ID, and a whole-collection filter is ~3ms against 400 points.
# It also self-heals older corruption for free.
FILTER='{"filter":{"should":[
  {"is_null":{"key":"metadata"}},
  {"is_empty":{"key":"metadata.repo"}},
  {"is_empty":{"key":"metadata.topic"}}
]},"limit":10,"with_payload":true,"with_vector":false}'

# Healthz already passed, so a failure here is not "Qdrant is down" — it means the
# collection is missing/renamed or the query was rejected. That would leave every
# store silently unverified, so it must be loud rather than swallowed.
RESP=$(curl -sf "$QDRANT_URL/collections/$COLLECTION/points/scroll" \
  -H 'Content-Type: application/json' -d "$FILTER")
if [ $? -ne 0 ]; then
  echo "[claude-memory] post-store verify hook: Qdrant is up but scrolling collection '$COLLECTION' failed. It may be missing or renamed — the store was NOT verified. Check: curl -s $QDRANT_URL/collections/$COLLECTION" >&2
  exit 2
fi

# NOTE: no backslashes inside the python below, and no 2>/dev/null on it. An early
# version used an f-string with escaped quotes (a syntax error on py<3.12); with
# stderr suppressed it failed silently and the hook exited 0 on a corrupt
# collection. A verifier that passes silently is worse than no verifier — if this
# parse ever breaks, it must be loud.
REPORT=$(printf '%s' "$RESP" | python3 -c '
import json, sys
points = json.load(sys.stdin)["result"]["points"]
for p in points:
    doc = (p.get("payload") or {}).get("document") or ""
    snippet = doc[:100].replace("\n", " ")
    print("  - {}: {}...".format(p["id"], snippet))
')
PARSE_RC=$?

if [ $PARSE_RC -ne 0 ]; then
  echo "[claude-memory] post-store verify hook: could not parse the Qdrant scroll response (python exit $PARSE_RC). The store was NOT verified — check metadata by hand." >&2
  exit 2
fi

[ -z "$REPORT" ] && exit 0
COUNT=$(printf '%s\n' "$REPORT" | wc -l | tr -d ' ')

cat >&2 << EOF
[claude-memory] STORE VERIFICATION FAILED — $COUNT point(s) in '$COLLECTION' have null/empty metadata:
$REPORT

This is almost certainly the metadata-stranding bug: the metadata JSON landed
inside the 'information' string instead of the 'metadata' parameter, so the point
was stored with NULL metadata and is invisible to every repo/topic-scoped query.

REPAIR NOW, while the memory text is still in your context:
  1. Read the point back:
     curl -s $QDRANT_URL/collections/$COLLECTION/points/<id> | python3 -m json.tool
  2. DELETE it (do NOT patch with set_payload):
     curl -s -X POST $QDRANT_URL/collections/$COLLECTION/points/delete \\
       -H 'Content-Type: application/json' -d '{"points":["<id>"]}'
  3. Re-store via mcp__claude-memory__qdrant-store with 'information' and
     'metadata' as SEPARATE parameters, metadata = {"repo": "...", "topic": "..."}.

Delete + re-store rather than set_payload: set_payload fixes the payload but not
the vector, which was embedded from the corrupted text including the stranded
markup. Re-storing re-embeds cleanly. set_payload is only for archaeological
repair where the original text is no longer available.

If a listed point predates this session and its text is NOT in your context,
say so and ask the user before touching it — set_payload is the right tool there.
EOF
exit 2
