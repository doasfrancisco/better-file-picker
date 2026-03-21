#!/bin/bash
# Custom @ file picker for meta-repo with nested git repos.
#
# === ALGORITHM ===
#
# Phase 0: Project root resolution
#   If $1 is provided, uses it as PROJECT_ROOT (for centralized usage from
#   other projects). Otherwise, falls back to BASH_SOURCE[0] to resolve
#   PROJECT_ROOT from the script's own location (.claude/file-suggestion.sh
#   → parent dir). The fallback is immune to cwd drift caused by Claude Code's
#   known working directory bug on Windows.
#
# Phase 1: Index (cached, rebuilds every 300s)
#   Recursive index_repo(dir, prefix):
#     1. git ls-files --cached --others --exclude-standard → tracked + untracked files
#        (saved to variable for reuse in step 2)
#     2. If dir has .meta-repo marker:
#        2.1 git ls-files --others --ignored --exclude-standard → find ignored paths
#        2.2 For each entry ending in / (git collapses dirs with .git that aren't
#            in the parent index — so trailing / = sub-repo):
#            2.2.1 If dir not already covered by step 1 → index_repo() (recurse)
#   Sub-repos indexed in parallel. All paths prefixed for correct nesting.
#   Outputs index.txt (files) + dirs.txt (directories).
#   All git commands use -C to ensure correct scope.
#
# Phase 2: Search (every keystroke)
#
#   Tiered grep on cache. Each tier is fuzzier than the last:
#     Tier 1: dir match → list ALL immediate children from cache (dir + files + subdirs)
#     Tier 2: exact prefix on segment      (e.g. "cata" → catafract/CLAUDE.md)  10
#     Tier 3: segment fuzzy                (c[^/]*a[^/]*t[^/]*a)                10
#     Tier 4: substring anywhere           (literal "cata" in path)              8
#     Tier 5: global fuzzy across segments (c.*a.*t.*a, crosses /)               8
#   All results concatenated, deduped (first occurrence wins), head -15.
#
#   Tier 1 guarantees all subdirs of the matched directory always show.
#   Tiers 2-5 fill remaining slots with broader matches.
#

PROJECT_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_HASH=$(echo "$PROJECT_ROOT" | md5sum | cut -d' ' -f1)
CACHE_DIR="$HOME/.cache-better-file-picker/${PROJECT_HASH}"
CACHE_FILE="$CACHE_DIR/index.txt"
CACHE_DIRS="$CACHE_DIR/dirs.txt"
CACHE_LOCK="$CACHE_DIR/lock"
CACHE_TTL=60

mkdir -p "$CACHE_DIR"

# Recursive: list files for a repo, then discover sub-repos if meta-repo
# Usage: index_repo <absolute_dir> <prefix>
#   Writes to stdout: prefixed file paths
index_repo() {
  local dir="$1" prefix="$2"

  # 1. List tracked + untracked files (save for reuse in step 2)
  local files
  files=$(git -C "$dir" ls-files --cached --others --exclude-standard 2>/dev/null)
  echo "$files" | sed "s|^|$prefix|"

  # 2. If meta-repo, find ignored sub-repos and recurse
  [ -f "$dir/.meta-repo" ] || return 0
  while read -r entry; do
    # Only entries ending in / (git collapses dirs with .git not in index)
    [[ "$entry" == */ ]] || continue
    local sub="${entry%/}"
    # Skip if already covered by step 1
    echo "$files" | grep -q "^${sub}/" && continue
    index_repo "$dir/$sub" "$prefix$sub/" &
  done < <(git -C "$dir" ls-files --others --ignored --exclude-standard 2>/dev/null)
  wait
}

build_index() {
  TMPOUT="$CACHE_DIR/parts"
  mkdir -p "$TMPOUT"
  rm -f "$TMPOUT"/*

  index_repo "$PROJECT_ROOT" "" > "$TMPOUT/all"

  # Merge and sort
  sort "$TMPOUT/all" > "$CACHE_FILE.tmp"
  rm -rf "$TMPOUT"

  # Pre-compute unique directories
  grep '/' "$CACHE_FILE.tmp" | sed 's|/[^/]*$||' | sort -u | sed 's|$|/|' > "$CACHE_DIRS.tmp"
  mv "$CACHE_FILE.tmp" "$CACHE_FILE"
  mv "$CACHE_DIRS.tmp" "$CACHE_DIRS"
}

# Build cache if missing or stale (always non-blocking)
if [ ! -f "$CACHE_FILE" ]; then
  build_index &
elif [ -f "$CACHE_FILE" ]; then
  age=$(( $(date +%s) - $(date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0) ))
  # Remove stale lock (process died before cleanup)
  if [ -f "$CACHE_LOCK" ]; then
    lock_age=$(( $(date +%s) - $(date -r "$CACHE_LOCK" +%s 2>/dev/null || echo 0) ))
    [ "$lock_age" -gt 75 ] && rm -f "$CACHE_LOCK"
  fi
  if [ "$age" -gt "$CACHE_TTL" ] && ! [ -f "$CACHE_LOCK" ]; then
    touch "$CACHE_LOCK"
    ( build_index; rm -f "$CACHE_LOCK" ) &
  fi
fi

query=$(cat | jq -r '.query // ""')

if [ -z "$query" ]; then
  ls -1p "$PROJECT_ROOT" | head -15
  exit 0
fi

# Build fuzzy patterns
# Segment fuzzy: "perso" → "p[^/]*e[^/]*r[^/]*s[^/]*o" (within one path segment)
# Global fuzzy:  "v6" → "v.*6" (anywhere in path, crosses segments)
fuzzy=""
gfuzzy=""
for (( i=0; i<${#query}; i++ )); do
  c="${query:$i:1}"
  if [[ "$c" =~ [\.\^\$\*\+\?\\\{\}\(\)\|/\[\]] ]]; then
    c="\\$c"
  fi
  if [ $i -eq 0 ]; then
    fuzzy="$c"
    gfuzzy="$c"
  else
    fuzzy="${fuzzy}[^/]*$c"
    gfuzzy="${gfuzzy}.*$c"
  fi
done

# Sort helper: by depth, files before dirs at same depth
by_depth() { awk -F/ '{d=($0 ~ /\/$/) ? 1 : 0; print NF, d, $0}' | sort -n -k1 -k2 | cut -d' ' -f3-; }

{
  # Tier 1: if query matches a dir, list its immediate contents from cache
  top_dir=$(grep -iE "(^|/)$query[^/]*/$" "$CACHE_DIRS" 2>/dev/null | by_depth | head -1)
  if [ -n "$top_dir" ]; then
    echo "$top_dir"
    grep -E "^${top_dir}[^/]+$" "$CACHE_FILE" 2>/dev/null
    grep -E "^${top_dir}[^/]+/$" "$CACHE_DIRS" 2>/dev/null
  fi

  # Tier 2: exact prefix match on segment
  { grep -iE "(^|/)$query" "$CACHE_DIRS" 2>/dev/null
    grep -iE "(^|/)$query" "$CACHE_FILE" 2>/dev/null
  } | by_depth | head -10

  # Tier 3: fuzzy match within segment
  { grep -iE "(^|/)$fuzzy" "$CACHE_DIRS" 2>/dev/null
    grep -iE "(^|/)$fuzzy" "$CACHE_FILE" 2>/dev/null
  } | by_depth | head -10

  # Tier 4: substring anywhere (fallback)
  grep -i "$query" "$CACHE_FILE" 2>/dev/null | by_depth | head -8

  # Tier 5: global fuzzy across segments (e.g. "v6" matches "alcance_v0_0_6.md")
  { grep -iE "$gfuzzy" "$CACHE_DIRS" 2>/dev/null
    grep -iE "$gfuzzy" "$CACHE_FILE" 2>/dev/null
  } | by_depth | head -8
} | awk '!seen[$0]++' | head -15
