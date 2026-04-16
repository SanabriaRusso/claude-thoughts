# RAG — Document Retrieval for Claude Code

Ingest books, papers, and technical documents into Qdrant so Claude Code can search them during sessions. Fully local — no external API calls, no cloud services.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Claude Code Session                      │
│                                                              │
│   User: "How does TCP flow control work?"                    │
│                                                              │
│   Claude calls: mcp__claude-rag__qdrant-find                 │
│   ──────────────────────────────────────────────────────────  │
│                          │                                   │
│   ┌──────────────────────▼──────────────────────┐            │
│   │         mcp-server-qdrant (claude-rag)       │            │
│   │         Runs as MCP stdio subprocess         │            │
│   │                                              │            │
│   │  1. Embeds query with fastembed (local ONNX) │            │
│   │  2. Searches Qdrant collection "claude-rag"  │            │
│   │  3. Returns top-5 matching chunks + metadata │            │
│   └──────────────────────┬──────────────────────┘            │
│                          │ localhost:6333                     │
│   ┌──────────────────────▼──────────────────────┐            │
│   │         Qdrant (Podman container)            │            │
│   │         Collection: claude-rag               │            │
│   │         Vectors: 768d cosine (nomic-embed)   │            │
│   └─────────────────────────────────────────────┘            │
│                                                              │
│   Claude uses retrieved chunks to answer the question        │
└──────────────────────────────────────────────────────────────┘
```

## Communication flows

### Ingestion (offline, one-time per document)

All processing runs locally inside a Podman container. No external queries are made except for the one-time model download.

```
  You                Container (claude-rag-ingest)        Qdrant         Ollama (optional)
   │                          │                            │                  │
   │  ./rag/ingest add ...    │                            │                  │
   │─────────────────────────►│                            │                  │
   │                          │                            │                  │
   │                    1. Parse file                      │                  │
   │                    (PDF/EPUB/MD)                      │                  │
   │                          │                            │                  │
   │                    2. Chunk text                      │                  │
   │                    (500 chars, paragraph-aware)       │                  │
   │                          │                            │                  │
   │                          │  3. Generate chunk context │                  │
   │                          │  (POST /api/generate)      │                  │
   │                          │───────────────────────────────────────────────►│
   │                          │◄───────────────────────────────────────────────│
   │                          │  "This chunk discusses..." │                  │
   │                          │                            │                  │
   │                    4. Embed with fastembed             │                  │
   │                    (nomic-embed-text-v1.5, local ONNX)│                  │
   │                          │                            │                  │
   │                          │  5. Store vectors + payload│                  │
   │                          │  (PUT /collections/...)    │                  │
   │                          │───────────────────────────►│                  │
   │                          │◄───────────────────────────│                  │
   │                          │                            │                  │
   │  Done! N chunks stored   │                            │                  │
   │◄─────────────────────────│                            │                  │
```

### Retrieval (live, during Claude Code sessions)

```
  Claude Code         mcp-server-qdrant             Qdrant
      │                     │                          │
      │  qdrant-find        │                          │
      │  query: "TCP flow"  │                          │
      │────────────────────►│                          │
      │                     │                          │
      │               Embed query                      │
      │               (fastembed, local ONNX)          │
      │                     │                          │
      │                     │  Search collection       │
      │                     │  (POST /points/query)    │
      │                     │─────────────────────────►│
      │                     │◄─────────────────────────│
      │                     │  Top-5 matching points   │
      │                     │                          │
      │  Results:           │                          │
      │  - chunk text       │                          │
      │  - source, chapter  │                          │
      │  - similarity score │                          │
      │◄────────────────────│                          │
```

### Network boundaries

| Connection | From | To | Protocol | Port | When |
|---|---|---|---|---|---|
| Qdrant API | Container / MCP server | Qdrant container | HTTP | 6333 | Ingestion + retrieval |
| Ollama API | Ingest container | Ollama on host | HTTP | 11434 | Ingestion only (optional) |
| Model download | Ingest container / MCP server | HuggingFace Hub | HTTPS | 443 | First run only |

**After first run, no external network access is required.** The embedding model is cached in a Podman volume (`claude-rag-cache`), and all subsequent operations are fully offline.

## What runs locally

| Component | Technology | Runs as | Size |
|---|---|---|---|
| Embedding model | `nomic-ai/nomic-embed-text-v1.5` via fastembed (ONNX) | In-process | ~270 MB (cached) |
| Vector database | Qdrant v1.17.1 | Podman container | ~100 MB image |
| Contextualization | Ollama (any local model, default `gemma3:4b`) | Host process | Varies |
| Ingestion CLI | Python 3.13 + deps | Podman container | ~600 MB image |
| MCP retrieval | `mcp-server-qdrant` via uvx | Subprocess | ~30 MB |

No API keys. No cloud services. No data leaves your machine.

## Quick start

```bash
# 1. Start Qdrant (if not already running)
cd qdrant && podman compose up -d && cd ..

# 2. Build the ingestion image and enable the RAG backend
./rag/setup.sh

# 3. Ingest a document
./rag/ingest add ~/books/tcp-ip-illustrated.pdf \
  --title "TCP/IP Illustrated" \
  --topic "networking"

# 4. Restart Claude Code — qdrant-find is now available for document search
```

## Usage

```bash
# Ingest a document (PDF, EPUB, or Markdown)
./rag/ingest add <file> --title "Title" --topic "subject"

# List ingested documents
./rag/ingest list

# Delete a document
./rag/ingest delete --title "Title"

# Optional: specify a different Ollama model for contextualization
./rag/ingest add book.pdf --title "Book" --topic "subject" --ollama-model qwen3:8b
```

## Contextual retrieval (optional)

If Ollama is running, the ingestion script generates a short context summary for each chunk before embedding. This prepends a sentence like *"This chunk discusses TCP flow control mechanisms in Chapter 5"* to each chunk, improving retrieval accuracy by 35-67% (per [Anthropic's research](https://www.anthropic.com/news/contextual-retrieval)).

```bash
# Install Ollama (macOS)
brew install ollama

# Pull a small model for contextualization
ollama pull gemma3:4b

# Ollama must be running during ingestion
ollama serve &
./rag/ingest add book.pdf --title "Book" --topic "subject"
```

If Ollama is not running, ingestion proceeds without contextualization — chunks are embedded as-is.

## Managing the backend

```bash
./switch-backend.sh enable rag     # Add MCP server + CLAUDE.md section
./switch-backend.sh disable rag    # Remove them
./switch-backend.sh status         # Show all backends
```

Enable/disable is independent of the memory backends (qdrant, memsearch).

## File structure

```
rag/
├── ingest            # CLI wrapper (runs ingest.py inside Podman container)
├── ingest.py         # Ingestion pipeline: parse → chunk → contextualize → embed → store
├── Containerfile     # Container image definition (Python 3.13 + all deps)
├── requirements.txt  # Python dependencies (pinned in image)
├── setup.sh          # Build image + enable backend
├── CLAUDE-rag.md     # Instructions injected into ~/.claude/CLAUDE.md
└── README.md         # This file
```

## What gets patched on your system

| File | What changes |
|---|---|
| `~/.claude.json` | Adds/removes `claude-rag` MCP server entry |
| `~/.claude/CLAUDE.md` | RAG section between `<!-- RAG-BACKEND-START/END -->` markers |

No hooks are installed. No plugins are modified. The RAG backend is purely an MCP server + CLAUDE.md instructions.
