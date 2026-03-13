import json
import sys
from pathlib import Path

def newest_inbox_json(inbox_dir: Path) -> Path:
    candidates = [p for p in inbox_dir.glob("*.json") if p.is_file()]
    if not candidates:
        print("no incident JSON files found in diagnostics/inbox/")
        raise SystemExit(1)
    return max(candidates, key=lambda p: p.stat().st_mtime)


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

data = json.loads(src.read_text())

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
- App Version: {data["metadata"].get("appVersion", "")}
- Build: {data["metadata"].get("buildNumber", "")}
- iOS: {data["metadata"].get("osVersion", "")}
- Device: {data["metadata"].get("deviceModel", "")}
- Screen: {data["metadata"].get("screenName", "")}
- Commit: {data["metadata"].get("gitCommit", "")}
- Timestamp: {data["metadata"].get("timestamp", "")}

## Breadcrumbs
{breadcrumbs if breadcrumbs else "- none"}

## Screenshot
{data.get("screenshotFilename", "")}
"""

out_file.write_text(text)
print(f"wrote {out_file}")
