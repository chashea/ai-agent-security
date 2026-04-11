#!/usr/bin/env python3
"""Foundry project connections and agent tool definitions.

Sets up project connections (AI Search, Bing, Blob Storage) and builds
tool definition dicts for agent creation payloads.

Usage:
    python3.12 foundry_tools.py --action setup-connections --config input.json
    python3.12 foundry_tools.py --action build-tools --config input.json
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


def _data_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ── Project Connections ──────────────────────────────────────────────────────


def create_connection(
    project_endpoint: str,
    data_token: str,
    agent_api_version: str,
    connection_name: str,
    connection_type: str,
    target: str,
    credentials: dict | None = None,
) -> dict | None:
    """Create a project connection. Returns connection dict or None."""
    url = f"{project_endpoint}/connections/{connection_name}?api-version={agent_api_version}"
    headers = _data_headers(data_token)

    # Check if exists
    check = requests.get(url, headers=headers)
    if check.status_code == 200:
        log.info("Connection already exists: %s", connection_name)
        result = check.json()
        return {"name": connection_name, "id": result.get("id", connection_name)}

    body: dict = {
        "properties": {
            "category": connection_type,
            "target": target,
            "authType": "AAD" if not credentials else "ApiKey",
        }
    }
    if credentials:
        body["properties"]["credentials"] = credentials

    resp = requests.put(url, json=body, headers=headers)
    if resp.status_code < 400:
        result = resp.json()
        log.info("Created connection: %s (%s)", connection_name, connection_type)
        return {"name": connection_name, "id": result.get("id", connection_name)}

    log.warning(
        "Connection creation failed for '%s' (HTTP %d): %s",
        connection_name,
        resp.status_code,
        resp.text,
    )
    return None


def setup_connections(config: dict) -> dict:
    """Create all project connections from config. Returns connection IDs."""
    credential = DefaultAzureCredential()
    data_token = _get_token(credential, "https://ai.azure.com/.default")

    project_endpoint = config["projectEndpoint"]
    api_version = config.get("agentApiVersion", "2025-05-15-preview")
    connections_cfg = config.get("connections", {})
    prefix = config.get("prefix", "AISec")
    result = {}

    # AI Search connection
    if "aiSearch" in connections_cfg:
        ai_search = connections_cfg["aiSearch"]
        conn = create_connection(
            project_endpoint,
            data_token,
            api_version,
            f"{prefix}-ai-search",
            "CognitiveSearch",
            ai_search.get("endpoint", ""),
        )
        if conn:
            result["aiSearch"] = conn

    # Bing Search connection
    if "bingSearch" in connections_cfg:
        conn = create_connection(
            project_endpoint,
            data_token,
            api_version,
            f"{prefix}-bing-search",
            "BingSearch",
            "https://api.bing.microsoft.com/",
        )
        if conn:
            result["bingSearch"] = conn

    # Blob Storage connection
    if "blobStorage" in connections_cfg:
        blob = connections_cfg["blobStorage"]
        conn = create_connection(
            project_endpoint,
            data_token,
            api_version,
            f"{prefix}-blob-storage",
            "AzureBlob",
            blob.get("endpoint", ""),
        )
        if conn:
            result["blobStorage"] = conn

    return {"connections": result}


# ── Tool Definition Builder ──────────────────────────────────────────────────


def build_tool_definitions(
    agent_tools: list[dict],
    vector_store_ids: list[str] | None = None,
    connection_ids: dict | None = None,
    agents_manifest: list[dict] | None = None,
    project_endpoint: str | None = None,
) -> list[dict]:
    """Convert config tool stubs into Foundry API-ready tool definition dicts."""
    definitions = []

    for tool in agent_tools:
        tool_type = tool.get("type", "")

        if tool_type == "code_interpreter":
            definitions.append({"type": "code_interpreter"})

        elif tool_type == "file_search":
            spec: dict = {"type": "file_search"}
            if vector_store_ids:
                spec["vector_store_ids"] = vector_store_ids
            definitions.append(spec)

        elif tool_type == "azure_ai_search":
            conn_id = ""
            if connection_ids and "aiSearch" in connection_ids:
                conn_id = connection_ids["aiSearch"].get("id", "")
            index_name = tool.get("indexName", "aisec-compliance-index")
            definitions.append({
                "type": "azure_ai_search",
                "azure_ai_search": {
                    "indexes": [{
                        "project_connection_id": conn_id,
                        "index_name": index_name,
                        "query_type": "semantic",
                        "top_k": 5,
                    }]
                },
            })

        elif tool_type == "bing_grounding":
            conn_id = ""
            if connection_ids and "bingSearch" in connection_ids:
                conn_id = connection_ids["bingSearch"].get("id", "")
            definitions.append({
                "type": "bing_grounding",
                "bing_grounding": {
                    "search_configurations": [{
                        "project_connection_id": conn_id,
                        "market": "en-US",
                        "count": 5,
                    }]
                },
            })

        elif tool_type == "openapi":
            openapi_cfg = tool.get("config", {})
            spec_obj = {
                "openapi": "3.0.1",
                "info": {"title": openapi_cfg.get("name", "API"), "version": "1.0.0"},
                "servers": [{"url": openapi_cfg.get("url", "")}],
                "paths": openapi_cfg.get("paths", {}),
            }
            definitions.append({
                "type": "openapi",
                "openapi": {
                    "name": openapi_cfg.get("name", "api"),
                    "description": openapi_cfg.get("description", ""),
                    "spec": spec_obj,
                    "auth": {"type": "anonymous"},
                },
            })

        elif tool_type == "azure_function":
            func_cfg = tool.get("config", {})
            definitions.append({
                "type": "azure_function",
                "azure_function": {
                    "function": {
                        "name": func_cfg.get("name", ""),
                        "description": func_cfg.get("description", ""),
                        "parameters": func_cfg.get("parameters", {}),
                    },
                    "input_binding": {
                        "type": "storage_queue",
                        "storage_queue": {
                            "queue_service_endpoint": func_cfg.get("queueEndpoint", ""),
                            "queue_name": func_cfg.get("queueName", "agent-tasks"),
                        },
                    },
                    "output_binding": {
                        "type": "storage_queue",
                        "storage_queue": {
                            "queue_service_endpoint": func_cfg.get("queueEndpoint", ""),
                            "queue_name": func_cfg.get("outputQueueName", "agent-results"),
                        },
                    },
                },
            })

        elif tool_type == "function":
            func_cfg = tool.get("function", tool.get("config", {}))
            definitions.append({
                "type": "function",
                "function": {
                    "name": func_cfg.get("name", ""),
                    "description": func_cfg.get("description", ""),
                    "parameters": func_cfg.get("parameters", {}),
                    "strict": func_cfg.get("strict", True),
                },
            })

        elif tool_type == "mcp":
            mcp_cfg = tool.get("config", {})
            definitions.append({
                "type": "mcp",
                "server_label": mcp_cfg.get("serverLabel", ""),
                "server_url": mcp_cfg.get("serverUrl", ""),
                "require_approval": mcp_cfg.get("requireApproval", "never"),
            })

        elif tool_type == "sharepoint_grounding":
            conn_id = tool.get("connectionId", "")
            definitions.append({
                "type": "sharepoint_grounding_preview",
                "sharepoint_grounding": {
                    "connections": [{"connection_id": conn_id}]
                },
            })

        elif tool_type == "a2a":
            a2a_agents = []
            if agents_manifest:
                for a in agents_manifest:
                    base_url = a.get("baseUrl", "")
                    if base_url:
                        a2a_agents.append({
                            "name": a.get("name", ""),
                            "url": base_url,
                            "description": a.get("description", ""),
                        })
            if a2a_agents:
                definitions.append({
                    "type": "a2a_preview",
                    "a2a": a2a_agents[0] if len(a2a_agents) == 1 else a2a_agents[0],
                })

        elif tool_type == "image_generation":
            definitions.append({"type": "image_generation"})

    return definitions


def build_tools(config: dict) -> dict:
    """Build tool definitions for all agents from config."""
    agents = config.get("agents", [])
    connection_ids = config.get("connectionIds", {})
    vector_stores = config.get("vectorStores", {})
    agents_manifest = config.get("agentsManifest", [])
    project_endpoint = config.get("projectEndpoint", "")

    result = {}
    for agent in agents:
        agent_name = agent.get("name", "")
        agent_tools = agent.get("tools", [])
        if not agent_tools:
            continue

        vs_ids = []
        if agent_name in vector_stores:
            vs_id = vector_stores[agent_name]
            vs_ids = [vs_id] if isinstance(vs_id, str) else vs_id

        definitions = build_tool_definitions(
            agent_tools=agent_tools,
            vector_store_ids=vs_ids if vs_ids else None,
            connection_ids=connection_ids,
            agents_manifest=agents_manifest,
            project_endpoint=project_endpoint,
        )
        result[agent_name] = definitions

    return {"toolDefinitions": result}


# ── CLI ──────────────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="Foundry tools and connections")
    parser.add_argument(
        "--action",
        required=True,
        choices=["setup-connections", "build-tools"],
        help="Action to perform",
    )
    parser.add_argument("--config", required=True, help="Path to JSON config file")
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    if args.action == "setup-connections":
        result = setup_connections(config)
    else:
        result = build_tools(config)

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log.error("Fatal error: %s", exc)
        sys.exit(1)
