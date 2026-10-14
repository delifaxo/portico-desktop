#!/bin/sh
# Isolated UI simulator. It does not contain Wine or execute Windows programs.
set -eu
task_script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
task_project_dir=$(CDPATH= cd "$task_script_dir/.." && pwd -P)
python3 - "$task_project_dir" <<'PY'
import json
import pathlib
import sys

project = pathlib.Path(sys.argv[1]).resolve()
work = project / "work"
root = work / "ui-smoke"
marker = root / ".portico-smoke-fixture"
if work.is_symlink() or root.is_symlink():
    raise SystemExit("Refusing a symlinked smoke fixture directory")
if root.exists() and any(root.iterdir()) and not marker.is_file():
    raise SystemExit("Refusing to overwrite an unmarked directory: " + str(root))

def checked(path):
    for item in [path, *path.parents]:
        if item == project:
            break
        if item.is_symlink():
            raise SystemExit("Refusing a symlink inside the fixture: " + str(item))
    return path

def write(path, contents, executable=False):
    checked(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(contents, encoding="utf-8")
    if executable:
        path.chmod(0o755)

bottle_id = "11111111-1111-4111-8111-111111111111"
game_id = "22222222-2222-4222-8222-222222222222"
wine = root / "engine" / "wine"
server = root / "engine" / "wineserver"
prefix = root / "Bottles" / bottle_id
game = root / "fixtures" / "Portico Smoke Game.exe"
write(marker, "PORTICO UI SMOKE FIXTURE\n")
write(wine, r'''#!/bin/sh
set -eu
if [ "${1:-}" = "--version" ]; then
    printf 'wine-0.0-portico-smoke\n'
    exit 0
fi
: "${WINEPREFIX:?The smoke simulator requires WINEPREFIX}"
printf '%s\n' "$@" > "$WINEPREFIX/smoke-arguments.txt"
printf '[SIMULATOR] Prefix: %s\n' "$WINEPREFIX"
printf '[SIMULATOR] No real Wine or Windows code is executed.\n' >&2
case "${1:-}" in
    wineboot.exe)
        /bin/mkdir -p "$WINEPREFIX/drive_c"
        /usr/bin/touch "$WINEPREFIX/system.reg"
        printf '[SIMULATOR] Environment initialized.\n'
        ;;
    */Portico\ Smoke\ Game.exe)
        /usr/bin/touch "$WINEPREFIX/.portico-smoke-running"
        printf '[SIMULATOR] Game launch accepted; waiting for Stop through wineserver.\n'
        ;;
    winecfg.exe)
        printf '[SIMULATOR] Configuration request completed.\n'
        ;;
    msiexec.exe|*.exe|*.EXE)
        printf '[SIMULATOR] Installer request completed.\n'
        ;;
    *)
        printf '[SIMULATOR] Unsupported fixture command.\n' >&2
        exit 2
        ;;
esac
''', executable=True)
write(server, r'''#!/bin/sh
set -eu
: "${WINEPREFIX:?The smoke simulator requires WINEPREFIX}"
printf '%s\n' "${1:-}" >> "$WINEPREFIX/smoke-server-calls.txt"
case "${1:-}" in
    -w)
        printf '[SIMULATOR] Waiting for this prefix only.\n'
        while [ -f "$WINEPREFIX/.portico-smoke-running" ]; do /bin/sleep 0.1; done
        printf '[SIMULATOR] This prefix has stopped.\n'
        ;;
    -k)
        /bin/rm -f "$WINEPREFIX/.portico-smoke-running"
        printf '[SIMULATOR] Stop requested for this prefix only.\n'
        ;;
    *) exit 2 ;;
esac
''', executable=True)
write(game, "PORTICO UI SMOKE FIXTURE — this text file is not a Windows executable.\n")
checked(prefix / "drive_c").mkdir(parents=True, exist_ok=True)
write(prefix / "system.reg", "WINE REGISTRY Version 2\n; UI simulator only\n")
checked(root / "Logs").mkdir(parents=True, exist_ok=True)
checked(prefix / ".portico-smoke-running").unlink(missing_ok=True)
library = {
    "schemaVersion": 1,
    "settings": {"enginePath": str(wine), "verboseLogging": True},
    "bottles": [{"id": bottle_id, "name": "Smoke · симулятор Wine", "createdAt": "2026-09-05T00:00:00Z", "status": "ready", "enginePath": str(wine)}],
    "games": [{"id": game_id, "name": "Тест запуску · симулятор", "bottleID": bottle_id, "executablePath": str(game), "arguments": ["--smoke", "argument with spaces", "literal;$(not-executed)"], "workingDirectory": str(game.parent), "addedAt": "2026-09-05T00:00:00Z", "lastPlayedAt": None, "isFavorite": True}]
}
write(root / "library.json", json.dumps(library, ensure_ascii=False, indent=2) + "\n")
print(root)
PY
