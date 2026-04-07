#!/bin/bash
set -euo pipefail

# switch-backend.sh — Enable/disable memory backends independently.
#
# Usage:
#   ./switch-backend.sh enable  <qdrant|memsearch>
#   ./switch-backend.sh disable <qdrant|memsearch>
#   ./switch-backend.sh status
#
# Both backends can run simultaneously (default). Disable individually as needed.

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_MD="$HOME/.claude/CLAUDE.md"
SETTINGS="$HOME/.claude/settings.json"

START_MARKER="<!-- MEMORY-BACKEND-START -->"
END_MARKER="<!-- MEMORY-BACKEND-END -->"

ACTION="${1:-}"
BACKEND="${2:-}"

usage() {
  echo "Usage: $0 <enable|disable> <qdrant|memsearch>"
  echo "       $0 status"
  echo ""
  echo "Manage Claude Code memory backends independently."
  echo "  enable  qdrant     — Add Qdrant hooks + MCP (cross-repo memory)"
  echo "  disable qdrant     — Remove Qdrant hooks"
  echo "  enable  memsearch  — Enable memsearch plugin (per-repo auto-capture)"
  echo "  disable memsearch  — Disable memsearch plugin"
  echo "  status             — Show which backends are active"
  exit 1
}

# ─── Helpers ────────────────────────────────────────────────────────────────

ensure_markers() {
  if ! grep -q "$START_MARKER" "$CLAUDE_MD" 2>/dev/null; then
    echo "  Adding section markers to $CLAUDE_MD..."
    local start_line end_line
    start_line=$(grep -n "^## Semantic Memory" "$CLAUDE_MD" | head -1 | cut -d: -f1)
    end_line=$(grep -n "^## General Preferences" "$CLAUDE_MD" | head -1 | cut -d: -f1)

    if [ -z "$start_line" ]; then
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
      local section_end=$((end_line - 1))
      while [ "$section_end" -gt "$start_line" ] && \
            sed -n "${section_end}p" "$CLAUDE_MD" | grep -q '^[[:space:]]*$'; do
        section_end=$((section_end - 1))
      done
      sed -i '' "$((section_end))a\\
${END_MARKER}" "$CLAUDE_MD"
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

  local start_line end_line total_lines
  start_line=$(grep -n "$START_MARKER" "$CLAUDE_MD" | head -1 | cut -d: -f1)
  end_line=$(grep -n "$END_MARKER" "$CLAUDE_MD" | head -1 | cut -d: -f1)
  total_lines=$(wc -l < "$CLAUDE_MD")

  {
    if [ "$start_line" -gt 1 ]; then
      head -n "$((start_line - 1))" "$CLAUDE_MD"
    fi
    cat "$source_file"
    if [ "$end_line" -lt "$total_lines" ]; then
      tail -n "+$((end_line + 1))" "$CLAUDE_MD"
    fi
  } > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
}

# Determine which CLAUDE-memory.md to use based on active backends
patch_claude_md() {
  local qdrant_on="$1"
  local memsearch_on="$2"

  if [ "$qdrant_on" = "true" ] && [ "$memsearch_on" = "true" ]; then
    replace_memory_section "$REPO_DIR/both/CLAUDE-memory.md"
  elif [ "$qdrant_on" = "true" ]; then
    replace_memory_section "$REPO_DIR/qdrant/CLAUDE-memory.md"
  elif [ "$memsearch_on" = "true" ]; then
    replace_memory_section "$REPO_DIR/memsearch/CLAUDE-memory.md"
  else
    # Both off — clear the section
    ensure_markers
    local start_line end_line total_lines
    start_line=$(grep -n "$START_MARKER" "$CLAUDE_MD" | head -1 | cut -d: -f1)
    end_line=$(grep -n "$END_MARKER" "$CLAUDE_MD" | head -1 | cut -d: -f1)
    total_lines=$(wc -l < "$CLAUDE_MD")
    {
      if [ "$start_line" -gt 1 ]; then
        head -n "$((start_line - 1))" "$CLAUDE_MD"
      fi
      echo "$START_MARKER"
      echo "## Semantic Memory — DISABLED"
      echo "No memory backends are active. Enable one with: ./switch-backend.sh enable <qdrant|memsearch>"
      echo "$END_MARKER"
      if [ "$end_line" -lt "$total_lines" ]; then
        tail -n "+$((end_line + 1))" "$CLAUDE_MD"
      fi
    } > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "$CLAUDE_MD"
  fi
  echo "  CLAUDE.md patched."
}

install_qdrant_hooks() {
  if [ ! -f "$SETTINGS" ]; then
    echo "  Creating $SETTINGS..."
    echo '{}' > "$SETTINGS"
  fi

  mkdir -p "$HOME/.claude/hooks"
  cp "$REPO_DIR/qdrant/hooks/session-start-memory.sh" "$HOME/.claude/hooks/"
  cp "$REPO_DIR/qdrant/hooks/session-stop-memory.sh" "$HOME/.claude/hooks/"
  chmod +x "$HOME/.claude/hooks/session-start-memory.sh"
  chmod +x "$HOME/.claude/hooks/session-stop-memory.sh"

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

  jq '
    .hooks.SessionStart = [.hooks.SessionStart[]? | select(.hooks | all(.command != "~/.claude/hooks/session-start-memory.sh"))] |
    .hooks.Stop = [.hooks.Stop[]? | select(.hooks | all(.command != "~/.claude/hooks/session-stop-memory.sh"))] |
    if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end |
    if (.hooks.Stop | length) == 0 then del(.hooks.Stop) else . end |
    if (.hooks | length) == 0 then del(.hooks) else . end
  ' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"

  echo "  Qdrant hooks removed."
}

manage_memsearch_plugin() {
  local action="$1"

  if ! command -v claude &>/dev/null; then
    echo "  Claude CLI not found, skipping plugin $action."
    return
  fi

  if ! claude plugin list 2>/dev/null | grep -q "memsearch"; then
    if [ "$action" = "enable" ]; then
      echo "  memsearch plugin not installed. Installing..."
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

  if claude plugin "$action" memsearch 2>/dev/null; then
    echo "  memsearch plugin ${action}d."
  else
    echo "  memsearch plugin already ${action}d."
  fi
}

# ─── Status detection ───────────────────────────────────────────────────────

is_qdrant_enabled() {
  [ -f "$SETTINGS" ] && \
  jq -e '.hooks.SessionStart // [] | map(.hooks[]?.command) | any(. == "~/.claude/hooks/session-start-memory.sh")' "$SETTINGS" >/dev/null 2>&1
}

is_memsearch_enabled() {
  [ -f "$SETTINGS" ] && \
  jq -e '.enabledPlugins["memsearch@memsearch-plugins"] == true' "$SETTINGS" >/dev/null 2>&1
}

show_status() {
  echo "Memory backend status:"
  echo ""
  if is_qdrant_enabled; then
    echo "  qdrant:    ON  (cross-repo, manual via MCP)"
  else
    echo "  qdrant:    OFF"
  fi
  if is_memsearch_enabled; then
    echo "  memsearch: ON  (per-repo, automatic via plugin)"
  else
    echo "  memsearch: OFF"
  fi
  echo ""
}

# ─── Main ───────────────────────────────────────────────────────────────────

case "$ACTION" in
  status)
    show_status
    exit 0
    ;;
  enable)
    [ -z "$BACKEND" ] && usage
    case "$BACKEND" in
      qdrant)
        echo "[memory] Enabling Qdrant..."
        install_qdrant_hooks
        # Determine memsearch state for CLAUDE.md
        if is_memsearch_enabled; then
          patch_claude_md "true" "true"
        else
          patch_claude_md "true" "false"
        fi
        ;;
      memsearch)
        echo "[memory] Enabling memsearch..."
        manage_memsearch_plugin "enable"
        if is_qdrant_enabled; then
          patch_claude_md "true" "true"
        else
          patch_claude_md "false" "true"
        fi
        ;;
      *) usage ;;
    esac
    ;;
  disable)
    [ -z "$BACKEND" ] && usage
    case "$BACKEND" in
      qdrant)
        echo "[memory] Disabling Qdrant..."
        remove_qdrant_hooks
        if is_memsearch_enabled; then
          patch_claude_md "false" "true"
        else
          patch_claude_md "false" "false"
        fi
        ;;
      memsearch)
        echo "[memory] Disabling memsearch..."
        manage_memsearch_plugin "disable"
        if is_qdrant_enabled; then
          patch_claude_md "true" "false"
        else
          patch_claude_md "false" "false"
        fi
        ;;
      *) usage ;;
    esac
    ;;
  *)
    usage
    ;;
esac

echo ""
show_status
echo "Restart Claude Code to apply."
