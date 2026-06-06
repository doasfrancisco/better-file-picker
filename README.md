# better-file-picker

Custom `@` file picker for Claude Code that indexes meta-repos with nested git repos.

## CLI (`betterpicker`)

Scaffolds a meta-repo and wires up an agent's `@` file picker in one command.

```bash
uv tool install .          # install globally (betterpicker on PATH)
betterpicker --agent claude
```

Run inside the directory you want to be the meta-repo root. It:

1. Creates a `.meta-repo` marker in the current directory.
2. Copies `file-suggestion.sh` to a stable global location, `~/.betterpicker/file-suggestion.sh` (refreshed on every run, so upgrades take effect).
3. Writes `.claude/settings.json` pointing the file picker at that script with the current directory as the project root.

The generated `.claude/settings.json`:

```json
{
  "fileSuggestion": {
    "type": "command",
    "command": "bash \"C:/Users/<you>/.betterpicker/file-suggestion.sh\" \"C:/path/to/repo\""
  },
  "respectGitignore": false
}
```

Notes:

- `--agent` is **required** (`claude` is the only value for now; the map in `cli.py` is extensible).
- If `.claude/settings.json` already exists, it is parsed, our keys (`fileSuggestion`, `respectGitignore`) are set, and the file is rewritten — any other keys are preserved.
- The picker cache lives under `~/.betterpicker/cache/<project-hash>/`.

## Dependencies

- `git` — file listing and sub-repo discovery
- `jq` — parses JSON query from Claude Code stdin. Could be replaced with pure bash to remove the dependency.

## Algorithm

Recursive `index_repo(dir, prefix)`:

1. `git ls-files --cached --others --exclude-standard` → all tracked + untracked files (saved for reuse)
2. If `.meta-repo` marker exists:
   1. `git ls-files --others --ignored --exclude-standard` → find ignored paths
   2. For each entry ending in `/` from 2.1:
      - If not already covered by step 1 → `index_repo(sub, prefix)` (recurse in parallel)

Why entries ending in `/` works: git collapses directories that have `.git` and aren't tracked in the parent index into `dir/` with trailing slash. Non-git directories like `fran++/` get expanded into individual files. So trailing `/` = sub-repo, no `.git` check needed.

## Versions

- **v1** (`file-suggestion-v1.sh`) — original, checks `.git` on every ignored entry
- **v2** (`file-suggestion-v2.sh`) — trailing `/` filter, recursive
- **v3** (`file-suggestion-v3.sh`) — experimental ripgrep (`rg`) instead of `git ls-files`
- **current** (`file-suggestion.sh`) — v2 (best performing)

## Benchmarks

On a meta-repo with 75+ nested git repos (Windows 11):

| Version | Cold cache | Warm cache |
|---|---|---|
| v1 (check `.git` on every entry) | 10.0s | 1.3s |
| v2 (filter trailing `/`) | 7.9s | 0.78s |
| v3 (ripgrep, `command rg`) | 8.9s | 0.84s |

Cold cache bottleneck: 75+ `git` process spawns (~100ms each on Windows). Warm cache: sub-second (grep on cached index).

## Insights

### `git ls-files --others --ignored` collapse behavior

The command treats directories differently based on whether they have files tracked in the parent repo's index:

- **Dir fully ignored, not in parent index** (e.g. `catafract/`) → git collapses it to `catafract/`. It does NOT enter it.
- **Dir has files tracked in parent index** (e.g. `better_file_picker/file-suggestion.sh` is tracked as `100644`) → git treats it as a regular directory, enters it, and lists individual ignored files inside.

Verified with `git ls-files --stage`:
```
100644 6eb0b96... 0  better_file_picker/file-suggestion.sh   # tracked → git enters dir
                                                              # catafract has no entry → collapsed
```

### `.git` boundary is absolute

No `git ls-files` flag crosses `.git` boundaries for unregistered repos. `--recurse-submodules` only works for registered submodules (`git submodule add`). Confirmed from git source code (via Nia search on `git/git`).

This is why the recursive algorithm exists — git can't list files across nested repos in a single command.

### Trailing `/` as sub-repo detection

`git ls-files --others --ignored` output for the same meta-repo:
- `catafract/` — collapsed (trailing `/`), has `.git`, not in parent index → **sub-repo**
- `fran++/v0.0.2/codegen.py` — expanded (individual files), no `.git` → **not a sub-repo**
- `better_file_picker/bash.exe.stackdump` — expanded, has `.git` but tracked in parent → **already indexed by step 1**

Filtering for entries ending in `/` gives exactly the set of sub-repos to recurse into. The "not in step 1" check handles the edge case of partially-tracked dirs.

### `git ls-files --cached --others --exclude-standard`

`--cached` (tracked files) and `--others` (untracked files) are complementary sets. `--others` alone replaces the default `--cached` mode, but passing both explicitly returns all files while still respecting `.gitignore`. This is how untracked files appear in `@` search before being committed.

### ripgrep vs git ls-files

`rg --files --hidden -g '!.git'` is functionally equivalent to `git ls-files --cached --others --exclude-standard` with two differences:
- **Tracked-but-gitignored files**: git shows them (they're in the index), rg skips them (it only sees filesystem + `.gitignore`). ~4 files per 6434 in chatwoot. Negligible.
- **Parent `.gitignore`**: rg walks up to parent `.git` and applies its ignore rules. `git -C subdir ls-files` only cares about that repo's own ignores. Use `command rg` to bypass Claude Code's wrapper function.

rg is slower per-repo because of path conversion overhead (`cut` + `tr` for Windows backslashes). Its advantage would be a single-spawn approach: one `rg --files --hidden --no-ignore` from root listing ALL files, then pruning with per-repo `.gitignore` in post-processing. Not yet implemented.

### Git config options for speed

From git source (`git/git`):

- **`core.fscache=true`** (Windows-only, enabled by default) — caches `lstat()` results within a single git process. Reads all file metadata in a directory at once instead of one call per file. Per-process only, dies on exit.
- **`core.untrackedCache=true`** — caches untracked file scan results persistently in `.git/index`. Checks directory mtimes — if unchanged, skips scanning. Race condition: files created in the same second as the last scan are invisible until next re-scan. Tested: no measurable improvement because the bottleneck is process spawn overhead, not per-call scanning.
- **`core.fsmonitor=true`** — background daemon tracks filesystem events in real-time via OS APIs. Git asks "what changed?" instead of walking the tree.
- **`feature.manyFiles=true`** — enables `core.untrackedCache`, `core.fsmonitor`, `index.skipHash` (faster index writes), and `index.version=4` (path-prefix compression).

### Cold cache profiling

| Phase | Time | What |
|---|---|---|
| Root repo `ls-files` | 0.27s | Fast |
| Discover sub-repos (`ls-files --others --ignored`) | 0.2s per meta-repo | Fast (only 3 meta-repos) |
| Index 75 sub-repos (parallel, `ls-files`) | ~7.5s | **Bottleneck** — process spawn overhead |

Each `git` process takes ~100ms on Windows just to start (load exe, init config, read index). 75 processes in parallel still takes ~7.5s total wall time.

## Possible future features

### Show gitignored files (not folders)

Currently `git ls-files --cached --others --exclude-standard` respects `.gitignore`, so files like `signal-dev/dashboard.html` (gitignored) don't appear in `@` search. But sometimes you want to find files that are gitignored — just not the folders (like `node_modules/`, `.venv/`).

Approach: add `git ls-files --others --ignored --exclude-standard --directory` per repo. The `--directory` flag collapses ignored folders into `dir/` entries (e.g. `node_modules/`, `.venv/`, `__pycache__/`) while keeping ignored files as individual entries (e.g. `dashboard.html`, `.env`, `context.md`). Filter out entries ending in `/` to get only the files. Merge with existing output.

Trade-off: adds one more `git ls-files` call per repo (75 more process spawns on cold build). Could be combined with the existing call if git supports it, but `--cached --others` and `--ignored` are somewhat mutually exclusive modes. Also exposes `.env` and other sensitive files in search results — may need a secondary exclude list.
