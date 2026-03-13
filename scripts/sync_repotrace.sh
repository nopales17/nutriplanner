#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/../../RepoTrace"

cp "$SRC/AGENTS.md" "$ROOT/"
cp "$SRC/diagnostics/claims.json" "$ROOT/diagnostics/"
cp "$SRC/diagnostics/triage_policy.json" "$ROOT/diagnostics/"
cp "$SRC/scripts/save_retrieval_result.py" "$ROOT/scripts/"

echo "RepoTrace control-plane synced into nutriplanner."
