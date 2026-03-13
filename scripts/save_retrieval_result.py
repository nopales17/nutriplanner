import json
import sys
from pathlib import Path


def validate(payload: dict) -> None:
    if not isinstance(payload.get("incident_id"), str) or not payload["incident_id"]:
        print("retrieval result must include non-empty string incident_id")
        raise SystemExit(1)

    retrieval = payload.get("retrieval")
    if not isinstance(retrieval, dict):
        print("retrieval result must include object retrieval")
        raise SystemExit(1)

    verdict = retrieval.get("verdict")
    if verdict not in {"motif_match", "motif_non_match", "ambiguous"}:
        print("retrieval.verdict must be one of: motif_match, motif_non_match, ambiguous")
        raise SystemExit(1)

    candidates = retrieval.get("candidates")
    if not isinstance(candidates, list) or not candidates:
        print("retrieval.candidates must be a non-empty list")
        raise SystemExit(1)

    required_candidate_keys = {
        "motif_id",
        "supporting_evidence",
        "contradicting_evidence",
        "missing_evidence",
        "next_discriminating_check",
    }

    for i, candidate in enumerate(candidates):
        if not isinstance(candidate, dict):
            print(f"candidate[{i}] must be an object")
            raise SystemExit(1)
        missing = [k for k in required_candidate_keys if k not in candidate]
        if missing:
            print(f"candidate[{i}] missing required keys: {', '.join(sorted(missing))}")
            raise SystemExit(1)


def load_payload() -> dict:
    if len(sys.argv) > 2:
        print("usage: python scripts/save_retrieval_result.py [path/to/retrieval_result.json]")
        raise SystemExit(1)

    if len(sys.argv) == 2:
        src = Path(sys.argv[1])
        if not src.exists():
            print(f"input file does not exist: {src}")
            raise SystemExit(1)
        return json.loads(src.read_text())

    raw = sys.stdin.read().strip()
    if not raw:
        print("provide retrieval JSON via file argument or stdin")
        raise SystemExit(1)
    return json.loads(raw)


def main() -> None:
    payload = load_payload()
    validate(payload)

    out_dir = Path("diagnostics/retrieval_results")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file = out_dir / f"{payload['incident_id']}.json"

    out_file.write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {out_file}")


if __name__ == "__main__":
    main()
