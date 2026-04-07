<!-- MEMORY-BACKEND-START -->
## Semantic Memory (Qdrant + MCP) — MANDATORY
IMPORTANT: You MUST use `mcp__claude-memory__qdrant-store` to persist knowledge before the session ends. This is a BLOCKING REQUIREMENT — do not end a session without storing memories. Treat this with the same priority as not breaking production code.

### At session start
- Search claude-memory MCP with relevant keywords, `repo:<name>`, and `topic:<area>` tags
- Use findings to inform your approach and avoid repeating past mistakes

### Before ending ANY session (when you receive the Stop hook or are about to give your final response)
You MUST call `mcp__claude-memory__qdrant-store` for each of the following that apply:
- Architecture decisions made or discussed
- Gotchas, bugs, or non-obvious behaviors discovered
- Lessons learned from corrections or failed approaches
- Cross-repo knowledge or integration points
- Project context that would help future sessions

### Storage format
- Always include metadata: `{"repo": "<project-name>", "topic": "<area>"}`
- Write memories as standalone facts (future sessions have no conversation context)
- One memory per distinct topic — don't bundle unrelated things

### If nothing worth storing
- At minimum, store a brief session summary: what was worked on, what was decided, what's pending

### If Qdrant is unreachable
- The SessionStart hook will attempt automatic recovery (podman start → podman-compose up)
- If recovery fails, **immediately inform the user** — do NOT silently proceed without memory
- Ask the user: "Qdrant is down and auto-recovery failed. Want to troubleshoot or proceed without semantic memory?"
- Never skip memory storage silently
<!-- MEMORY-BACKEND-END -->
