# memsearch Memory Backend

Zero-infra semantic memory for Claude Code using [memsearch](https://github.com/zilliztech/memsearch) by Zilliz.

## How it works

memsearch auto-captures session context via a Stop hook — each Claude response is
summarized by Haiku and appended to daily markdown files. On each new prompt, it
auto-recalls the top-3 relevant memories and injects them into context. No manual
tool calls needed.

- **Storage**: Daily markdown files in `.memsearch/memory/YYYY-MM-DD.md`
- **Embeddings**: Local ONNX (bge-m3), no API keys
- **Index**: Milvus Lite (rebuildable from the markdown files)
- **Cross-agent**: Works with Claude Code, OpenClaw, OpenCode, Codex

## Setup

### Quick start

```bash
cd claude-thoughts
./memsearch/setup.sh
```

The setup script will:
1. Install memsearch with ONNX embeddings
2. Configure the embedding provider
3. Install the Claude Code plugin (if available)
4. Download the embedding model (~558MB, one-time)
5. Activate memsearch as the active backend

### Manual install

If the setup script doesn't work for your environment:

```bash
# 1. Install the package
pip install "memsearch[onnx]"
# or: pipx install "memsearch[onnx]"
# or: uv tool install "memsearch[onnx]"

# 2. Configure ONNX embeddings
memsearch config set embedding.provider onnx

# 3. Install Claude Code plugin
claude plugin marketplace add zilliztech/memsearch
claude plugin install memsearch

# 4. Activate
./switch-backend.sh memsearch
```

### Activate

From the repo root:

```bash
./switch-backend.sh memsearch
```

This removes Qdrant session hooks and patches `~/.claude/CLAUDE.md` with memsearch-specific instructions.

## Usage

Memory capture and recall are automatic. For explicit recall:

```
> /memory-recall what architecture decisions did we make about auth?
```

## Data

- **Memory files**: `.memsearch/memory/` (per-project, git-trackable)
- **Vector index**: `~/.memsearch/milvus.db` (derived, rebuildable)
- **Embedding model**: `~/.cache/huggingface/` (~558MB ONNX model)

## Configuration

```bash
memsearch config set embedding.provider onnx          # default, local
memsearch config set embedding.provider openai         # needs OPENAI_API_KEY
memsearch config set embedding.provider ollama         # local models
```
