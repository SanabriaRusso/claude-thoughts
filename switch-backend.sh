#!/bin/bash
set -euo pipefail

# switch-backend.sh — Toggle between Qdrant and memsearch memory backends.
#
# Usage: ./switch-backend.sh <qdrant|memsearch>
#
# This script:
#   1. Patches ~/.claude/CLAUDE.md with the selected backend's memory section
#   2. Adds/removes Qdrant session hooks in ~/.claude/settings.json
#   3. Enables/disables the memsearch plugin (if available)
#   4. Records the active backend in .active-backend

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
SETTINGS="$HOME/.claude/settings.json"
BACKEND="${1:-}"

START_MARKER="<!-- MEMORY-BACKEND-START -->"
END_MARKER="<!-- MEMORY-BACKEND-END -->"

QDRANT_START_HOOK="~/.claude/hooks/session-start-memory.sh"
QDRANT_STOP_HOOK="~/.claude/hooks/session-stop-memory.sh"

usage() {
  echo "Usage: $0 <qdrant|memsearch>"
  echo ""
  echo "Switches the active Claude Code memory backend."
  echo "  qdrant     — Qdrant vector DB + MCP server (requires podman)"
  echo "  memsearch  — Zilliz memsearch plugin (zero infra)"
  exit 1
}

[ -z "$BACKEND" ] && usage

# ─── Helpers ────────────────────────────────────────────────────────────────

ensure_markers() {
  # If CLAUDE.md doesn't have our markers yet, wrap the existing memory section
  if ! grep -q "$START_MARKER" "$CLAUDE_MD" 2>/dev/null; then
    echo "  Adding section markers to $CLAUDE_MD..."

    # Find the memory section bounds: from "## Semantic Memory" to before "## General Preferences"
    local start_line end_line
    start_line=$(grep -n "^## Semantic Memory" "$CLAUDE_MD" | head -1 | cut -d: -f1)
    end_line=$(grep -n "^## General Preferences" "$CLAUDE_MD" | head -1 | cut -d: -f1)

    if [ -z "$start_line" ]; then
      # No memory section exists — append markers before "## General Preferences" or at end
      if [ -n "$end_line" ]; then
        sed -i '' "${end_line}i\\
\\
${START_MARKER}\\
${END_MARKER}\\
" "$CLAUDE_MD"
      else
        printf "\n\n%s\n%s\n" "$START_MARKER" "$END_MARKER" >> "$CLAUDE_MD"
      fi
    else
      # Wrap existing section with markers
      # end_line points to "## General Preferences", so the memory section ends one line before
      local section_end=$((end_line - 1))
      # Trim trailing blank lines before the end marker
      while [ "$section_end" -gt "$start_line" ] && \
            sed -n "${section_end}p" "$CLAUDE_MD" | grep -q '^[[:space:]]*$'; do
        section_end=$((section_end - 1))
      done

      # Insert end marker after the last content line
      sed -i '' "$((section_end))a\\
${END_MARKER}" "$CLAUDE_MD"
      # Insert start marker before the section heading
      sed -i '' "$((start_line))i\\
${START_MARKER}" "$CLAUDE_MD"
    fi
  fi
}

replace_memory_section() {
  local source_file="$1"

  if [ ! -f "$source_file" ]; then
    echo "ERROR: $source_file not found" >&2
    exit 1
  fi

  ensure_markers

  # Replace everything between (and including) the markers with the source file.
  # Strategy: print lines before START, cat the source file, print lines after END.
  local start_line end_line total_lines
  start_line=$(grep -n "$START_MARKER" "$CLAUDE_MD" | head -1 | cut -d: -f1)
  end_line=$(grep -n "$END_MARKER" "$CLAUDE_MD" | head -1 | cut -d: -f1)
  total_lines=$(wc -l < "$CLAUDE_MD")

  {
    # Lines before the start marker
    if [ "$start_line" -gt 1 ]; then
      head -n "$((start_line - 1))" "$CLAUDE_MD"
    fi
    # The replacement content (already includes its own markers)
    cat "$source_file"
    # Lines after the end marker
    if [ "$end_line" -lt "$total_lines" ]; then
      tail -n "+$((end_line + 1))" "$CLAUDE_MD"
    fi
  } > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
}

install_qdrant_hooks() {
  if [ ! -f "$SETTINGS" ]; then
    echo "  Creating $SETTINGS..."
    echo '{}' > "$SETTINGS"
  fi

  # Copy hook scripts to ~/.claude/hooks/
  mkdir -p "$HOME/.claude/hooks"
  cp "$REPO_DIR/qdrant/hooks/session-start-memory.sh" "$HOME/.claude/hooks/"
  cp "$REPO_DIR/qdrant/hooks/session-stop-memory.sh" "$HOME/.claude/hooks/"
  chmod +x "$HOME/.claude/hooks/session-start-memory.sh"
  chmod +x "$HOME/.claude/hooks/session-stop-memory.sh"

  # Add hooks to settings.json if not already present
  local has_start has_stop
  has_start=$(jq -r '.hooks.SessionStart // [] | map(.hooks[]?.command) | any(. == "~/.claude/hooks/session-start-memory.sh")' "$SETTINGS" 2>/dev/null || echo "false")
  has_stop=$(jq -r '.hooks.Stop // [] | map(.hooks[]?.command) | any(. == "~/.claude/hooks/session-stop-memory.sh")' "$SETTINGS" 2>/dev/null || echo "false")

  if [ "$has_start" != "true" ]; then
    jq '.hooks.SessionStart = (.hooks.SessionStart // []) + [{"hooks": [{"type": "command", "command": "~/.claude/hooks/session-start-memory.sh", "timeout": 15}]}]' \
      "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
  fi

  if [ "$has_stop" != "true" ]; then
    jq '.hooks.Stop = (.hooks.Stop // []) + [{"hooks": [{"type": "command", "command": "~/.claude/hooks/session-stop-memory.sh", "timeout": 5}]}]' \
      "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
  fi

  echo "  Qdrant hooks installed."
}

remove_qdrant_hooks() {
  if [ ! -f "$SETTINGS" ]; then
    return
  fi

  # Remove only the Qdrant-specific hook entries, preserve others
  jq '
    .hooks.SessionStart = [.hooks.SessionStart[]? | select(.hooks | all(.command != "~/.claude/hooks/session-start-memory.sh"))] |
    .hooks.Stop = [.hooks.Stop[]? | select(.hooks | all(.command != "~/.claude/hooks/session-stop-memory.sh"))] |
    # Clean up empty arrays
    if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end |
    if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end |
    if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"

  echo "  Qdrant hooks removed."
}

manage_memsearch_plugin() {
  local action="$1"  # "enable" or "disable"

  if ! command -v claude &>/dev/null; then
    echo "  Claude CLI not found, skipping plugin $action."
    return
  fi

  # Check if memsearch is installed
  if ! claude plugin list 2>/dev/null | grep -q "memsearch"; then
    if [ "$action" = "enable" ]; then
      echo "  memsearch plugin not installed. Installing..."
      # Add the Zilliz marketplace if not already present
      if ! claude plugin marketplace list 2>/dev/null | grep -q "memsearch"; then
        claude plugin marketplace add zilliztech/memsearch 2>/dev/null || true
      fi
      claude plugin install memsearch 2>/dev/null || {
        echo "  WARNING: Could not install memsearch plugin. Install manually:"
        echo "    claude plugin marketplace add zilliztech/memsearch"
        echo "    claude plugin install memsearch"
        return
      }
      echo "  memsearch plugin installed and enabled."
      return
    else
      echo "  memsearch plugin not installed, nothing to disable."
      return
    fi
  fi

  # Plugin exists — enable or disable it
  if claude plugin "$action" memsearch 2>/dev/null; then
    echo "  memsearch plugin ${action}d."
  else
    # "already enabled/disabled" exits non-zero, which is fine
    echo "  memsearch plugin already ${action}d."
  fi
}

# ─── Main ───────────────────────────────────────────────────────────────────

case "$BACKEND" in
  qdrant)
    echo "[switch] Activating Qdrant backend..."
    replace_memory_section "$REPO_DIR/qdrant/CLAUDE-memory.md"
    echo "  CLAUDE.md patched with Qdrant memory section."
    install_qdrant_hooks
    manage_memsearch_plugin "disable"
    echo "qdrant" > "$REPO_DIR/.active-backend"
    echo ""
    echo "[switch] Qdrant backend active. Restart Claude Code to apply."
    ;;
  memsearch)
    echo "[switch] Activating memsearch backend..."
    replace_memory_section "$REPO_DIR/memsearch/CLAUDE-memory.md"
    echo "  CLAUDE.md patched with memsearch memory section."
    remove_qdrant_hooks
    manage_memsearch_plugin "enable"
    echo "memsearch" > "$REPO_DIR/.active-backend"
    echo ""
    echo "[switch] memsearch backend active. Restart Claude Code to apply."
    ;;
  *)
    usage
    ;;
esac
