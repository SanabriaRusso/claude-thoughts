#!/usr/bin/env python3
"""Document ingestion CLI for Claude Code RAG.

Parses PDF, EPUB, and Markdown files into chunks, optionally contextualizes
them via Ollama, embeds with fastembed, and stores in Qdrant for retrieval
by Claude Code's MCP-based qdrant-find tool.
"""

import argparse
import re
import sys
from pathlib import Path

import httpx
from qdrant_client import QdrantClient
from qdrant_client.models import FieldCondition, Filter, MatchValue

# ── Configuration ──────────────────────────────────────────────────────────

import os

QDRANT_URL = os.environ.get("QDRANT_URL", "http://localhost:6333")
COLLECTION_NAME = "claude-rag"
EMBEDDING_MODEL = "nomic-ai/nomic-embed-text-v1.5"
OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://localhost:11434")
OLLAMA_MODEL = os.environ.get("OLLAMA_MODEL", "gemma3:4b")
CHUNK_SIZE = 500
CHUNK_OVERLAP = 50


# ── Parsers ────────────────────────────────────────────────────────────────


def parse_pdf(path):
    """Extract text with chapter/page structure from PDF."""
    import fitz  # pymupdf

    doc = fitz.open(path)
    sections = []
    current_chapter = "Introduction"

    for page_num in range(len(doc)):
        page = doc[page_num]
        blocks = page.get_text("dict", sort=True)["blocks"]

        page_text_parts = []
        for block in blocks:
            if "lines" not in block:
                continue
            for line in block["lines"]:
                text = "".join(span["text"] for span in line["spans"]).strip()
                if not text:
                    continue

                # Detect chapter headings via font size heuristic
                max_font_size = max(span["size"] for span in line["spans"])
                if max_font_size >= 16 and len(text) < 120:
                    # Likely a chapter/section heading
                    if page_text_parts:
                        sections.append(
                            {
                                "text": "\n".join(page_text_parts),
                                "chapter": current_chapter,
                                "page": page_num + 1,
                            }
                        )
                        page_text_parts = []
                    current_chapter = text
                else:
                    page_text_parts.append(text)

        if page_text_parts:
            sections.append(
                {
                    "text": "\n".join(page_text_parts),
                    "chapter": current_chapter,
                    "page": page_num + 1,
                }
            )

    doc.close()
    return sections


def parse_epub(path):
    """Extract text with chapter structure from EPUB."""
    import ebooklib
    from ebooklib import epub
    from bs4 import BeautifulSoup

    book = epub.read_epub(str(path))
    sections = []

    for item in book.get_items_of_type(ebooklib.ITEM_DOCUMENT):
        soup = BeautifulSoup(item.get_content(), "html.parser")

        # Extract chapter title from first heading
        heading = soup.find(["h1", "h2", "h3"])
        chapter_title = heading.get_text(strip=True) if heading else "Untitled Section"

        text = soup.get_text(separator="\n", strip=True)
        if text.strip():
            sections.append(
                {
                    "text": text,
                    "chapter": chapter_title,
                    "page": None,
                }
            )

    return sections


def parse_markdown(path):
    """Extract text with heading structure from Markdown."""
    content = Path(path).read_text(encoding="utf-8")
    sections = []
    current_chapter = "Introduction"
    current_lines = []

    for line in content.split("\n"):
        heading_match = re.match(r"^(#{1,3})\s+(.+)", line)
        if heading_match:
            # Flush current section
            if current_lines:
                text = "\n".join(current_lines).strip()
                if text:
                    sections.append(
                        {
                            "text": text,
                            "chapter": current_chapter,
                            "page": None,
                        }
                    )
                current_lines = []
            current_chapter = heading_match.group(2).strip()
        else:
            current_lines.append(line)

    # Flush final section
    if current_lines:
        text = "\n".join(current_lines).strip()
        if text:
            sections.append(
                {
                    "text": text,
                    "chapter": current_chapter,
                    "page": None,
                }
            )

    return sections


PARSERS = {
    ".pdf": parse_pdf,
    ".epub": parse_epub,
    ".md": parse_markdown,
    ".markdown": parse_markdown,
}


# ── Chunking ───────────────────────────────────────────────────────────────


def chunk_sections(sections, chunk_size=CHUNK_SIZE, overlap=CHUNK_OVERLAP):
    """Split sections into chunks respecting paragraph and sentence boundaries.

    Returns a list of dicts with text, chapter, and page.
    """
    all_chunks = []

    for section in sections:
        text = section["text"].strip()
        if not text:
            continue

        paragraphs = re.split(r"\n\s*\n", text)
        current_chunk = ""

        for para in paragraphs:
            para = para.strip()
            if not para:
                continue

            if len(current_chunk) + len(para) + 2 <= chunk_size:
                current_chunk = f"{current_chunk}\n\n{para}".strip()
            else:
                if current_chunk:
                    all_chunks.append(
                        {
                            "text": current_chunk,
                            "chapter": section["chapter"],
                            "page": section.get("page"),
                        }
                    )
                # Handle paragraphs longer than chunk_size
                if len(para) > chunk_size:
                    sentences = re.split(r"(?<=[.!?])\s+", para)
                    current_chunk = ""
                    for sentence in sentences:
                        if len(current_chunk) + len(sentence) + 1 <= chunk_size:
                            current_chunk = f"{current_chunk} {sentence}".strip()
                        else:
                            if current_chunk:
                                all_chunks.append(
                                    {
                                        "text": current_chunk,
                                        "chapter": section["chapter"],
                                        "page": section.get("page"),
                                    }
                                )
                            # If a single sentence exceeds chunk_size, take it as-is
                            current_chunk = sentence
                else:
                    current_chunk = para

        if current_chunk:
            all_chunks.append(
                {
                    "text": current_chunk,
                    "chapter": section["chapter"],
                    "page": section.get("page"),
                }
            )

    # Apply overlap: prepend tail of previous chunk
    if overlap > 0 and len(all_chunks) > 1:
        for i in range(len(all_chunks) - 1, 0, -1):
            prev_tail = all_chunks[i - 1]["text"][-overlap:]
            # Find a clean word boundary for the overlap
            space_idx = prev_tail.find(" ")
            if space_idx > 0:
                prev_tail = prev_tail[space_idx + 1 :]
            all_chunks[i]["text"] = f"...{prev_tail} {all_chunks[i]['text']}"

    return all_chunks


# ── Contextual Retrieval (Ollama) ──────────────────────────────────────────


def check_ollama():
    """Check if Ollama is reachable."""
    try:
        r = httpx.get(f"{OLLAMA_URL}/api/tags", timeout=5.0)
        return r.status_code == 200
    except (httpx.ConnectError, httpx.TimeoutException):
        return False


def contextualize_chunk(chunk_text, chapter, prev_chunk=None, next_chunk=None, model=OLLAMA_MODEL):
    """Generate a context prefix for a chunk using Ollama."""
    context_parts = []
    if chapter:
        context_parts.append(f"Chapter: {chapter}")
    if prev_chunk:
        context_parts.append(f"Previous text: ...{prev_chunk[-200:]}")
    if next_chunk:
        context_parts.append(f"Next text: {next_chunk[:200]}...")

    surrounding = "\n".join(context_parts)

    prompt = (
        f"<surrounding_context>\n{surrounding}\n</surrounding_context>\n\n"
        f"<chunk>\n{chunk_text}\n</chunk>\n\n"
        "Give a short succinct context (1-2 sentences) to situate this chunk "
        "within the overall document for the purposes of improving search "
        "retrieval of the chunk. Answer only with the succinct context and nothing else."
    )

    try:
        response = httpx.post(
            f"{OLLAMA_URL}/api/generate",
            json={"model": model, "prompt": prompt, "stream": False},
            timeout=60.0,
        )
        if response.status_code == 200:
            context = response.json().get("response", "").strip()
            if context:
                return f"{context}\n\n{chunk_text}"
    except (httpx.ConnectError, httpx.TimeoutException):
        pass

    return chunk_text


def contextualize_chunks(chunks, model=OLLAMA_MODEL):
    """Add contextual prefixes to all chunks. Modifies chunks in place."""
    if not check_ollama():
        print("  Ollama not available — skipping contextualization")
        for chunk in chunks:
            chunk["contextualized"] = False
        return

    print(f"  Contextualizing with Ollama ({model})...")
    for i, chunk in enumerate(chunks):
        prev_text = chunks[i - 1]["text"] if i > 0 else None
        next_text = chunks[i + 1]["text"] if i < len(chunks) - 1 else None
        original_text = chunk["text"]
        chunk["text"] = contextualize_chunk(original_text, chunk["chapter"], prev_text, next_text, model)
        chunk["contextualized"] = chunk["text"] != original_text
        if (i + 1) % 10 == 0 or i + 1 == len(chunks):
            print(f"    {i + 1}/{len(chunks)}")


# ── Qdrant Operations ─────────────────────────────────────────────────────


def get_client():
    """Create a Qdrant client with the RAG embedding model configured."""
    client = QdrantClient(url=QDRANT_URL)
    client.set_model(EMBEDDING_MODEL)
    return client


def collection_exists(client):
    """Check if the RAG collection exists."""
    return COLLECTION_NAME in [c.name for c in client.get_collections().collections]


def document_exists(client, title):
    """Check if a document with this title already has chunks stored."""
    if not collection_exists(client):
        return False
    try:
        results, _ = client.scroll(
            collection_name=COLLECTION_NAME,
            scroll_filter=Filter(
                must=[FieldCondition(key="source", match=MatchValue(value=title))]
            ),
            limit=1,
            with_payload=False,
            with_vectors=False,
        )
        return len(results) > 0
    except Exception:
        return False


# ── Commands ───────────────────────────────────────────────────────────────


def cmd_add(args):
    """Ingest a document into Qdrant."""
    path = Path(args.file)
    if not path.exists():
        print(f"Error: {path} not found", file=sys.stderr)
        sys.exit(1)

    ext = path.suffix.lower()
    if ext not in PARSERS:
        print(
            f"Error: unsupported format '{ext}'. Supported: {', '.join(PARSERS.keys())}",
            file=sys.stderr,
        )
        sys.exit(1)

    client = get_client()

    # Check for duplicates
    if document_exists(client, args.title):
        print(f"Document '{args.title}' already exists. Delete it first with:")
        print(f"  python {__file__} delete --title '{args.title}'")
        sys.exit(1)

    # 1. Parse
    print(f"Parsing {path.name}...")
    sections = PARSERS[ext](path)
    print(f"  {len(sections)} sections extracted")

    # 2. Chunk
    print("Chunking...")
    chunks = chunk_sections(sections)
    print(f"  {len(chunks)} chunks generated")

    if not chunks:
        print("No content to ingest.", file=sys.stderr)
        sys.exit(1)

    # 3. Contextualize (Ollama)
    contextualize_chunks(chunks, model=args.ollama_model)

    # 4. Embed + Store
    # Uses qdrant-client's built-in fastembed integration (client.add).
    # This auto-creates the collection with the correct named vector config
    # matching what mcp-server-qdrant expects for the same embedding model.
    print("Embedding and storing in Qdrant...")
    total_chunks = len(chunks)
    client.add(
        collection_name=COLLECTION_NAME,
        documents=[c["text"] for c in chunks],
        metadata=[
            {
                "source": args.title,
                "topic": args.topic,
                "chapter": c["chapter"],
                "page": c.get("page"),
                "chunk_index": i,
                "total_chunks": total_chunks,
                "contextualized": c.get("contextualized", False),
            }
            for i, c in enumerate(chunks)
        ],
        batch_size=100,
    )

    ctx_count = sum(1 for c in chunks if c.get("contextualized"))
    print(f"\nDone! {total_chunks} chunks stored in '{COLLECTION_NAME}'.")
    print(f"  Document: {args.title}")
    print(f"  Topic:    {args.topic}")
    print(f"  Contextualized: {ctx_count}/{total_chunks} chunks")


def cmd_list(args):
    """List all ingested documents."""
    client = get_client()

    if not collection_exists(client):
        print("No documents ingested yet.")
        return

    documents = {}
    offset = None
    while True:
        results, next_offset = client.scroll(
            collection_name=COLLECTION_NAME,
            limit=100,
            offset=offset,
            with_payload=True,
            with_vectors=False,
        )
        for point in results:
            payload = point.payload
            source = payload.get("source", "Unknown")
            if source not in documents:
                documents[source] = {
                    "topic": payload.get("topic", ""),
                    "chunks": 0,
                    "contextualized": 0,
                }
            documents[source]["chunks"] += 1
            if payload.get("contextualized"):
                documents[source]["contextualized"] += 1

        if next_offset is None:
            break
        offset = next_offset

    if not documents:
        print("No documents ingested yet.")
        return

    print(f"Ingested documents ({len(documents)}):\n")
    for name, info in sorted(documents.items()):
        ctx = f"{info['contextualized']}/{info['chunks']}"
        print(f"  {name}")
        print(f"    Topic: {info['topic']}  |  Chunks: {info['chunks']}  |  Contextualized: {ctx}")
        print()


def cmd_delete(args):
    """Delete all chunks for a document."""
    client = get_client()

    if not collection_exists(client):
        print("No documents ingested yet.")
        return

    # Collect matching point IDs
    point_ids = []
    offset = None
    while True:
        results, next_offset = client.scroll(
            collection_name=COLLECTION_NAME,
            scroll_filter=Filter(
                must=[FieldCondition(key="source", match=MatchValue(value=args.title))]
            ),
            limit=100,
            offset=offset,
            with_payload=False,
            with_vectors=False,
        )
        point_ids.extend([p.id for p in results])
        if next_offset is None:
            break
        offset = next_offset

    if not point_ids:
        print(f"No chunks found for document '{args.title}'")
        return

    client.delete(
        collection_name=COLLECTION_NAME,
        points_selector=point_ids,
    )
    print(f"Deleted {len(point_ids)} chunks for '{args.title}'")


# ── CLI ────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(
        description="Ingest documents into Qdrant for Claude Code RAG",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  %(prog)s add book.pdf --title 'TCP/IP Illustrated' --topic networking\n"
            "  %(prog)s list\n"
            "  %(prog)s delete --title 'TCP/IP Illustrated'\n"
        ),
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # add
    p_add = subparsers.add_parser("add", help="Ingest a document")
    p_add.add_argument("file", help="Path to document (PDF, EPUB, or Markdown)")
    p_add.add_argument("--title", required=True, help="Document title for identification")
    p_add.add_argument("--topic", required=True, help="Subject/topic tag")
    p_add.add_argument(
        "--ollama-model",
        default=OLLAMA_MODEL,
        help=f"Ollama model for contextualization (default: {OLLAMA_MODEL})",
    )
    p_add.set_defaults(func=cmd_add)

    # list
    p_list = subparsers.add_parser("list", help="List ingested documents")
    p_list.set_defaults(func=cmd_list)

    # delete
    p_del = subparsers.add_parser("delete", help="Delete a document's chunks")
    p_del.add_argument("--title", required=True, help="Document title to delete")
    p_del.set_defaults(func=cmd_delete)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
