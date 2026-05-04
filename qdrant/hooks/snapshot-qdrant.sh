#!/bin/bash
# Snapshot every Qdrant collection to ~/qdrant-dumps/claude-memory-<TS>/.
# Invoked in the background by session-stop-memory.sh; logs to ~/qdrant-dumps/.snapshot.log.
#
# Opt out:  export QDRANT_SNAPSHOTS_ENABLED=0
# Override: QDRANT_URL, QDRANT_DUMP_DIR, QDRANT_DUMP_KEEP

set -uo pipefail

if [ "${QDRANT_SNAPSHOTS_ENABLED:-1}" = "0" ]; then
  exit 0
fi

QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
DUMP_DIR="${QDRANT_DUMP_DIR:-$HOME/qdrant-dumps}"
KEEP="${QDRANT_DUMP_KEEP:-3}"
[ "$KEEP" -lt 1 ] 2>/dev/null && KEEP=1
TS=$(date +%Y%m%d-%H%M%S)-$$
TARGET="$DUMP_DIR/claude-memory-$TS"
LOG="$DUMP_DIR/.snapshot.log"

if ! mkdir -p "$DUMP_DIR" 2>/dev/null; then
  echo "snapshot-qdrant: cannot create $DUMP_DIR" >&2
  exit 1
fi
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

if ! curl -sf "$QDRANT_URL/healthz" > /dev/null 2>&1; then
  log "Qdrant unreachable at $QDRANT_URL — skipping"
  exit 0
fi

collections=$(curl -sf "$QDRANT_URL/collections" | jq -r '.result.collections[]?.name' 2>/dev/null)
if [ -z "$collections" ]; then
  log "No collections to snapshot"
  exit 0
fi

if ! mkdir -p "$TARGET"; then
  log "Cannot create $TARGET — aborting"
  exit 1
fi
log "Starting snapshot → $TARGET"

success=0
fail=0
while IFS= read -r col; do
  [ -z "$col" ] && continue
  if ! [[ "$col" =~ ^[A-Za-z0-9._-]+$ ]]; then
    log "  $col: SKIPPED (name has unsafe characters)"
    fail=$((fail + 1))
    continue
  fi

  snap=$(curl -sf -X POST "$QDRANT_URL/collections/$col/snapshots" | jq -r '.result.name // empty')
  if [ -z "$snap" ]; then
    log "  $col: create FAILED"
    fail=$((fail + 1))
    continue
  fi

  if curl -sf "$QDRANT_URL/collections/$col/snapshots/$snap" -o "$TARGET/${col}.snapshot"; then
    size=$(du -h "$TARGET/${col}.snapshot" 2>/dev/null | cut -f1)
    log "  $col: saved ($size)"
    success=$((success + 1))
  else
    log "  $col: download FAILED"
    fail=$((fail + 1))
  fi

  # Remove the in-volume snapshot so the qdrant-data volume doesn't grow
  curl -sf -X DELETE "$QDRANT_URL/collections/$col/snapshots/$snap" > /dev/null 2>&1 || true
done <<< "$collections"

if [ "$success" -eq 0 ]; then
  log "All snapshots failed; removing empty $TARGET"
  rm -rf "$TARGET"
  exit 1
fi

log "Done: $success ok, $fail failed"

# Rotate: keep $KEEP most recent
# shellcheck disable=SC2012
ls -1dt "$DUMP_DIR"/claude-memory-* 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
  log "Pruning $old"
  rm -rf "$old"
done

exit 0
