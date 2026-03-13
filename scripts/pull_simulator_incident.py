import json
import shutil
import subprocess
from pathlib import Path

BUNDLE_ID = "com.repotrace.demo"
APP_INCIDENTS_RELATIVE_DIR = Path("Documents/Incidents")


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run_command(args: list[str]) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        raise RuntimeError(message)
    return result.stdout


def booted_udids() -> list[str]:
    output = run_command(["xcrun", "simctl", "list", "devices", "booted", "--json"])
    payload = json.loads(output)

    udids: list[str] = []
    for devices in payload.get("devices", {}).values():
        for device in devices:
            if device.get("state") == "Booted":
                udids.append(device["udid"])
    return udids


def first_container_with_app(udids: list[str]) -> Path:
    for udid in udids:
        result = subprocess.run(
            ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return Path(result.stdout.strip())
    raise RuntimeError(f"app {BUNDLE_ID} not installed on any booted simulator")


def newest_unprocessed_json(source_dir: Path, inbox_dir: Path, incidents_dir: Path) -> Path:
    candidates = sorted(
        [path for path in source_dir.glob("*.json") if path.is_file()],
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise RuntimeError(f"no incident JSON files in {source_dir}")

    for candidate in candidates:
        incident_id = candidate.stem
        if (inbox_dir / candidate.name).exists():
            continue
        if (incidents_dir / f"{incident_id}.md").exists():
            continue
        return candidate

    raise RuntimeError("no unprocessed simulator incident JSON files found")


def main() -> int:
    root = repo_root()
    inbox_dir = root / "diagnostics" / "inbox"
    incidents_dir = root / "diagnostics" / "incidents"

    try:
        udids = booted_udids()
        if not udids:
            raise RuntimeError("no booted iOS Simulator devices found")

        container = first_container_with_app(udids)
        source_dir = container / APP_INCIDENTS_RELATIVE_DIR
        if not source_dir.exists():
            raise RuntimeError(f"incident directory not found in simulator app container: {source_dir}")

        source_json = newest_unprocessed_json(source_dir, inbox_dir, incidents_dir)
        inbox_dir.mkdir(parents=True, exist_ok=True)

        destination = inbox_dir / source_json.name
        shutil.copy2(source_json, destination)
        print(f"copied {source_json} -> {destination}")
        return 0
    except RuntimeError as error:
        print(error)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
