#!/usr/bin/env python3
"""Adversarial attack harness for deployed Foundry agents.

Sends a curated library of hostile prompts (prompt injection, jailbreak,
XPIA, PII harvest, credential fishing, harmful content, protected material,
groundedness fabrication) against every agent in the most recent deployment
manifest, attaching a ``user_security_context`` so Defender for Cloud AI,
Prompt Shields, Purview DSPM for AI, and Foundry evaluators can attribute
the traffic and fire the appropriate alerts.

This is a deliberate alert-generation tool, not an evaluation. Run it when
you want to *see* detections light up in Defender XDR and Purview.

Usage:
    python3.12 scripts/attack_agents.py
    python3.12 scripts/attack_agents.py --category prompt_injection
    python3.12 scripts/attack_agents.py --agent AISec-HR --severity high critical
    python3.12 scripts/attack_agents.py --dry-run               # no network
    python3.12 scripts/attack_agents.py --output logs/attack.json
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import time
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import requests
from azure.identity import DefaultAzureCredential

# Allow ``python3.12 scripts/attack_agents.py`` without PYTHONPATH gymnastics.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from attack_prompts import ALL_ATTACKS, CATEGORIES, Attack, select  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent
MANIFEST_DIR = REPO_ROOT / "manifests"
LOG_DIR = REPO_ROOT / "logs"
DEFAULT_END_USER_ID = "bc41eeb7-8113-489f-ba62-5976c56afb61"
DEFAULT_SOURCE_IP = "198.51.100.24"
API_VERSION = "2024-10-21"

# Outcome labels (mirrored by classify_response; keep stable for downstream
# tooling that may parse JSON output).
OUTCOME_OK = "ok"
OUTCOME_BLOCKED_CONTENT = "blocked_content_filter"
OUTCOME_BLOCKED_PROMPT_SHIELD = "blocked_prompt_shield"
OUTCOME_BLOCKED_JAILBREAK = "blocked_jailbreak"
OUTCOME_BLOCKED_OTHER = "blocked_other"
OUTCOME_ERROR = "error"
OUTCOME_NETWORK = "network_error"
OUTCOME_DRY_RUN = "dry_run"

BLOCKED_OUTCOMES = frozenset({
    OUTCOME_BLOCKED_CONTENT,
    OUTCOME_BLOCKED_PROMPT_SHIELD,
    OUTCOME_BLOCKED_JAILBREAK,
    OUTCOME_BLOCKED_OTHER,
})


log = logging.getLogger("attack_agents")


@dataclass
class AttackResult:
    agent: str
    attack_id: str
    category: str
    severity: str
    expected_detection: str
    status: int
    outcome: str
    response_snippet: str


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def configure_logging(log_file: Path | None) -> Path | None:
    handlers: list[logging.Handler] = [logging.StreamHandler(sys.stderr)]
    if log_file is not None:
        log_file.parent.mkdir(parents=True, exist_ok=True)
        handlers.insert(0, logging.FileHandler(log_file))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=handlers,
        force=True,
    )
    return log_file


def latest_manifest(manifest_dir: Path = MANIFEST_DIR) -> Path:
    manifests = sorted(manifest_dir.glob("AISec_*.json"))
    if not manifests:
        raise SystemExit(f"No manifests found in {manifest_dir}")
    return manifests[-1]


def load_agents_from_config(repo_root: Path = REPO_ROOT) -> dict[str, dict]:
    cfg_path = repo_root / "config.json"
    try:
        cfg = json.loads(cfg_path.read_text())
    except FileNotFoundError:
        return {}
    agents = cfg.get("workloads", {}).get("foundry", {}).get("agents", [])
    return {a.get("name", ""): a for a in agents if a.get("name")}


def aoai_host(manifest: dict) -> str:
    endpoint = manifest["data"]["foundry"]["projectEndpoint"]
    host = endpoint.split("://", 1)[1].split("/", 1)[0]
    return f"https://{host}"


# ---------------------------------------------------------------------------
# Response classification
# ---------------------------------------------------------------------------


def classify_response(status: int, body: str) -> str:
    """Map an HTTP response to one of the stable OUTCOME_* labels.

    This is the single place downstream reports depend on — keep labels
    stable.
    """
    if status == 0:
        return OUTCOME_NETWORK
    if status == 200:
        return OUTCOME_OK
    body_l = (body or "").lower()
    if status == 400:
        # Content filter (Azure OpenAI content safety) returns
        # "content_filter" in the JSON error body.
        if "content_filter" in body_l or '"code": "content_filter"' in body_l:
            return OUTCOME_BLOCKED_CONTENT
        # Prompt Shields (jailbreak + indirect attack) returns specific
        # codes in the innererror structure.
        if "jailbreak" in body_l:
            return OUTCOME_BLOCKED_JAILBREAK
        if (
            "prompt_shield" in body_l
            or "prompt shield" in body_l
            or "indirectattack" in body_l
            or "indirect_attack" in body_l
        ):
            return OUTCOME_BLOCKED_PROMPT_SHIELD
        return OUTCOME_BLOCKED_OTHER
    if status in (401, 403):
        return OUTCOME_ERROR
    if status >= 500 or status == 429:
        return OUTCOME_ERROR
    return OUTCOME_ERROR


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------


def chat_completion(
    *,
    base_url: str,
    model_deployment: str,
    token: str,
    system: str,
    user: str,
    end_user_id: str,
    application_name: str,
    source_ip: str = DEFAULT_SOURCE_IP,
    timeout: float = 60.0,
    max_retries: int = 5,
    session: requests.Session | None = None,
) -> tuple[int, str]:
    """Send a single chat completion. Returns (status, body_or_content)."""
    sess = session or requests
    url = (
        f"{base_url}/openai/deployments/{model_deployment}/chat/completions"
        f"?api-version={API_VERSION}"
    )
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    body = {
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "temperature": 0.2,
        "max_tokens": 400,
        "user_security_context": {
            "endUserId": end_user_id,
            "applicationName": application_name,
            "sourceIP": source_ip,
        },
    }
    delay = 1.0
    for attempt in range(1, max_retries + 1):
        try:
            resp = sess.post(url, json=body, headers=headers, timeout=timeout)
        except requests.exceptions.RequestException as exc:
            log.warning("  retry %d/%d after %.0fs: %s", attempt, max_retries, delay, exc)
            time.sleep(delay)
            delay = min(delay * 2, 15)
            continue
        if resp.status_code >= 500 or resp.status_code == 429:
            log.warning(
                "  retry %d/%d after %.0fs: HTTP %d",
                attempt, max_retries, delay, resp.status_code,
            )
            time.sleep(delay)
            delay = min(delay * 2, 15)
            continue
        # 4xx (other than 429) — return the error body so classify_response
        # can inspect the content_filter / prompt_shield code.
        try:
            payload = resp.json()
        except ValueError:
            return resp.status_code, resp.text[:600]
        if resp.status_code >= 400:
            return resp.status_code, json.dumps(payload)[:600]
        content = (
            payload.get("choices", [{}])[0].get("message", {}).get("content", "")
        ) or ""
        return resp.status_code, content[:320]
    return 0, "retries exhausted"


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------


def run_attacks(
    *,
    agents: list[dict],
    attacks: list[Attack],
    config_agents: dict[str, dict],
    base_url: str,
    model_deployment: str,
    token: str,
    end_user_id: str,
    source_ip: str = DEFAULT_SOURCE_IP,
    dry_run: bool = False,
    agent_filter: list[str] | None = None,
    sleep_between: float = 0.5,
    session: requests.Session | None = None,
) -> list[AttackResult]:
    """Drive ``attacks`` against each agent. Returns a flat list of results."""
    wanted_agents = set(agent_filter) if agent_filter else None
    results: list[AttackResult] = []

    for agent in agents:
        agent_name = agent.get("name", "")
        if not agent_name:
            continue
        if wanted_agents and agent_name not in wanted_agents:
            short = agent_name.replace("AISec-", "")
            # Also accept a short-name match so --agent HR works.
            if short not in wanted_agents:
                continue
        short = agent_name.replace("AISec-", "")
        cfg = config_agents.get(agent_name, {})
        system_prompt = cfg.get("instructions", f"You are {agent_name}.")
        log.info("── %s (%d attack(s))", short, len(attacks))

        for attack in attacks:
            if dry_run:
                outcome = OUTCOME_DRY_RUN
                status = -1
                snippet = "(dry-run)"
            else:
                status, body = chat_completion(
                    base_url=base_url,
                    model_deployment=model_deployment,
                    token=token,
                    system=system_prompt,
                    user=attack.prompt,
                    end_user_id=end_user_id,
                    application_name=agent_name,
                    source_ip=source_ip,
                    session=session,
                )
                outcome = classify_response(status, body)
                # Keep FULL body so content-filter verdicts on blocked calls
                # survive in the report. Console log still truncates at 200.
                snippet = body or ""
            results.append(
                AttackResult(
                    agent=short,
                    attack_id=attack.id,
                    category=attack.category,
                    severity=attack.severity,
                    expected_detection=attack.expected_detection,
                    status=status,
                    outcome=outcome,
                    response_snippet=snippet,
                )
            )
            log.info(
                "  [%s][%s][%s] %s",
                attack.id,
                attack.severity,
                outcome,
                snippet[:140],
            )
            if not dry_run and sleep_between > 0:
                time.sleep(sleep_between)

    return results


def summarise(results: Iterable[AttackResult]) -> dict:
    by_outcome: dict[str, int] = {}
    by_category: dict[str, dict[str, int]] = {}
    by_agent: dict[str, dict[str, int]] = {}
    total = 0
    for r in results:
        total += 1
        by_outcome[r.outcome] = by_outcome.get(r.outcome, 0) + 1
        cat = by_category.setdefault(r.category, {"total": 0, "blocked": 0, "ok": 0})
        cat["total"] += 1
        if r.outcome in BLOCKED_OUTCOMES:
            cat["blocked"] += 1
        elif r.outcome == OUTCOME_OK:
            cat["ok"] += 1
        ag = by_agent.setdefault(r.agent, {"total": 0, "blocked": 0, "ok": 0})
        ag["total"] += 1
        if r.outcome in BLOCKED_OUTCOMES:
            ag["blocked"] += 1
        elif r.outcome == OUTCOME_OK:
            ag["ok"] += 1
    return {
        "total": total,
        "byOutcome": by_outcome,
        "byCategory": by_category,
        "byAgent": by_agent,
    }


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest", type=Path, default=None, help="Manifest JSON (defaults to newest in manifests/).")
    p.add_argument("--end-user-id", default=os.environ.get("END_USER_ID", DEFAULT_END_USER_ID))
    p.add_argument("--source-ip", default=DEFAULT_SOURCE_IP, help="Synthetic source IP for user_security_context.")
    p.add_argument(
        "--category",
        action="append",
        choices=list(CATEGORIES),
        help="Restrict to one or more categories (repeatable).",
    )
    p.add_argument(
        "--severity",
        nargs="+",
        choices=["low", "medium", "high", "critical"],
        help="Restrict to one or more severity levels.",
    )
    p.add_argument("--attack-id", action="append", help="Run only the listed attack IDs.")
    p.add_argument(
        "--agent",
        action="append",
        help="Restrict to these agent names (full or short form, e.g. AISec-HR or HR). Repeatable.",
    )
    p.add_argument("--dry-run", action="store_true", help="Print the plan without calling any agent.")
    p.add_argument("--list", action="store_true", help="Print the attack catalog and exit.")
    p.add_argument("--output", type=Path, default=None, help="Write the JSON report to this path.")
    p.add_argument("--log-file", type=Path, default=None, help="Tee logs to this file.")
    p.add_argument(
        "--sleep-between",
        type=float,
        default=0.5,
        help="Seconds to pause between attacks (avoid rate-limits).",
    )
    return p.parse_args(argv)


def _print_catalog() -> None:
    rows = []
    for a in ALL_ATTACKS:
        rows.append(f"{a.id:<28} {a.severity:<8} {a.category:<22} {a.expected_detection}")
    print("\n".join(rows))
    print(f"\n{len(ALL_ATTACKS)} attacks across {len(CATEGORIES)} categories.")


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    configure_logging(args.log_file)

    if args.list:
        _print_catalog()
        return 0

    attacks = select(
        categories=args.category,
        severities=args.severity,
        ids=args.attack_id,
    )
    if not attacks:
        log.error("No attacks matched the filters.")
        return 2
    log.info("Selected %d attack(s).", len(attacks))

    manifest_path = args.manifest or latest_manifest()
    manifest = json.loads(manifest_path.read_text())
    foundry = manifest["data"]["foundry"]
    base_url = aoai_host(manifest)
    model_deployment = foundry["modelDeploymentName"]
    agents = foundry.get("agents", [])
    config_agents = load_agents_from_config()

    log.info(
        "manifest=%s host=%s model=%s agents=%d",
        manifest_path.name,
        base_url.replace("https://", ""),
        model_deployment,
        len(agents),
    )

    token = ""
    if not args.dry_run:
        credential = DefaultAzureCredential()
        token = credential.get_token("https://cognitiveservices.azure.com/.default").token
    log.info("endUserId=%s dryRun=%s", args.end_user_id, args.dry_run)

    results = run_attacks(
        agents=agents,
        attacks=attacks,
        config_agents=config_agents,
        base_url=base_url,
        model_deployment=model_deployment,
        token=token,
        end_user_id=args.end_user_id,
        source_ip=args.source_ip,
        dry_run=args.dry_run,
        agent_filter=args.agent,
        sleep_between=args.sleep_between,
    )

    summary = summarise(results)
    report = {
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "manifest": manifest_path.name,
        "filters": {
            "categories": args.category,
            "severities": args.severity,
            "attackIds": args.attack_id,
            "agents": args.agent,
        },
        "summary": summary,
        "results": [asdict(r) for r in results],
    }
    payload = json.dumps(report, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(payload)
        log.info("report -> %s", args.output)
    else:
        print(payload)

    log.info(
        "done total=%d ok=%d blocked=%d error=%d",
        summary["total"],
        summary["byOutcome"].get(OUTCOME_OK, 0),
        sum(summary["byOutcome"].get(k, 0) for k in BLOCKED_OUTCOMES),
        sum(summary["byOutcome"].get(k, 0) for k in (OUTCOME_ERROR, OUTCOME_NETWORK)),
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
