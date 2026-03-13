import json
import sys
from pathlib import Path

def load_json(path: Path):
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        print(f"invalid JSON in {path}: {exc}")
        raise SystemExit(1)

def is_incident_report_payload(data: dict) -> bool:
    return isinstance(data, dict) and isinstance(data.get("id"), str) and bool(data["id"].strip())

def newest_inbox_json(inbox_dir: Path) -> Path:
    candidates = sorted(
        [p for p in inbox_dir.glob("*.json") if p.is_file()],
        key=lambda p: p.stat().st_mtime,
        reverse=True
    )
    if not candidates:
        print("no incident JSON files found in diagnostics/inbox/")
        raise SystemExit(1)
    for candidate in candidates:
        if is_incident_report_payload(load_json(candidate)):
            return candidate
    print("no raw incident report JSON files found in diagnostics/inbox/ (expected top-level 'id')")
    raise SystemExit(1)


if len(sys.argv) > 2:
    print("usage: python scripts/new_incident.py [path/to/incident.json]")
    raise SystemExit(1)

if len(sys.argv) == 2:
    src = Path(sys.argv[1])
else:
    src = newest_inbox_json(Path("diagnostics/inbox"))

if not src.exists():
    print(f"input file does not exist: {src}")
    raise SystemExit(1)

data = load_json(src)

if not is_incident_report_payload(data):
    if isinstance(data, dict) and "incident_id" in data and "retrieval" in data:
        print(
            f"input JSON appears to be a retrieval result (incident_id + retrieval), "
            f"not a raw incident report: {src}"
        )
    else:
        print(f"input JSON missing required top-level incident report key 'id': {src}")
    raise SystemExit(1)
incident_id = data["id"]
out_dir = Path("diagnostics/incidents")
out_dir.mkdir(parents=True, exist_ok=True)
out_file = out_dir / f"{incident_id}.md"

breadcrumbs = "\n".join(
    f"- [{b['timestamp']}] ({b['category']}) {b['message']}"
    for b in data.get("breadcrumbs", [])
)

text = f"""# {incident_id}

## Title
{data.get("title", "")}

## Expected
{data.get("expectedBehavior", "")}

## Actual
{data.get("actualBehavior", "")}

## Notes
{data.get("reporterNotes", "")}

## Metadata
- App Version: {data.get("metadata", {}).get("appVersion", "")}
- Build: {data.get("metadata", {}).get("buildNumber", "")}
- iOS: {data.get("metadata", {}).get("osVersion", "")}
- Device: {data.get("metadata", {}).get("deviceModel", "")}
- Screen: {data.get("metadata", {}).get("screenName", "")}
- Commit: {data.get("metadata", {}).get("gitCommit", "")}
- Timestamp: {data.get("metadata", {}).get("timestamp", "")}

## Breadcrumbs
{breadcrumbs if breadcrumbs else "- none"}

## Screenshot
{data.get("screenshotFilename", "")}
"""

out_file.write_text(text)
print(f"wrote {out_file}")
