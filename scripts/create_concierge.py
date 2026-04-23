#!/usr/bin/env python3.12
"""Delta-apply: create or update only the Concierge orchestrator agent.

Reads `config.json`, finds the `Concierge` agent definition, queries the
live Foundry project for the existing specialist agent IDs, builds the
`connected_agent` tool list, and POSTs the agent. Does NOT touch the
other agents, the Foundry project, the model deployment, or infra.

Idempotent: if the Concierge already exists, it's DELETEd and recreated
with the current tool list (Foundry prompt agents have no PATCH).

Usage:
    python3.12 scripts/create_concierge.py
    python3.12 scripts/create_concierge.py --prefix AISec --dry-run
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys

import requests
from azure.identity import DefaultAzureCredential

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("concierge")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_CONFIG = os.path.join(REPO_ROOT, "config.json")
DEFAULT_API_VERSION = "2025-05-15-preview"


def _load_config(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def _get_data_token() -> str:
    return DefaultAzureCredential().get_token("https://ai.azure.com/.default").token


def _headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _list_live_agents(project_endpoint: str, token: str, api_version: str) -> dict[str, str]:
    """Return {agent_name: agent_id} for every agent currently in the project."""
    url = f"{project_endpoint.rstrip('/')}/agents?api-version={api_version}"
    resp = requests.get(url, headers=_headers(token), timeout=60)
    resp.raise_for_status()
    body = resp.json()
    entries = body.get("data") if isinstance(body, dict) else body
    result: dict[str, str] = {}
    for entry in entries or []:
        name = entry.get("name") or ""
        agent_id = entry.get("id") or entry.get("assistant_id") or ""
        if name and agent_id:
            result[name] = agent_id
    return result


def _build_connected_tools(
    concierge_cfg: dict,
    live: dict[str, str],
    prefix: str,
) -> list[dict]:
    """Build connected_agent tool defs from Concierge config + live agent map.

    Target resolution: try `<prefix>-<targetName>` first (matches deploy-time
    naming), then `<targetName>` as a fallback.
    """
    tools: list[dict] = []
    dropped: list[str] = []
    for tool in concierge_cfg.get("tools", []):
        if tool.get("type") != "connected_agent":
            continue
        target_name = tool.get("targetName") or tool.get("target") or ""
        tool_call_name = tool.get("name") or target_name.replace("-", "_").replace(" ", "_")
        description = tool.get("description") or f"Delegate to {target_name}"
        candidates = [f"{prefix}-{target_name}", target_name] if prefix else [target_name]
        agent_id = next((live[c] for c in candidates if c in live), None)
        if not agent_id:
            dropped.append(target_name)
            continue
        tools.append(
            {
                "type": "connected_agent",
                "connected_agent": {
                    "id": agent_id,
                    "name": tool_call_name,
                    "description": description,
                },
            }
        )
    if dropped:
        log.warning(
            "Skipping %d connected_agent tool(s) with no live target: %s",
            len(dropped),
            ", ".join(dropped),
        )
    return tools


def _delete_if_present(project_endpoint: str, token: str, api_version: str, agent_name: str) -> None:
    url = f"{project_endpoint.rstrip('/')}/agents/{agent_name}?api-version={api_version}"
    resp = requests.get(url, headers=_headers(token), timeout=30)
    if resp.status_code == 200:
        log.info("Deleting existing agent '%s' (delete-and-recreate)", agent_name)
        del_resp = requests.delete(url, headers=_headers(token), timeout=60)
        if del_resp.status_code >= 400:
            raise RuntimeError(
                f"Failed to delete existing '{agent_name}' (HTTP {del_resp.status_code}): {del_resp.text[:400]}"
            )
    elif resp.status_code == 404:
        log.info("No existing agent named '%s' — creating fresh.", agent_name)
    else:
        log.warning(
            "GET on existing agent returned HTTP %d: %s",
            resp.status_code,
            resp.text[:400],
        )


def _create_agent(
    project_endpoint: str,
    token: str,
    api_version: str,
    agent_name: str,
    model: str,
    instructions: str,
    description: str,
    tools: list[dict],
) -> dict:
    url = f"{project_endpoint.rstrip('/')}/agents?api-version={api_version}"
    definition = {"kind": "prompt", "model": model, "instructions": instructions}
    if tools:
        definition["tools"] = tools
    payload = {"name": agent_name, "description": description, "definition": definition}
    resp = requests.post(url, headers=_headers(token), json=payload, timeout=120)
    if resp.status_code >= 400:
        raise RuntimeError(
            f"Agent create failed (HTTP {resp.status_code}): {resp.text[:600]}"
        )
    return resp.json()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=DEFAULT_CONFIG, help="Path to config.json")
    parser.add_argument("--agent-name", default="Concierge", help="Agent name in config.json (default: Concierge)")
    parser.add_argument("--prefix", default=None, help="Override deployed-agent prefix (defaults to config.prefix)")
    parser.add_argument("--api-version", default=None, help=f"Agent API version (default from config or {DEFAULT_API_VERSION})")
    parser.add_argument("--project-endpoint", default=None, help="Override Foundry project endpoint")
    parser.add_argument("--dry-run", action="store_true", help="Print what would be sent and exit")
    args = parser.parse_args()

    cfg = _load_config(args.config)
    fw = cfg.get("workloads", {}).get("foundry", {})
    prefix = args.prefix or cfg.get("prefix", "")
    api_version = args.api_version or fw.get("agentApiVersion") or DEFAULT_API_VERSION

    agents_cfg = fw.get("agents", [])
    concierge = next((a for a in agents_cfg if a.get("name") == args.agent_name), None)
    if not concierge:
        log.error("Agent '%s' not found in config.json", args.agent_name)
        return 2

    deployed_name = f"{prefix}-{args.agent_name}" if prefix else args.agent_name
    project_endpoint = args.project_endpoint or fw.get("projectEndpoint")
    if not project_endpoint:
        # Reconstruct default Foundry project endpoint from account+project names.
        account = fw.get("accountName")
        project = fw.get("projectName")
        if account and project:
            project_endpoint = f"https://{account}.services.ai.azure.com/api/projects/{project}"
            log.info("Derived projectEndpoint: %s", project_endpoint)
        else:
            log.error(
                "Cannot determine projectEndpoint. Pass --project-endpoint or add "
                "workloads.foundry.projectEndpoint to config.json."
            )
            return 2

    log.info("Acquiring ai.azure.com token via DefaultAzureCredential...")
    token = _get_data_token()

    log.info("Listing live agents in project...")
    live = _list_live_agents(project_endpoint, token, api_version)
    log.info("Found %d live agent(s): %s", len(live), ", ".join(sorted(live.keys())))

    tools = _build_connected_tools(concierge, live, prefix)
    if not tools:
        log.error("No connected_agent tools resolved — refusing to create an empty orchestrator.")
        return 3

    payload_preview = {
        "name": deployed_name,
        "description": concierge.get("description", ""),
        "definition": {
            "kind": "prompt",
            "model": concierge.get("model", "gpt-4o"),
            "instructions": concierge.get("instructions", ""),
            "tools": tools,
        },
    }
    print(json.dumps({"targetEndpoint": project_endpoint, "agent": payload_preview}, indent=2))

    if args.dry_run:
        log.info("--dry-run set; no API calls made.")
        return 0

    _delete_if_present(project_endpoint, token, api_version, deployed_name)
    result = _create_agent(
        project_endpoint,
        token,
        api_version,
        deployed_name,
        model=concierge.get("model", "gpt-4o"),
        instructions=concierge.get("instructions", ""),
        description=concierge.get("description", ""),
        tools=tools,
    )
    log.info("Created agent '%s' (id=%s) with %d connected_agent tools.",
             deployed_name, result.get("id", "?"), len(tools))
    return 0


if __name__ == "__main__":
    sys.exit(main())
