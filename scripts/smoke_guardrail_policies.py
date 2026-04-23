#!/usr/bin/env python3.12
"""Smoke test: report Foundry guardrail policy compliance.

Queries Azure Policy compliance state for every `aisec-guardrail-*`
subscription-scope assignment created by
`infra/foundry-guardrail-per-risk.bicep` and prints a per-policy
table of compliant / non-compliant resource counts. Designed to
demonstrate the policies in Foundry → Operate → Compliance → Policies
catching violations produced by
`infra/foundry-guardrail-violation-fixtures.bicep` (or any other
model deployment bound to a non-compliant RAI policy).

Usage
-----
    python3.12 scripts/smoke_guardrail_policies.py

    # Trigger an on-demand scan first (takes 10-30 min to complete),
    # then poll compliance state until it completes:
    python3.12 scripts/smoke_guardrail_policies.py --trigger-scan --wait

    # Only show assignments with violations, exit 1 if none are flagged:
    python3.12 scripts/smoke_guardrail_policies.py --assert-violations

    # JSON output for CI:
    python3.12 scripts/smoke_guardrail_policies.py --json out.json

Requires `az login` with reader access on the target subscription.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import dataclass, field

ASSIGNMENT_PREFIX = "aisec-guardrail-"


def _az(args: list[str], *, check: bool = True) -> str:
    """Run az CLI, return stdout."""
    result = subprocess.run(
        ["az", *args],
        capture_output=True,
        text=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(
            f"az {' '.join(args)} failed with exit {result.returncode}: "
            f"{result.stderr.strip()}"
        )
    return result.stdout


def get_subscription_id() -> str:
    out = _az(["account", "show", "--query", "id", "-o", "tsv"])
    return out.strip()


def list_guardrail_assignments_raw(sub_id: str) -> list[dict]:
    """Return all subscription-scope policy assignments."""
    raw = _az(["policy", "assignment", "list", "--subscription", sub_id, "-o", "json"])
    return json.loads(raw)


def _filter_by_prefix(assignments: list[dict], prefix: str) -> list[dict]:
    return [a for a in assignments if (a.get("name") or "").startswith(prefix)]


def trigger_scan(sub_id: str) -> str:
    """Kick off subscription-scope policy compliance scan, return scan name."""
    print(f"Triggering policy scan for subscription {sub_id}...", file=sys.stderr)
    scan_name = f"guardrail-smoke-{int(time.time())}"
    # az policy state trigger-scan is async — returns immediately with the URL
    # to poll. Using --no-wait to decouple from the internal polling.
    _az(
        [
            "policy",
            "state",
            "trigger-scan",
            "--subscription",
            sub_id,
            "--no-wait",
        ],
        check=False,
    )
    return scan_name


@dataclass
class AssignmentCompliance:
    name: str
    display_name: str
    total_resources: int = 0
    compliant: int = 0
    non_compliant: int = 0
    non_compliant_resources: list[str] = field(default_factory=list)
    error: str | None = None

    @property
    def is_violated(self) -> bool:
        return self.non_compliant > 0


def fetch_compliance(sub_id: str, assignment: dict) -> AssignmentCompliance:
    """Query policy-insights compliance summary for one assignment."""
    name = assignment["name"]
    display = assignment.get("displayName") or name
    result = AssignmentCompliance(name=name, display_name=display)

    # Policy-insights returns lowercase compliance states; inline $filter
    # must be part of the URL for az rest POST to forward it.
    base = (
        f"https://management.azure.com/subscriptions/{sub_id}/"
        "providers/Microsoft.PolicyInsights/policyStates/latest"
    )
    filter_expr = f"PolicyAssignmentId eq '{assignment['id']}'"
    summary_url = f"{base}/summarize?api-version=2019-10-01&$filter={filter_expr}"

    try:
        raw = _az(
            ["rest", "--method", "post", "--url", summary_url, "-o", "json"]
        )
    except RuntimeError as e:
        result.error = str(e)
        return result

    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        result.error = f"malformed JSON from policy-insights: {e}"
        return result

    values = data.get("value") or []
    if not values:
        return result

    summary = values[0]
    results_obj = summary.get("results", {}) or {}
    for row in results_obj.get("resourceDetails", []) or []:
        state = (row.get("complianceState") or "").lower()
        count = int(row.get("count", 0))
        if state == "compliant":
            result.compliant = count
        elif state == "noncompliant":
            result.non_compliant = count
    result.total_resources = result.compliant + result.non_compliant

    if result.non_compliant > 0:
        query_url = (
            f"{base}/queryResults?api-version=2019-10-01&$top=25"
            f"&$filter=({filter_expr}) and ComplianceState eq 'NonCompliant'"
        )
        try:
            rows_raw = _az(
                ["rest", "--method", "post", "--url", query_url, "-o", "json"]
            )
            rows = json.loads(rows_raw).get("value", []) or []
            seen: set[str] = set()
            ids: list[str] = []
            for r in rows:
                rid = r.get("resourceId")
                if rid and rid not in seen:
                    seen.add(rid)
                    ids.append(rid)
            result.non_compliant_resources = ids
        except (RuntimeError, json.JSONDecodeError):
            pass

    return result


def print_table(rows: list[AssignmentCompliance]) -> None:
    name_w = max((len(r.display_name) for r in rows), default=10)
    name_w = max(name_w, len("POLICY"))
    header = f"{'POLICY':<{name_w}}  {'TOTAL':>5}  {'COMPLIANT':>9}  {'VIOLATED':>8}  STATUS"
    print(header)
    print("-" * len(header))
    for r in rows:
        if r.error:
            status = f"ERROR: {r.error[:60]}"
        elif r.total_resources == 0:
            status = "no-resources-in-scope"
        elif r.is_violated:
            status = f"VIOLATION ({r.non_compliant_resources[0] if r.non_compliant_resources else '?'})"
        else:
            status = "compliant"
        print(
            f"{r.display_name:<{name_w}}  "
            f"{r.total_resources:>5}  "
            f"{r.compliant:>9}  "
            f"{r.non_compliant:>8}  "
            f"{status}"
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--subscription",
        help="Override the subscription ID. Defaults to `az account show`.",
    )
    parser.add_argument(
        "--trigger-scan",
        action="store_true",
        help="Kick off an on-demand Azure Policy scan before querying state.",
    )
    parser.add_argument(
        "--wait",
        type=int,
        default=0,
        metavar="MINUTES",
        help="After --trigger-scan, poll every 60s until resourceDetails is populated, up to this many minutes (default 0 = no wait).",
    )
    parser.add_argument(
        "--assert-violations",
        action="store_true",
        help="Exit 1 if no assignments are in the Violated state. Useful for CI demos.",
    )
    parser.add_argument(
        "--json",
        metavar="PATH",
        help="Write the full compliance report as JSON to this path.",
    )
    parser.add_argument(
        "--prefix",
        default=ASSIGNMENT_PREFIX,
        help=f"Assignment-name prefix filter (default '{ASSIGNMENT_PREFIX}').",
    )
    args = parser.parse_args()

    sub_id = args.subscription or get_subscription_id()
    print(f"Subscription: {sub_id}", file=sys.stderr)

    if args.trigger_scan:
        trigger_scan(sub_id)

    assignments = _filter_by_prefix(list_guardrail_assignments_raw(sub_id), args.prefix)
    if not assignments:
        print(f"No assignments matched prefix '{args.prefix}'.", file=sys.stderr)
        return 2

    print(
        f"Found {len(assignments)} guardrail policy assignments. Querying compliance...",
        file=sys.stderr,
    )

    deadline = time.time() + args.wait * 60 if args.wait else None
    while True:
        rows = [fetch_compliance(sub_id, a) for a in assignments]
        any_with_data = any(r.total_resources > 0 for r in rows)
        if deadline is None or any_with_data or time.time() >= deadline:
            break
        remaining_s = int(deadline - time.time())
        print(
            f"Compliance data not yet populated — sleeping 60s (budget {remaining_s}s)...",
            file=sys.stderr,
        )
        time.sleep(60)

    rows.sort(key=lambda r: (not r.is_violated, r.display_name))
    print_table(rows)

    violated = [r for r in rows if r.is_violated]
    print(
        f"\nSummary: {len(violated)}/{len(rows)} assignments show violations.",
        file=sys.stderr,
    )

    if args.json:
        with open(args.json, "w") as f:
            json.dump(
                {
                    "subscription": sub_id,
                    "assignments": [
                        {
                            "name": r.name,
                            "display_name": r.display_name,
                            "total_resources": r.total_resources,
                            "compliant": r.compliant,
                            "non_compliant": r.non_compliant,
                            "non_compliant_resources": r.non_compliant_resources,
                            "error": r.error,
                        }
                        for r in rows
                    ],
                },
                f,
                indent=2,
            )
        print(f"Wrote JSON report to {args.json}", file=sys.stderr)

    if args.assert_violations and not violated:
        print(
            "ASSERTION FAILED: expected at least one assignment to show violations.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
