#!/bin/bash
# Custom @ file picker for meta-repo with nested git repos.
#
# === v3: EXPERIMENTAL — uses rg (ripgrep) instead of git ls-files ===
#
# Slower than v2 because Claude's rg is a shell function wrapping claude.exe,
# not real ripgrep. Each spawn has claude.exe overhead.
#
# FUTURE IDEA: a single `rg --files --hidden --no-ignore` from root could list
# ALL files across ALL sub-repos in one process spawn. Then prune results using
# each sub-repo's .gitignore rules in post-processing. This would eliminate the
# 75+ process spawns entirely — one rg call instead of 75 git calls.
# Blocked by: need real ripgrep binary (not Claude's wrapper), and a way to
# apply per-repo .gitignore rules to the flat file list.
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
#   Iterative BFS:
#     1. git ls-files --cached --others --exclude-standard → root repo files
#     2. If root has .meta-repo → queue it
#     3. While queue not empty:
#        3.1 git ls-files --others --ignored --exclude-standard → discover sub-repos
#            (entries ending in / = dirs with .git not in parent index)
#        3.2 For each sub-repo (parallel):
#            - git ls-files → list its files
#            - If .meta-repo → queue for next iteration
#   Outputs index.txt (files) + dirs.txt (directories).
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

# Export rg for subshells (Claude Code defines it as a shell function)
type rg &>/dev/null && export -f rg

PROJECT_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CACHE_DIR="${TMPDIR:-/tmp}/claude-file-suggestion-$(echo "$PROJECT_ROOT" | md5sum | cut -d' ' -f1)"
CACHE_FILE="$CACHE_DIR/index.txt"
CACHE_DIRS="$CACHE_DIR/dirs.txt"
CACHE_TTL=300

mkdir -p "$CACHE_DIR"

build_index() {
  local parts="$CACHE_DIR/parts"
  mkdir -p "$parts"
  rm -f "$parts"/*

  # 1. Root repo files (rg: faster than git, no git startup overhead)
  local rootlen=$(( ${#PROJECT_ROOT} + 2 ))
  rg --files --hidden -g '!.git' "$PROJECT_ROOT" 2>/dev/null | cut -c${rootlen}- | tr '\134' '/' > "$parts/root"

  # 2-3. BFS: discover and index sub-repos in meta-repos
  local queue=() next=()
  [ -f "$PROJECT_ROOT/.meta-repo" ] && queue+=("|$PROJECT_ROOT")

  while [ ${#queue[@]} -gt 0 ]; do
    next=()
    for item in "${queue[@]}"; do
      local prefix="${item%%|*}" dir="${item#*|}"
      while read -r entry; do
        [[ "$entry" == */ ]] || continue
        local sub="${entry%/}"
        (
          local subdir="$dir/$sub"
          local sublen=$(( ${#subdir} + 2 ))
          rg --files --hidden -g '!.git' "$subdir" 2>/dev/null \
            | cut -c${sublen}- | tr '\134' '/' \
            | sed "s|^|${prefix}${sub}/|" > "$parts/$(echo "${prefix}${sub}" | tr '/' '_')"
        ) &
        [ -f "$dir/$sub/.meta-repo" ] && next+=("${prefix}${sub}/|$dir/$sub")
      done < <(git -C "$dir" ls-files --others --ignored --exclude-standard 2>/dev/null)
    done
    wait
    queue=("${next[@]}")
  done

  cat "$parts"/* 2>/dev/null | sort > "$CACHE_FILE.tmp"
  rm -rf "$parts"
  grep '/' "$CACHE_FILE.tmp" | sed 's|/[^/]*$||' | sort -u | sed 's|$|/|' > "$CACHE_DIRS.tmp"
  mv "$CACHE_FILE.tmp" "$CACHE_FILE"
  mv "$CACHE_DIRS.tmp" "$CACHE_DIRS"
}

# Build cache if missing or stale
if [ ! -f "$CACHE_FILE" ]; then
  build_index
elif [ -f "$CACHE_FILE" ]; then
  age=$(( $(date +%s) - $(date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0) ))
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
