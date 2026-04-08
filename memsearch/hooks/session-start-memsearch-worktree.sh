#!/bin/bash
# SessionStart hook: unify memsearch storage across git worktrees.
#
# When running in a git worktree, replaces the local .memsearch/ with a
# symlink to the main worktree's .memsearch/. Any existing local memories
# are merged first so nothing is lost.
#
# Result: all worktrees of a repo share one memory store. Deleting a
# worktree no longer loses memsearch history.

# Only proceed inside a git repo
git rev-parse --is-inside-work-tree > /dev/null 2>&1 || exit 0

MAIN_GIT_DIR=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
CURRENT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0

# Main worktree root = git common dir minus trailing /.git
MAIN_TOPLEVEL="${MAIN_GIT_DIR%/.git}"

# Not a worktree — nothing to do
[ "$MAIN_TOPLEVEL" != "$CURRENT_TOPLEVEL" ] || exit 0

MAIN_MEMSEARCH="$MAIN_TOPLEVEL/.memsearch"
LOCAL_MEMSEARCH="$CURRENT_TOPLEVEL/.memsearch"

# Already correctly symlinked — done
if [ -L "$LOCAL_MEMSEARCH" ]; then
  target=$(readlink "$LOCAL_MEMSEARCH")
  [ "$target" = "$MAIN_MEMSEARCH" ] && exit 0
  # Points elsewhere — remove stale symlink
  rm "$LOCAL_MEMSEARCH"
fi

# Ensure main .memsearch/memory/ exists
mkdir -p "$MAIN_MEMSEARCH/memory"

# If local .memsearch is a real directory, merge its memories first
if [ -d "$LOCAL_MEMSEARCH" ] && [ ! -L "$LOCAL_MEMSEARCH" ]; then
  if [ -d "$LOCAL_MEMSEARCH/memory" ]; then
    for f in "$LOCAL_MEMSEARCH/memory"/*.md; do
      [ -f "$f" ] || continue
      base=$(basename "$f")
      if [ -f "$MAIN_MEMSEARCH/memory/$base" ]; then
        # Append with separator to avoid blending entries
        printf '\n\n---\n\n' >> "$MAIN_MEMSEARCH/memory/$base"
        cat "$f" >> "$MAIN_MEMSEARCH/memory/$base"
      else
        cp "$f" "$MAIN_MEMSEARCH/memory/$base"
      fi
    done
  fi
  rm -rf "$LOCAL_MEMSEARCH"
fi

# Create symlink: worktree → main repo
ln -s "$MAIN_MEMSEARCH" "$LOCAL_MEMSEARCH"

echo "[memsearch-worktree] Linked worktree .memsearch → $MAIN_MEMSEARCH"
