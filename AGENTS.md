# Project guidance for Codex

You are working on an iOS app.

Primary debugging workflow:
1. Read `diagnostics/incidents/` for the current incident.
2. Read `diagnostics/claims.json` before broad repo exploration.
3. Distinguish clearly between:
   - observations
   - claims / hypotheses
   - checks run
   - falsified branches
4. Prefer narrowing the search frontier over broad speculative reading.
5. Reuse existing claims if they remain relevant.
6. When a claim is disproven, mark it as falsified instead of repeating it.
7. When a new durable repo-specific debugging fact is discovered, update `diagnostics/claims.json`.
8. Before broad code search, produce a retrieval result from incident evidence.
9. Save the retrieval result to `diagnostics/retrieval_results/<incident-id>.json`.
10. Apply `diagnostics/triage_policy.json` to choose the next action mode.

Output style:
- Be explicit about top candidate subsystems.
- Name the smallest next deterministic check.
- Keep the active frontier small.

When fixing a bug:
- First identify likely files and checks.
- Then implement the smallest fix.
- Then explain which claim was confirmed or falsified.

## RepoTrace workflow rules

For debugging tasks:
1. Read `diagnostics/incidents/` first if an incident is present.
2. Read `diagnostics/claims.json` before broad repo exploration.
3. Separate:
   - observations
   - claims
   - checks
   - falsified branches
4. Keep the search frontier small.
5. Prefer deterministic checks over broad speculative reading.
6. Only add a claim to `claims.json` if it is likely reusable across future incidents.
7. If no `.xcodeproj`/`.xcworkspace` is present, run a deterministic iOS typecheck with:
   `xcrun --sdk iphonesimulator swiftc -target arm64-apple-ios17.0-simulator -typecheck RepoTrace/Diagnostics/*.swift`
8. Produce a retrieval result object from incident evidence before broad code search.
9. Save that retrieval result under `diagnostics/retrieval_results/<incident-id>.json`.
10. Apply `diagnostics/triage_policy.json` using the retrieval verdict.
11. Execute only the next action mode selected by the policy.
