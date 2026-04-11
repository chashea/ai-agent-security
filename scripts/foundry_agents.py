#!/usr/bin/env python3
"""Foundry agent operations using the Azure AI Projects SDK.

Handles agent CRUD, Purview governance toggle, and application publishing.
Called by the PowerShell orchestrator (Foundry.psm1) with JSON input on a
temp file and returns JSON manifest to stdout.

Usage:
    python3.12 foundry_agents.py --action deploy --config input.json
    python3.12 foundry_agents.py --action remove --config input.json
"""

import argparse
import json
import logging
import sys

import requests
from azure.identity import DefaultAzureCredential

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)


def _get_token(credential: DefaultAzureCredential, scope: str) -> str:
    return credential.get_token(scope).token


def _arm_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _data_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ── Purview Governance ───────────────────────────────────────────────────────


def enable_purview_governance(
    project_endpoint: str, data_token: str, agent_api_version: str
) -> bool:
    """Enable Purview governance integration on the Foundry project."""
    url = f"{project_endpoint}/governance/settings?api-version={agent_api_version}"
    body = {"purviewIntegrationEnabled": True}
    try:
        resp = requests.put(url, json=body, headers=_data_headers(data_token))
        if resp.status_code < 400:
            log.info("Purview governance integration enabled.")
            return True
        log.warning(
            "Purview governance toggle returned HTTP %d: %s",
            resp.status_code,
            resp.text,
        )
    except Exception as exc:
        log.warning("Purview governance toggle failed: %s", exc)
    return False


# ── Agent CRUD ───────────────────────────────────────────────────────────────


def create_agent(
    project_endpoint: str,
    data_token: str,
    agent_api_version: str,
    agent_name: str,
    model: str,
    instructions: str,
    description: str | None = None,
    tools: list[dict] | None = None,
) -> dict | None:
    """Create a prompt agent with optional tools. Returns agent dict or None."""
    headers = _data_headers(data_token)

    # Idempotency: check if agent already exists
    check_url = (
        f"{project_endpoint}/agents/{agent_name}?api-version={agent_api_version}"
    )
    check_resp = requests.get(check_url, headers=headers)
    if check_resp.status_code == 200:
        log.info("Agent already exists: %s", agent_name)
        return {"id": agent_name, "name": agent_name, "model": model}

    # Create agent
    url = f"{project_endpoint}/agents?api-version={agent_api_version}"
    definition: dict = {"kind": "prompt", "model": model, "instructions": instructions}
    if tools:
        definition["tools"] = tools

    payload: dict = {"name": agent_name, "definition": definition}
    if description:
        payload["description"] = description

    resp = requests.post(url, json=payload, headers=headers)
    if resp.status_code < 400:
        result = resp.json()
        agent_id = result.get("id", agent_name)
        log.info("Created agent: %s (id: %s)", agent_name, agent_id)
        return {"id": agent_id, "name": agent_name, "model": model}

    log.warning(
        "Agent creation failed for '%s' (HTTP %d): %s",
        agent_name,
        resp.status_code,
        resp.text,
    )
    return None


def delete_agent(
    project_endpoint: str, data_token: str, agent_api_version: str, agent_id: str, agent_name: str
) -> bool:
    """Delete an agent by ID."""
    url = f"{project_endpoint}/agents/{agent_id}?api-version={agent_api_version}"
    resp = requests.delete(url, headers=_data_headers(data_token))
    if resp.status_code < 400:
        log.info("Deleted agent: %s (%s)", agent_name, agent_id)
        return True
    log.warning(
        "Agent delete HTTP %d for '%s': %s", resp.status_code, agent_name, resp.text
    )
    return False


# ── Application Publishing ───────────────────────────────────────────────────


def publish_application(
    account_path: str,
    project_name: str,
    arm_token: str,
    app_api_version: str,
    agent_name: str,
) -> str | None:
    """Publish an agent as a Foundry application endpoint. Returns baseUrl or None."""
    app_url = (
        f"{account_path}/projects/{project_name}/applications/{agent_name}"
        f"?api-version={app_api_version}"
    )
    headers = _arm_headers(arm_token)

    # Check if already published
    check_resp = requests.get(app_url, headers=headers)
    if check_resp.status_code == 200:
        base_url = check_resp.json().get("properties", {}).get("baseUrl", "")
        log.info("Application already published: %s", agent_name)
        return base_url

    body = {
        "properties": {
            "displayName": agent_name,
            "agents": [{"agentName": agent_name}],
        }
    }
    resp = requests.put(app_url, json=body, headers=headers)
    if resp.status_code < 400:
        base_url = resp.json().get("properties", {}).get("baseUrl", "")
        log.info("Published agent: %s -> %s", agent_name, base_url)
        return base_url

    log.warning(
        "Publish failed for '%s' (HTTP %d): %s",
        agent_name,
        resp.status_code,
        resp.text,
    )
    return None


def unpublish_application(
    account_path: str,
    project_name: str,
    arm_token: str,
    app_api_version: str,
    agent_name: str,
) -> bool:
    """Unpublish an agent application."""
    app_url = (
        f"{account_path}/projects/{project_name}/applications/{agent_name}"
        f"?api-version={app_api_version}"
    )
    resp = requests.delete(app_url, headers=_arm_headers(arm_token))
    if resp.status_code < 400:
        log.info("Unpublished application: %s", agent_name)
        return True
    log.warning(
        "Unpublish failed for '%s' (HTTP %d): %s",
        agent_name,
        resp.status_code,
        resp.text,
    )
    return False


# ── Deploy Action ────────────────────────────────────────────────────────────


def deploy(config: dict) -> dict:
    """Deploy agents and publish as applications. Returns manifest JSON."""
    credential = DefaultAzureCredential()
    arm_token = _get_token(credential, "https://management.azure.com/.default")
    data_token = _get_token(credential, "https://ai.azure.com/.default")

    project_endpoint = config["projectEndpoint"]
    account_name = config["accountName"]
    project_name = config["projectName"]
    subscription_id = config["subscriptionId"]
    resource_group = config["resourceGroup"]
    prefix = config["prefix"]

    agent_api_version = config.get("agentApiVersion", "2025-05-15-preview")
    app_api_version = config.get("appApiVersion", "2025-10-01-preview")

    arm_base = "https://management.azure.com"
    account_path = (
        f"{arm_base}/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{account_name}"
    )

    # 1. Purview governance
    purview_enabled = enable_purview_governance(
        project_endpoint, data_token, agent_api_version
    )

    # 2. Create agents (with tools if provided)
    agents = []
    tool_definitions = config.get("toolDefinitions", {})
    for agent_cfg in config.get("agents", []):
        agent_name = f"{prefix}-{agent_cfg['name']}"
        agent_tools = tool_definitions.get(agent_cfg["name"])
        result = create_agent(
            project_endpoint=project_endpoint,
            data_token=data_token,
            agent_api_version=agent_api_version,
            agent_name=agent_name,
            model=agent_cfg["model"],
            instructions=agent_cfg["instructions"],
            description=agent_cfg.get("description"),
            tools=agent_tools,
        )
        if result:
            if agent_tools:
                result["toolCount"] = len(agent_tools)
            agents.append(result)

    # 3. Publish as applications
    for agent in agents:
        base_url = publish_application(
            account_path=account_path,
            project_name=project_name,
            arm_token=arm_token,
            app_api_version=app_api_version,
            agent_name=agent["name"],
        )
        if base_url:
            agent["baseUrl"] = base_url

    return {
        "purviewIntegrationEnabled": purview_enabled,
        "agents": agents,
    }


# ── Remove Action ────────────────────────────────────────────────────────────


def remove(config: dict) -> dict:
    """Remove agents and unpublish applications. Returns confirmation."""
    credential = DefaultAzureCredential()
    arm_token = _get_token(credential, "https://management.azure.com/.default")
    data_token = _get_token(credential, "https://ai.azure.com/.default")

    project_endpoint = config["projectEndpoint"]
    account_name = config["accountName"]
    project_name = config["projectName"]
    subscription_id = config["subscriptionId"]
    resource_group = config["resourceGroup"]

    agent_api_version = config.get("agentApiVersion", "2025-05-15-preview")
    app_api_version = config.get("appApiVersion", "2025-10-01-preview")

    arm_base = "https://management.azure.com"
    account_path = (
        f"{arm_base}/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{account_name}"
    )

    agents = config.get("agents", [])
    removed_apps = []
    removed_agents = []

    # 1. Unpublish applications
    for agent in agents:
        name = agent.get("name", "")
        if not name:
            continue
        if unpublish_application(
            account_path, project_name, arm_token, app_api_version, name
        ):
            removed_apps.append(name)

    # 2. Delete agents
    for agent in agents:
        agent_id = agent.get("id", "")
        name = agent.get("name", "")
        if not agent_id:
            continue
        if delete_agent(
            project_endpoint, data_token, agent_api_version, agent_id, name
        ):
            removed_agents.append(name)

    return {
        "removedApplications": removed_apps,
        "removedAgents": removed_agents,
    }


# ── CLI ──────────────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="Foundry agent operations")
    parser.add_argument(
        "--action",
        required=True,
        choices=["deploy", "remove"],
        help="Action to perform",
    )
    parser.add_argument(
        "--config", required=True, help="Path to JSON config file"
    )
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    if args.action == "deploy":
        result = deploy(config)
    else:
        result = remove(config)

    # Output manifest to stdout (PowerShell captures this)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log.error("Fatal error: %s", exc)
        sys.exit(1)
