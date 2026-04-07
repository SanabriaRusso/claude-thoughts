<!-- MEMORY-BACKEND-START -->
## Semantic Memory — DUAL MODE

Two memory backends are active. Use both — they serve different purposes.

### memsearch (automatic, per-repo)
- **Auto-capture**: the Stop hook summarizes each turn and appends to `.memsearch/memory/YYYY-MM-DD.md`
- **Auto-recall**: relevant past memories are injected into context automatically
- **Scope**: current repo only
- For deeper recall, use `/memory-recall <query>`

### Qdrant (manual, cross-repo)
- **Cross-repo search**: a single global collection spans all projects
- Use `mcp__claude-memory__qdrant-find` to search for context from other repos
- Use `mcp__claude-memory__qdrant-store` to persist important decisions, gotchas, and cross-repo knowledge
- Always include metadata: `{"repo": "<project-name>", "topic": "<area>"}`

### When to use which
- **memsearch handles day-to-day** — session context is captured automatically, no action needed
- **Qdrant for cross-repo and high-signal items** — architecture decisions, integration points, gotchas that matter across projects. Store these explicitly via MCP.

### Before ending a session
- memsearch auto-captures — no action needed for per-repo context
- For cross-repo knowledge or major decisions, call `mcp__claude-memory__qdrant-store` with repo/topic metadata
- If Qdrant is unreachable, skip it — memsearch still captures locally

### If memsearch is not capturing
- Check plugin: `claude plugin list`
- Fall back: `cd ~/github/claude-thoughts && ./switch-backend.sh disable memsearch`

### If Qdrant is unreachable
- The SessionStart hook attempts auto-recovery (podman start → podman-compose up)
- If recovery fails, inform the user — memsearch still works independently
<!-- MEMORY-BACKEND-END -->
