#!/bin/bash
set -euo pipefail

# memsearch first-time installation and configuration
# Installs memsearch with ONNX embeddings, configures the plugin, and activates the backend.

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Installing memsearch with ONNX embeddings..."

if command -v uv &>/dev/null; then
  uv tool install "memsearch[onnx]"
elif command -v pipx &>/dev/null; then
  pipx install "memsearch[onnx]"
elif command -v pip &>/dev/null; then
  pip install "memsearch[onnx]"
else
  echo "ERROR: Need uv, pipx, or pip to install memsearch."
  echo "Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
  exit 1
fi

echo "==> Configuring ONNX embedding provider..."
memsearch config set embedding.provider onnx

echo "==> Installing Claude Code plugin..."
if command -v claude &>/dev/null; then
  # Add the Zilliz marketplace (hosts the memsearch plugin)
  if ! claude plugin marketplace list 2>/dev/null | grep -q "memsearch"; then
    echo "    Adding Zilliz memsearch marketplace..."
    claude plugin marketplace add zilliztech/memsearch || true
  fi
  # Install the plugin
  if claude plugin list 2>/dev/null | grep -q "memsearch"; then
    echo "    Plugin already installed."
  else
    claude plugin install memsearch || {
      echo "    WARNING: Could not install memsearch plugin."
      echo "    Try manually: claude plugin install memsearch"
    }
  fi
else
  echo "    Claude Code CLI not found. Install memsearch plugin manually after installing Claude Code."
fi

echo "==> Pre-warming embedding model (one-time download, ~558MB)..."
memsearch search "warmup" 2>/dev/null || true

echo "==> Activating memsearch backend..."
bash "$REPO_DIR/switch-backend.sh" memsearch

echo ""
echo "Done. Restart Claude Code to activate memsearch."
