<!-- RAG-BACKEND-START -->
## Reference Documents (RAG)

Ingested reference materials are searchable via `mcp__claude-rag__qdrant-find`.

### When to search
- When the user asks about a subject covered by ingested materials
- When you need domain-specific knowledge beyond your training data
- When the user says "check the docs/books" or similar

### How to search
- Call `mcp__claude-rag__qdrant-find` with a natural language query
- Results include text passages with source metadata (document, chapter, page)
- Try multiple query angles if the first search doesn't surface what you need

### What's available
- Run `~/github/claude-thoughts/rag/ingest list` to see ingested documents
<!-- RAG-BACKEND-END -->
