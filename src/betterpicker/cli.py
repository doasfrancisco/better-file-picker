"""betterpicker CLI.

Scaffolds a meta-repo for the better-file-picker `@` file picker:

    betterpicker --agent claude

creates a `.meta-repo` marker in the current directory and wires up the
agent's file-picker settings to a copy of `file-suggestion.sh` kept at a
stable global location (`~/.betterpicker/`), so the settings never depend on
where this package happens to be installed.
"""

import argparse
import json
import os
import shutil
import sys
from importlib import resources
from pathlib import Path

# Stable, predictable home for the bundled script and its cache. The settings
# file always points here, regardless of where uv installed the package.
INSTALL_DIR = Path.home() / ".betterpicker"
SCRIPT_NAME = "file-suggestion.sh"

# Per-agent output: where the settings file goes and which bundled template
# seeds it. Extend this map to support more agents.
AGENTS = {
    "claude": {
        "dir": ".claude",
        "filename": "settings.json",
        "template": "settings.claude.json",
    },
}


def _refresh_script() -> Path:
    """Copy the bundled file-suggestion.sh into ~/.betterpicker (refreshing it
    on every run so upgrades take effect). Returns the stable destination."""
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    dest = INSTALL_DIR / SCRIPT_NAME
    src_res = resources.files("betterpicker") / "data" / SCRIPT_NAME
    with resources.as_file(src_res) as src:
        shutil.copyfile(src, dest)
    # Best effort exec bit (no-op on Windows; matters when run under WSL/Unix).
    try:
        os.chmod(dest, 0o755)
    except OSError:
        pass
    return dest


def _write_settings(agent: dict, script_path: Path, project_root: Path) -> Path:
    """Merge our keys into the agent's settings file, preserving anything else.

    Reads the existing JSON into memory (if present), sets the keys we own, and
    rewrites the whole file — the clean way to edit JSON.
    """
    template_text = (
        resources.files("betterpicker") / "data" / agent["template"]
    ).read_text(encoding="utf-8")
    desired = json.loads(template_text)
    desired["fileSuggestion"]["command"] = (
        desired["fileSuggestion"]["command"]
        .replace("{{SCRIPT_PATH}}", script_path.as_posix())
        .replace("{{PROJECT_ROOT}}", project_root.as_posix())
    )

    out_dir = project_root / agent["dir"]
    out_dir.mkdir(parents=True, exist_ok=True)
    settings_path = out_dir / agent["filename"]

    if settings_path.exists():
        try:
            existing = json.loads(settings_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, ValueError):
            existing = {}
        if not isinstance(existing, dict):
            existing = {}
    else:
        existing = {}

    existing.update(desired)
    settings_path.write_text(
        json.dumps(existing, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return settings_path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        prog="betterpicker",
        description="Scaffold a .meta-repo marker and wire up an agent's "
        "file picker to the better-file-picker script.",
    )
    parser.add_argument(
        "--agent",
        required=True,
        choices=sorted(AGENTS),
        help="Agent to configure (writes its file-picker settings).",
    )
    args = parser.parse_args(argv)
    agent = AGENTS[args.agent]

    project_root = Path.cwd()

    # 1. Drop the meta-repo marker (idempotent).
    marker = project_root / ".meta-repo"
    marker.touch(exist_ok=True)

    # 2. Refresh the script at its stable global location.
    script_path = _refresh_script()

    # 3. Write/merge the agent settings.
    settings_path = _write_settings(agent, script_path, project_root)

    print(f"betterpicker: ready for '{args.agent}' in {project_root}")
    print(f"  marker   {marker}")
    print(f"  script   {script_path}")
    print(f"  settings {settings_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
