#!/usr/bin/env python3
"""Defender XDR alerts → Security-Triage Foundry agent demo.

Fetches recent Defender alerts via Microsoft Graph, pipes each one to the
deployed Security-Triage agent as a thread input, polls the run to
completion, and writes a structured log with the triage response per
alert.

Usage:
    python3.12 scripts/demo_security_triage.py
    python3.12 scripts/demo_security_triage.py --since-minutes 120 --top 5
    python3.12 scripts/demo_security_triage.py --manifest manifests/AISec_20260417-125451768.json

Auth: DefaultAzureCredential. `az login` + `az account set` must point at
the target tenant/subscription; see project CLAUDE.md.

Outputs: logs/security-triage-demo-<UTC-timestamp>.json
"""
from __future__ import annotations

import argparse
import json
import logging
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from azure.identity import DefaultAzureCredential

# Local sibling imports
_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

from fetch_defender_alerts import fetch_alerts  # noqa: E402

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("demo_security_triage")


SEVERITY_RANK = {"high": 0, "medium": 1, "low": 2, "informational": 3}
DEFAULT_MANIFEST_DIR = "manifests"
DEFAULT_AGENT_NAME_SUBSTRING = "Security-Triage"
DEFAULT_API_VERSION = "2025-05-15-preview"


def _data_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _find_latest_manifest(manifest_dir: Path) -> Path | None:
    if not manifest_dir.is_dir():
        return None
    files = sorted(
        (p for p in manifest_dir.glob("*.json") if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return files[0] if files else None


def _load_triage_context(manifest_path: Path, agent_name_substring: str) -> dict:
    """Extract project endpoint + Security-Triage agent id from a manifest."""
    with manifest_path.open(encoding="utf-8") as fh:
        m = json.load(fh)
    foundry = m.get("data", {}).get("foundry", {})
    project_endpoint = foundry.get("projectEndpoint", "")
    agents = foundry.get("agents", []) or []
    triage = next(
        (a for a in agents if agent_name_substring in (a.get("name") or "")),
        None,
    )
    if not project_endpoint:
        raise RuntimeError(f"projectEndpoint missing from manifest {manifest_path}")
    if not triage:
        raise RuntimeError(
            f"No agent matching '{agent_name_substring}' in {manifest_path}. "
            f"Available: {[a.get('name') for a in agents]}"
        )
    return {
        "project_endpoint": project_endpoint,
        "agent_id": triage.get("id") or triage.get("name"),
        "agent_name": triage.get("name"),
        "manifest_path": str(manifest_path),
    }


def _rank_alerts(alerts: list[dict], top: int) -> list[dict]:
    """Pick top-N alerts, highest severity first, newest within severity."""
    def key(al: dict) -> tuple:
        sev = SEVERITY_RANK.get((al.get("severity") or "").lower(), 99)
        created = al.get("createdDateTime") or ""
        # Negate string for reverse order on created: easier to do manually
        return (sev, _invert_iso(created))

    return sorted(alerts, key=key)[:top]


def _invert_iso(iso_str: str) -> str:
    """Invert an ISO-8601 timestamp for reverse sort (newer first)."""
    if not iso_str:
        return ""
    return "".join(chr(255 - ord(c)) if c.isdigit() else c for c in iso_str)


def _build_triage_prompt(alert: dict) -> str:
    """Shape the user message sent to Security-Triage for one alert."""
    summary_keys = (
        "id",
        "title",
        "severity",
        "status",
        "serviceSource",
        "detectionSource",
        "category",
        "classification",
        "createdDateTime",
        "description",
        "providerAlertId",
        "incidentId",
    )
    summary = {k: alert.get(k) for k in summary_keys if alert.get(k) is not None}
    return (
        "Triage this Defender XDR alert. Confirm severity, summarize what the alert "
        "indicates, pull any relevant correlated signals you can find via hunting "
        "queries, and recommend next actions. Respect your read-only scope — do not "
        "propose modifications.\n\n"
        "Alert (JSON):\n"
        f"{json.dumps(summary, indent=2, default=str)}"
    )


def run_triage(
    project_endpoint: str,
    data_token: str,
    agent_id: str,
    prompt: str,
    api_version: str,
    poll_attempts: int = 60,
    poll_interval_s: float = 2.0,
) -> dict:
    """Send prompt to the agent via thread/message/run and return response + metadata."""
    headers = _data_headers(data_token)
    start = time.monotonic()
    thread_id = None
    run_status = "unknown"
    assistant_response = ""
    error: str | None = None
    try:
        thread_resp = requests.post(
            f"{project_endpoint}/threads?api-version={api_version}",
            json={},
            headers=headers,
            timeout=30,
        )
        thread_resp.raise_for_status()
        thread_id = thread_resp.json()["id"]

        requests.post(
            f"{project_endpoint}/threads/{thread_id}/messages?api-version={api_version}",
            json={"role": "user", "content": prompt},
            headers=headers,
            timeout=30,
        ).raise_for_status()

        run_resp = requests.post(
            f"{project_endpoint}/threads/{thread_id}/runs?api-version={api_version}",
            json={"assistant_id": agent_id},
            headers=headers,
            timeout=30,
        )
        run_resp.raise_for_status()
        run_id = run_resp.json()["id"]

        for _ in range(poll_attempts):
            status_resp = requests.get(
                f"{project_endpoint}/threads/{thread_id}/runs/{run_id}"
                f"?api-version={api_version}",
                headers=headers,
                timeout=15,
            )
            status_resp.raise_for_status()
            run_status = status_resp.json().get("status", "")
            if run_status in ("completed", "failed", "cancelled", "expired"):
                break
            time.sleep(poll_interval_s)

        if run_status == "completed":
            msgs_resp = requests.get(
                f"{project_endpoint}/threads/{thread_id}/messages"
                f"?api-version={api_version}&order=desc&limit=1",
                headers=headers,
                timeout=15,
            )
            msgs_resp.raise_for_status()
            messages = msgs_resp.json().get("data", [])
            if messages:
                content_blocks = messages[0].get("content", []) or []
                text_parts = [
                    b.get("text", {}).get("value", "")
                    for b in content_blocks
                    if b.get("type") == "text"
                ]
                assistant_response = "\n".join(p for p in text_parts if p)
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
        log.warning("triage call failed: %s", error)
    finally:
        if thread_id:
            try:
                requests.delete(
                    f"{project_endpoint}/threads/{thread_id}?api-version={api_version}",
                    headers=headers,
                    timeout=10,
                )
            except Exception:
                pass

    return {
        "run_status": run_status,
        "duration_ms": int((time.monotonic() - start) * 1000),
        "assistant_response": assistant_response,
        "error": error,
    }


def run_demo(args: argparse.Namespace) -> dict:
    manifest_path = Path(args.manifest) if args.manifest else _find_latest_manifest(
        Path(args.manifest_dir)
    )
    if manifest_path is None:
        raise RuntimeError(
            f"No manifests found in {args.manifest_dir}. Run Deploy.ps1 first, "
            f"or pass --manifest <path>."
        )
    ctx = _load_triage_context(manifest_path, args.agent_name_substring)
    log.info("Using agent %s from manifest %s", ctx["agent_name"], manifest_path.name)

    alerts_payload = fetch_alerts(since_minutes=args.since_minutes, top=args.fetch_top)
    alerts = alerts_payload.get("alerts", [])
    log.info("Fetched %d alerts from Graph (window=%dm)", len(alerts), args.since_minutes)
    if alerts_payload.get("alertsError"):
        log.warning("Graph alerts error: %s", alerts_payload["alertsError"])

    selected = _rank_alerts(alerts, top=args.top)
    log.info("Selected %d alerts for triage", len(selected))

    credential = DefaultAzureCredential()
    data_token = credential.get_token("https://ai.azure.com/.default").token

    results: list[dict] = []
    for idx, alert in enumerate(selected, start=1):
        log.info(
            "[%d/%d] triaging alert %s (severity=%s)",
            idx,
            len(selected),
            alert.get("id", "?"),
            alert.get("severity", "?"),
        )
        prompt = _build_triage_prompt(alert)
        triage = run_triage(
            project_endpoint=ctx["project_endpoint"],
            data_token=data_token,
            agent_id=ctx["agent_id"],
            prompt=prompt,
            api_version=args.api_version,
        )
        results.append(
            {
                "alert": alert,
                "run_status": triage["run_status"],
                "duration_ms": triage["duration_ms"],
                "assistant_response": triage["assistant_response"],
                "error": triage["error"],
            }
        )

    report = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "manifest": ctx["manifest_path"],
        "agent": {"id": ctx["agent_id"], "name": ctx["agent_name"]},
        "window": {"sinceMinutes": args.since_minutes, "selected": len(selected), "fetched": len(alerts)},
        "results": results,
    }

    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_path = out_dir / f"security-triage-demo-{stamp}.json"
    out_path.write_text(json.dumps(report, indent=2, default=str), encoding="utf-8")
    log.info("Wrote %s", out_path)

    # Compact human summary to stdout
    print(f"manifest: {ctx['manifest_path']}")
    print(f"agent:    {ctx['agent_name']} ({ctx['agent_id']})")
    print(f"fetched:  {len(alerts)} alerts, triaged {len(selected)}")
    for i, r in enumerate(results, start=1):
        al = r["alert"]
        status = r["run_status"]
        ms = r["duration_ms"]
        preview = (r["assistant_response"] or r.get("error") or "")[:120].replace("\n", " ")
        print(
            f"  [{i}] {status:10s} {ms:>6}ms  "
            f"sev={al.get('severity','?')} "
            f"src={al.get('serviceSource','?')}  {preview}"
        )
    print(f"log: {out_path}")
    return report


def main() -> int:
    ap = argparse.ArgumentParser(description="Defender alerts → Security-Triage agent demo")
    ap.add_argument("--since-minutes", type=int, default=60, help="Graph alert lookback window")
    ap.add_argument("--fetch-top", type=int, default=50, help="Max alerts to pull from Graph")
    ap.add_argument("--top", type=int, default=3, help="Top-N alerts to triage (highest severity first)")
    ap.add_argument("--manifest", default=None, help="Explicit manifest path (default: newest in manifests/)")
    ap.add_argument("--manifest-dir", default=DEFAULT_MANIFEST_DIR)
    ap.add_argument("--agent-name-substring", default=DEFAULT_AGENT_NAME_SUBSTRING)
    ap.add_argument("--api-version", default=DEFAULT_API_VERSION)
    ap.add_argument("--output-dir", default="logs")
    args = ap.parse_args()
    try:
        run_demo(args)
    except Exception as exc:
        log.error("demo failed: %s", exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
