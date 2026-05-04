# Restoring Qdrant from a snapshot dump

After a podman machine reset (or any event that destroys `qdrant-data`), use the
dumps in `~/qdrant-dumps/` to rebuild every collection.

The Stop hook produces dumps named `~/qdrant-dumps/claude-memory-<TS>/<collection>.snapshot`,
keeping the 3 most recent runs.

## Prerequisites

- Qdrant container running and reachable at `http://localhost:6333`
  (`./switch-backend.sh status` will show whether it's up).
- `curl` and `jq` available locally.
- **Quit Claude Code (and any process using the MCP servers) first.** The
  `claude-memory` / `claude-rag` MCP servers will auto-create empty collections
  with their own vector config on first use. If that happens before restore,
  the snapshot upload will fail or land in a mismatched collection. Restore on
  a quiescent Qdrant.
- The dump must come from the same Qdrant major version as the running container
  (`qdrant/compose.yaml` pins it). Cross-version restores can fail.

## Restore the most recent dump

```bash
# Pick the newest dump
DUMP=$(ls -1dt ~/qdrant-dumps/claude-memory-* | head -1)
echo "Restoring from: $DUMP"

# Upload each *.snapshot back into Qdrant
for f in "$DUMP"/*.snapshot; do
  col=$(basename "$f" .snapshot)
  echo "→ $col"
  curl -sf -X POST "http://localhost:6333/collections/${col}/snapshots/upload?priority=snapshot" \
       -H "Content-Type:multipart/form-data" \
       -F "snapshot=@${f}" \
    | jq .
done
```

`priority=snapshot` tells Qdrant the uploaded snapshot is authoritative — it will
create the collection if missing and overwrite any partial state.

## Verify

```bash
curl -s http://localhost:6333/collections | jq '.result.collections'
curl -s http://localhost:6333/collections/claude-memory | jq '.result.points_count'
curl -s http://localhost:6333/collections/claude-rag    | jq '.result.points_count'
```

Point counts should match what you had before the wipe (check `~/qdrant-dumps/.snapshot.log`
for the snapshot sizes recorded around the time of the dump).

## Restore a specific dump

```bash
DUMP=~/qdrant-dumps/claude-memory-YYYYMMDD-HHMMSS-PID   # adjust as needed
# then run the same loop as above
```

## Notes

- The MCP servers (`claude-memory`, `claude-rag`) auto-reconnect — no Claude Code
  restart needed once collections are back.
- If a collection already exists with the wrong vector config, delete it first:
  `curl -X DELETE http://localhost:6333/collections/<name>`.
- Dumps are uncompressed `.snapshot` archives produced by Qdrant's snapshot API;
  do not edit or rename them.
