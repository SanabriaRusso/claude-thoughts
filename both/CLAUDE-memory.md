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
- Store through `/wrap-session` (it dedupes by point ID and verifies every write); an ad-hoc `mcp__claude-memory__qdrant-store` is acceptable for a single urgent fact
- Always include metadata: `{"repo": "<project-name>", "topic": "<area>", "category": "decision|gotcha|lesson|integration|context"}`
- Write memories fact-first: only the first ~350 characters are embedded, so the opening sentence must state the fact

### When to use which
- **memsearch handles day-to-day** — session context is captured automatically, no action needed
- **Qdrant for cross-repo and high-signal items** — architecture decisions, integration points, gotchas that matter across projects. Store these explicitly via MCP.

### Before ending a session
- memsearch auto-captures — no action needed for per-repo context
- **Canonical path: say the session is ending ("let's wrap the session", "done for today") or run `/wrap-session`.** The skill surveys the conversation and today's memsearch capture, dedupes against existing memories by point ID, supersedes stale ones, and stores high-signal items with `{repo, topic, category}` metadata
- Claude may run it in a fork subagent (inherits the conversation); an agent without the conversation passes a digest as the argument
- Hooks nudge, they do not store: UserPromptSubmit flags a session-end phrase, and Stop blocks once per such signal if nothing was stored since
- If Qdrant is unreachable, skip it — memsearch still captures locally

### If memsearch is not capturing
- Check plugin: `claude plugin list`
- Fall back: `cd ~/github/claude-thoughts && ./switch-backend.sh disable memsearch`

### If Qdrant is unreachable
- The SessionStart hook attempts auto-recovery (podman start → podman-compose up)
- If recovery fails, inform the user — memsearch still works independently
<!-- MEMORY-BACKEND-END -->
