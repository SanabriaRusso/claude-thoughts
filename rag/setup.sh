#!/bin/bash
set -euo pipefail

# setup.sh — Build the RAG container image and enable the RAG backend.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# Check for podman
if ! command -v podman &>/dev/null; then
  echo "Error: podman is required but not installed." >&2
  echo "  brew install podman" >&2
  exit 1
fi

echo "[rag] Building container image..."
podman build -t claude-rag-ingest -f "$SCRIPT_DIR/Containerfile" "$SCRIPT_DIR"

echo ""
echo "[rag] Creating model cache volume..."
podman volume exists claude-rag-cache 2>/dev/null || podman volume create claude-rag-cache

echo ""
echo "[rag] Enabling RAG backend..."
"$REPO_DIR/switch-backend.sh" enable rag

echo ""
echo "RAG backend ready. Restart Claude Code to activate."
echo ""
echo "Usage:"
echo "  $SCRIPT_DIR/ingest add <file> --title 'Title' --topic 'subject'"
echo "  $SCRIPT_DIR/ingest list"
echo "  $SCRIPT_DIR/ingest delete --title 'Title'"
echo ""
echo "Optional: install Ollama for contextual retrieval (better search quality)"
echo "  brew install ollama && ollama pull gemma3:4b"
