import json
import os
import shutil
import subprocess
from pathlib import Path

# Default to live app bundle; can be overridden for local testing.
BUNDLE_ID = os.environ.get("PULL_INCIDENT_BUNDLE_ID", "nutriplanner.nutriplanner")
APP_INCIDENTS_RELATIVE_DIR = Path("Documents/Incidents")


def repo_root() -> Path:
    return Path(__file__).resolve().parent.parent


def run_command(args: list[str]) -> str:
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip()
        raise RuntimeError(message)
    return result.stdout


def simulator_udids(booted_only: bool) -> list[str]:
    args = ["xcrun", "simctl", "list", "devices"]
    if booted_only:
        args.append("booted")
    args.append("--json")
    output = run_command(args)
    payload = json.loads(output)

    udids: list[str] = []
    for devices in payload.get("devices", {}).values():
        for device in devices:
            if booted_only and device.get("state") != "Booted":
                continue
            udid = device.get("udid")
            if isinstance(udid, str) and udid:
                udids.append(udid)
    return udids


def app_data_containers(udids: list[str]) -> list[Path]:
    containers: list[Path] = []
    for udid in udids:
        result = subprocess.run(
            ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            containers.append(Path(result.stdout.strip()))
    if not containers:
        raise RuntimeError(f"app {BUNDLE_ID} not installed on any booted simulator")
    return containers


def is_incident_report_payload(data: dict) -> bool:
    return isinstance(data, dict) and isinstance(data.get("id"), str) and bool(data["id"].strip())


def load_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError:
        return None


def newest_unprocessed_json(candidates: list[Path], inbox_dir: Path, incidents_dir: Path) -> Path:
    candidates = sorted(
        [path for path in candidates if path.is_file()],
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        raise RuntimeError("no incident JSON files found across booted simulator app containers")

    for candidate in candidates:
        payload = load_json(candidate)
        if not is_incident_report_payload(payload or {}):
            continue
        incident_id = candidate.stem
        if (inbox_dir / candidate.name).exists():
            continue
        if (incidents_dir / f"{incident_id}.md").exists():
            continue
        return candidate

    raise RuntimeError("no unprocessed raw incident report JSON files found")


def main() -> int:
    root = repo_root()
    inbox_dir = root / "diagnostics" / "inbox"
    incidents_dir = root / "diagnostics" / "incidents"

    try:
        booted_udids = simulator_udids(booted_only=True)
        all_udids = simulator_udids(booted_only=False)
        if not all_udids:
            raise RuntimeError("no iOS Simulator devices found")

        # Prefer currently booted devices, but fall back to all simulators.
        candidate_sets = [booted_udids, all_udids] if booted_udids else [all_udids]
        candidate_jsons: list[Path] = []
        for udid_set in candidate_sets:
            try:
                containers = app_data_containers(udid_set)
            except RuntimeError:
                continue
            for container in containers:
                source_dir = container / APP_INCIDENTS_RELATIVE_DIR
                if not source_dir.exists():
                    continue
                candidate_jsons.extend(source_dir.glob("*.json"))
            if candidate_jsons:
                break

        source_json = newest_unprocessed_json(candidate_jsons, inbox_dir, incidents_dir)
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
