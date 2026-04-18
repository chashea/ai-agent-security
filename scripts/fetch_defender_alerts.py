#!/usr/bin/env python3
"""Pull recent Defender XDR alerts + incidents via Microsoft Graph.

Auth: DefaultAzureCredential (falls through to AzureCliCredential), so
`az login` + `az account get-access-token` must already work.

Usage:
    python3.12 scripts/fetch_defender_alerts.py --since-minutes 60
    python3.12 scripts/fetch_defender_alerts.py --since-minutes 60 --output alerts.json

Library use:
    from fetch_defender_alerts import fetch_alerts
    result = fetch_alerts(since_minutes=60, top=50)
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
from azure.identity import DefaultAzureCredential

GRAPH = "https://graph.microsoft.com/v1.0"


def _graph_token() -> str:
    return DefaultAzureCredential().get_token("https://graph.microsoft.com/.default").token


def _get_json(url: str, tok: str) -> dict:
    r = requests.get(url, headers={"Authorization": f"Bearer {tok}"}, timeout=60)
    r.raise_for_status()
    return r.json()


def fetch_alerts(since_minutes: int = 60, top: int = 50) -> dict:
    """Fetch Defender XDR alerts and incidents via Microsoft Graph.

    Returns a dict with keys:
        generatedAt : ISO-8601 UTC timestamp of the fetch
        since       : ISO-8601 UTC cut-off (createdDateTime >= since)
        alerts      : list[dict] from /security/alerts_v2
        incidents   : list[dict] from /security/incidents
        alertsError, incidentsError : optional error strings on failure
    """
    since = (datetime.now(timezone.utc) - timedelta(minutes=since_minutes)).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    tok = _graph_token()

    alerts_url = (
        f"{GRAPH}/security/alerts_v2"
        f"?$filter=createdDateTime ge {since}"
        f"&$top={top}"
        f"&$orderby=createdDateTime desc"
    )
    incidents_url = (
        f"{GRAPH}/security/incidents"
        f"?$filter=createdDateTime ge {since}"
        f"&$top={top}"
        f"&$orderby=createdDateTime desc"
    )

    out: dict = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "since": since,
    }
    try:
        a = _get_json(alerts_url, tok)
        out["alerts"] = a.get("value", [])
    except Exception as exc:
        out["alertsError"] = str(exc)
        out["alerts"] = []
    try:
        i = _get_json(incidents_url, tok)
        out["incidents"] = i.get("value", [])
    except Exception as exc:
        out["incidentsError"] = str(exc)
        out["incidents"] = []

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since-minutes", type=int, default=60)
    ap.add_argument("--top", type=int, default=50)
    ap.add_argument("--output", default=None)
    args = ap.parse_args()

    out = fetch_alerts(since_minutes=args.since_minutes, top=args.top)

    print(f"since: {out['since']}  (window: {args.since_minutes}m)")
    print(f"alerts:    {len(out['alerts'])}")
    print(f"incidents: {len(out['incidents'])}")
    if out.get("alertsError"):
        print("alertsError:", out["alertsError"])
    if out.get("incidentsError"):
        print("incidentsError:", out["incidentsError"])
    print()
    by_src: dict = {}
    by_sev: dict = {}
    for al in out["alerts"]:
        s = al.get("serviceSource") or al.get("detectionSource") or "unknown"
        by_src[s] = by_src.get(s, 0) + 1
        sv = al.get("severity", "unknown")
        by_sev[sv] = by_sev.get(sv, 0) + 1
    print("alerts by serviceSource:", by_src)
    print("alerts by severity:     ", by_sev)
    print()
    print("Top 15 alerts:")
    for al in out["alerts"][:15]:
        print(
            f"  [{al.get('severity','?'):8s}] {al.get('serviceSource','?'):25s} "
            f"{al.get('createdDateTime','')}  {al.get('title','')[:80]}"
        )
    print()
    print("Top 10 incidents:")
    for inc in out["incidents"][:10]:
        print(
            f"  [{inc.get('severity','?'):8s}] {inc.get('status','?'):12s} "
            f"{inc.get('createdDateTime','')}  {inc.get('displayName','')[:80]}"
        )

    if args.output:
        Path(args.output).write_text(json.dumps(out, indent=2, default=str))
        print(f"\nfull dump -> {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
