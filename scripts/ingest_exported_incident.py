import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BUNDLE_ID = os.environ.get("PULL_INCIDENT_BUNDLE_ID", "nutriplanner.nutriplanner")


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run_command(args: list[str]) -> tuple[int, str]:
    result = subprocess.run(args, capture_output=True, text=True)
    output = (result.stdout or "") + (result.stderr or "")
    return result.returncode, output.strip()


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        print(f"invalid JSON in {path}: {exc}")
        raise SystemExit(1)


def validate_raw_incident(payload: dict, path: Path) -> str:
    incident_id = payload.get("id")
    if isinstance(incident_id, str) and incident_id.strip():
        return incident_id.strip()

    if isinstance(payload, dict) and "incident_id" in payload and "retrieval" in payload:
        print(
            f"input JSON is a retrieval result (incident_id + retrieval), not a raw incident report: {path}"
        )
    else:
        print(f"input JSON missing required top-level incident report key 'id': {path}")
    raise SystemExit(1)


def load_optional_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def run_devicectl_json(args: list[str]) -> tuple[int, str, dict | None]:
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as tmp:
        json_path = Path(tmp.name)
    try:
        code, output = run_command(["xcrun", "devicectl", *args, "--json-output", str(json_path)])
        payload = load_optional_json(json_path) if code == 0 else None
        return code, output, payload
    finally:
        if json_path.exists():
            json_path.unlink()


def newest_valid_incident_json(
    search_dirs: list[Path],
    recursive_dirs: list[Path] | None = None,
    max_age_hours: int | None = None,
) -> Path:
    candidates: list[Path] = []
    searched_locations: list[str] = []
    for directory in search_dirs:
        searched_locations.append(str(directory))
        if not directory.exists() or not directory.is_dir():
            continue
        candidates.extend(directory.glob("incident-*.json"))
        candidates.extend(directory.glob("*.json"))

    if recursive_dirs:
        for directory in recursive_dirs:
            searched_locations.append(f"{directory}/**/incident-*.json")
            if not directory.exists() or not directory.is_dir():
                continue
            candidates.extend(directory.rglob("incident-*.json"))

    if not candidates:
        print("no JSON files found in default import locations")
        print("searched:")
        for location in searched_locations:
            print(f"- {location}")
        raise SystemExit(1)

    deduped = {path.resolve() for path in candidates if path.is_file()}
    if max_age_hours is not None:
        cutoff = time.time() - (max_age_hours * 3600)
        deduped = {path for path in deduped if path.stat().st_mtime >= cutoff}
        if not deduped:
            print(f"no recent incident JSON files found in default import locations (last {max_age_hours}h)")
            print("searched:")
            for location in searched_locations:
                print(f"- {location}")
            raise SystemExit(1)

    candidates = sorted(deduped, key=lambda p: p.stat().st_mtime, reverse=True)
    for candidate in candidates:
        payload = load_json(candidate)
        if isinstance(payload.get("id"), str) and payload["id"].strip():
            return candidate

    print("no valid raw incident report JSON found in default import locations (expected top-level 'id')")
    print("searched:")
    for location in searched_locations:
        print(f"- {location}")
    raise SystemExit(1)


def parse_pull_destination(output: str) -> Path | None:
    for line in output.splitlines():
        line = line.strip()
        if line.startswith("copied ") and " -> " in line:
            _, destination = line.split(" -> ", 1)
            return Path(destination.strip())
    return None


def list_connected_ios_device_ids() -> list[str]:
    code, output, payload = run_devicectl_json(["list", "devices"])
    if code != 0 or not payload:
        if output:
            print(output)
        return []

    devices = payload.get("result", {}).get("devices", [])
    ids: list[str] = []
    for device in devices:
        platform = device.get("hardwareProperties", {}).get("platform")
        reality = device.get("hardwareProperties", {}).get("reality")
        identifier = device.get("identifier")
        if platform == "iOS" and reality == "physical" and isinstance(identifier, str) and identifier:
            ids.append(identifier)
    return ids


def newest_unprocessed_device_incident(
    device_id: str,
    inbox_dir: Path,
    incidents_dir: Path,
) -> str | None:
    code, output, payload = run_devicectl_json(
        [
            "device",
            "info",
            "files",
            "--device",
            device_id,
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            BUNDLE_ID,
            "--subdirectory",
            "Documents/Incidents",
        ]
    )
    if code != 0 or not payload:
        return None

    files = payload.get("result", {}).get("files", [])
    candidates: list[tuple[str, str]] = []
    for item in files:
        name = item.get("name")
        if not isinstance(name, str):
            continue
        if not (name.startswith("incident-") and name.endswith(".json")):
            continue
        incident_id = name.removesuffix(".json")
        if (inbox_dir / name).exists():
            continue
        if (incidents_dir / f"{incident_id}.md").exists():
            continue
        last_mod = item.get("metadata", {}).get("lastModDate", "")
        candidates.append((name, last_mod if isinstance(last_mod, str) else ""))

    if not candidates:
        return None
    candidates.sort(key=lambda pair: pair[1], reverse=True)
    return candidates[0][0]


def copy_incident_from_device(device_id: str, filename: str, destination: Path) -> tuple[int, str]:
    source = f"Documents/Incidents/{filename}"
    return run_command(
        [
            "xcrun",
            "devicectl",
            "device",
            "copy",
            "from",
            "--device",
            device_id,
            "--source",
            source,
            "--destination",
            str(destination),
            "--domain-type",
            "appDataContainer",
            "--domain-identifier",
            BUNDLE_ID,
        ]
    )


def run_new_incident(root: Path, source: Path | None = None) -> int:
    cmd = [sys.executable, str(root / "scripts" / "new_incident.py")]
    if source is not None:
        cmd.append(str(source))
    code, output = run_command(cmd)
    if output:
        print(output)
    return code


def copy_to_inbox_and_ingest(root: Path, source: Path) -> int:
    payload = load_json(source)
    incident_id = validate_raw_incident(payload, source)

    inbox_dir = root / "diagnostics" / "inbox"
    inbox_dir.mkdir(parents=True, exist_ok=True)
    destination = inbox_dir / f"{incident_id}.json"
    shutil.copy2(source, destination)
    print(f"copied {source} -> {destination}")
    return run_new_incident(root, destination)


def run_connected_device_pull_and_ingest(root: Path) -> int:
    inbox_dir = root / "diagnostics" / "inbox"
    incidents_dir = root / "diagnostics" / "incidents"
    inbox_dir.mkdir(parents=True, exist_ok=True)
    incidents_dir.mkdir(parents=True, exist_ok=True)

    device_ids = list_connected_ios_device_ids()
    if not device_ids:
        print("no connected physical iOS devices found via devicectl")
        return 1

    for device_id in device_ids:
        filename = newest_unprocessed_device_incident(device_id, inbox_dir, incidents_dir)
        if not filename:
            continue
        destination = inbox_dir / filename
        code, output = copy_incident_from_device(device_id, filename, destination)
        if output:
            print(output)
        if code == 0:
            print(f"copied connected-device incident -> {destination}")
            return run_new_incident(root, destination)
    print("no unprocessed raw incident JSON found on connected physical iOS devices")
    return 1


def run_simulator_pull_and_ingest(root: Path) -> int:
    pull_script = root / "scripts" / "pull_simulator_incident.py"
    code, output = run_command([sys.executable, str(pull_script)])
    if output:
        print(output)
    if code != 0:
        return code
    destination = parse_pull_destination(output)
    return run_new_incident(root, destination)


def resolve_source_from_args() -> Path:
    if len(sys.argv) > 2:
        print("usage: python scripts/ingest_exported_incident.py [path/to/incident.json|directory]")
        raise SystemExit(1)

    if len(sys.argv) == 2:
        source = Path(sys.argv[1]).expanduser().resolve()
        if not source.exists() and str(sys.argv[1]).startswith("/var/mobile/Containers/Data/Application"):
            print(
                "iPhone sandbox path is not directly readable from macOS. "
                "Use Share JSON, then save to iCloud Drive or Downloads on your Mac."
            )
            raise SystemExit(1)
        if source.is_dir():
            return newest_valid_incident_json([source], recursive_dirs=[source])
        return source

    icloud_root = Path("~/Library/Mobile Documents/com~apple~CloudDocs").expanduser()
    default_dirs = [
        icloud_root / "Incidents",
        icloud_root / "nutriplanner-incidents",
        icloud_root / "Downloads",
        Path("~/Downloads").expanduser(),
        Path("~/Documents").expanduser(),
        Path("~/Desktop").expanduser(),
        icloud_root,
    ]
    return newest_valid_incident_json(
        default_dirs,
        recursive_dirs=[
            icloud_root,
            Path("~/Downloads").expanduser(),
            Path("~/Documents").expanduser(),
            Path("~/Desktop").expanduser(),
        ],
        max_age_hours=24,
    )


def main() -> int:
    root = repo_root()
    if len(sys.argv) == 1:
        device_code = run_connected_device_pull_and_ingest(root)
        if device_code == 0:
            return 0
        print("falling back to simulator incident pull...")
        simulator_code = run_simulator_pull_and_ingest(root)
        if simulator_code == 0:
            return 0
        print("falling back to local/iCloud export search...")
        source = resolve_source_from_args()
        return copy_to_inbox_and_ingest(root, source)

    source = resolve_source_from_args()
    if not source.exists() or not source.is_file():
        print(f"input file does not exist: {source}")
        return 1
    return copy_to_inbox_and_ingest(root, source)


if __name__ == "__main__":
    raise SystemExit(main())
