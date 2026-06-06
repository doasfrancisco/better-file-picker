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
#   Single awk process loads dirs.txt + index.txt into memory, then runs
#   all 5 tiers in one pass (no subprocess spawns per tier).
#   Total query time must stay ≤0.5s on Windows — Claude Code drops results
#   from slow commands, so the file picker appears broken if search is slow.
#     Tier 1: dir match → shallowest dir + ≤3 children (skip if depth >4)
#     Tier 2: exact prefix on segment      (e.g. "cata" → catafract/CLAUDE.md)  10
#     Tier 3: segment fuzzy                (c[^/]*a[^/]*t[^/]*a)                10
#     Tier 4: substring anywhere           (literal "cata" in path)              8
#     Tier 5: global fuzzy across segments (c.*a.*t.*a, crosses /)      remaining
#   Dedup via seen[] array, emit() stops at 15 results.
#   Dirs scanned before files in each tier so folders appear first.
#

PROJECT_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROJECT_HASH=$(echo "$PROJECT_ROOT" | md5sum | cut -d' ' -f1)
CACHE_DIR="$HOME/.betterpicker/cache/${PROJECT_HASH}"
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
  # Use lock to prevent multiple cold-start builds stacking up
  if ! [ -f "$CACHE_LOCK" ]; then
    touch "$CACHE_LOCK"
    ( build_index; rm -f "$CACHE_LOCK" ) &>/dev/null &
    disown
  fi
elif [ -f "$CACHE_FILE" ]; then
  age=$(( $(date +%s) - $(date -r "$CACHE_FILE" +%s 2>/dev/null || echo 0) ))
  # Remove stale lock (process died before cleanup)
  if [ -f "$CACHE_LOCK" ]; then
    lock_age=$(( $(date +%s) - $(date -r "$CACHE_LOCK" +%s 2>/dev/null || echo 0) ))
    [ "$lock_age" -gt 75 ] && rm -f "$CACHE_LOCK"
  fi
  if [ "$age" -gt "$CACHE_TTL" ] && ! [ -f "$CACHE_LOCK" ]; then
    touch "$CACHE_LOCK"
    ( build_index; rm -f "$CACHE_LOCK" ) &>/dev/null &
    disown
  fi
fi

query=$(cat | jq -r '.query // ""')

if [ -z "$query" ]; then
  ls -1p "$PROJECT_ROOT" | head -15
  exit 0
fi

# If cache doesn't exist yet, serve partial results from ls
if [ ! -f "$CACHE_FILE" ]; then
  ls -1p "$PROJECT_ROOT" | grep -i "$query" | head -15
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

# Single awk pass: reads dirs.txt + index.txt once, runs all 5 tiers in
# memory, deduplicates, and outputs ≤15 results.  Replaces ~15 process
# spawns (grep|sort|cut per tier) with 1 awk process — critical on Windows
# where process creation is expensive (~2.5s → target <0.5s).
awk -v query="$query" -v fuzzy="$fuzzy" -v gfuzzy="$gfuzzy" '
function emit(path) {
  if (path in seen || total >= 15) return 0
  seen[path] = 1; print path; total++; return 1
}
# Partial selection sort: emit up to limit entries, shallowest first.
# Sort key = (depth-1)*2 for dirs, depth*2+1 for files → dirs before files
# at the same nesting level.  O(limit * n) where n ≤ 100, so negligible.
function emit_sorted(m, mk, n, lim,    c, i, j, mj, tmp, tk) {
  c = 0
  for (i = 1; i <= n && c < lim && total < 15; i++) {
    mj = i
    for (j = i + 1; j <= n; j++) if (mk[j] < mk[mj]) mj = j
    if (mj != i) {
      tmp = m[i];  m[i]  = m[mj];  m[mj]  = tmp
      tk  = mk[i]; mk[i] = mk[mj]; mk[mj] = tk
    }
    if (emit(m[i])) c++
  }
}
BEGIN { IGNORECASE = 1; total = 0 }
# Pre-compute sort keys during load: dirs get (depth-1)*2, files depth*2+1
NR == FNR { d[++nd] = $0; dd[nd] = (split($0, _, "/") - 1) * 2; next }
{ f[++nf] = $0; fd[nf] = split($0, _, "/") * 2 + 1 }
END {
  t2 = "(^|/)" query
  t3 = "(^|/)" fuzzy
  t5 = gfuzzy

  # Tier 1: shallowest dir matching query, then ≤3 immediate children
  # Skip if shallowest match is deeper than 4 segments (deep dirs
  # should not outrank shallow files like CLAUDE.md).
  t1 = ""; t1d = 9999
  for (i = 1; i <= nd; i++) {
    if (d[i] ~ t2 "[^/]*/$") {
      n = split(d[i], _, "/")
      if (n < t1d) { t1 = d[i]; t1d = n }
    }
  }
  if (t1 != "" && t1d <= 5) {
    emit(t1); c = 0
    for (i = 1; i <= nd && c < 3; i++) {
      if (d[i] != t1 && index(d[i], t1) == 1) {
        r = substr(d[i], length(t1) + 1)
        if (r !~ /\/.*\//) { if (emit(d[i])) c++ }
      }
    }
    for (i = 1; i <= nf && c < 3; i++) {
      if (index(f[i], t1) == 1) {
        r = substr(f[i], length(t1) + 1)
        if (index(r, "/") == 0) { if (emit(f[i])) c++ }
      }
    }
  }

  # Tiers 2-5: collect all candidates, sort by depth, emit limit
  # Tier 2: exact prefix on segment
  cn = 0
  for (i = 1; i <= nd ; i++) if (d[i] ~ t2) { cm[++cn] = d[i]; ck[cn] = dd[i] }
  for (i = 1; i <= nf ; i++) if (f[i] ~ t2) { cm[++cn] = f[i]; ck[cn] = fd[i] }
  emit_sorted(cm, ck, cn, 10)

  # Tier 3: segment fuzzy
  cn = 0
  for (i = 1; i <= nd ; i++) if (d[i] ~ t3) { cm[++cn] = d[i]; ck[cn] = dd[i] }
  for (i = 1; i <= nf ; i++) if (f[i] ~ t3) { cm[++cn] = f[i]; ck[cn] = fd[i] }
  emit_sorted(cm, ck, cn, 10)

  # Tier 4: substring anywhere (files only)
  cn = 0
  for (i = 1; i <= nf ; i++) if (f[i] ~ query) { cm[++cn] = f[i]; ck[cn] = fd[i] }
  emit_sorted(cm, ck, cn, 8)

  # Tier 5: global fuzzy across segments — no per-tier cap, just fill
  # remaining slots (earlier tiers may have produced nothing)
  cn = 0
  for (i = 1; i <= nd ; i++) if (d[i] ~ t5) { cm[++cn] = d[i]; ck[cn] = dd[i] }
  for (i = 1; i <= nf ; i++) if (f[i] ~ t5) { cm[++cn] = f[i]; ck[cn] = fd[i] }
  emit_sorted(cm, ck, cn, 15)
}
' "$CACHE_DIRS" "$CACHE_FILE"
