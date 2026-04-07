<!-- MEMORY-BACKEND-START -->
## Semantic Memory (memsearch) — AUTOMATIC

Memory capture is handled automatically by the memsearch plugin. After each turn, the Stop hook summarizes the conversation and appends it to `.memsearch/memory/YYYY-MM-DD.md`.

### At session start
- memsearch automatically injects relevant past memories as context
- For deeper recall, use `/memory-recall <query>` describing what you need
- Example: `/memory-recall what architecture decisions did we make about the auth service?`

### During the session
- State important decisions clearly so they get captured with good summaries
- Use clear prefixes for easier retrieval, e.g.:
  - "[repo-name] Switched to Helm v3 chart structure"
  - "[repo-name] Using kustomize overlays for env separation"

### Memory storage is automatic
- The Stop hook captures each turn as bullet-point summaries
- No manual `qdrant-store` calls needed — memsearch handles this transparently
- Memories are stored as markdown in `.memsearch/memory/` (human-readable, git-trackable)

### If memsearch is not capturing
- Check that the plugin is installed: `claude plugin list`
- Verify config: `memsearch config get embedding.provider`
- Fall back to Qdrant: `cd ~/github/claude-thoughts && ./switch-backend.sh qdrant`
<!-- MEMORY-BACKEND-END -->
