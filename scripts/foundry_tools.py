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
import time

import requests
from azure.identity import DefaultAzureCredential

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)


def _retry_request(
    method: str,
    url: str,
    max_attempts: int = 10,
    base_delay: float = 3.0,
    **kwargs,
) -> requests.Response:
    """requests.{method} with retry on SSL / timeout / 5xx errors.

    Fresh Foundry control-plane connections can intermittently return
    transport errors during the warmup window. This wrapper retries those
    with exponential backoff; non-retriable 4xx errors raise immediately.
    """
    kwargs.setdefault("timeout", 30)
    method_func = getattr(requests, method.lower())
    last_exc: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            resp = method_func(url, **kwargs)
            if 500 <= resp.status_code < 600 and attempt < max_attempts:
                log.warning(
                    "HTTP %d on %s %s (attempt %d/%d) — retrying",
                    resp.status_code,
                    method,
                    url,
                    attempt,
                    max_attempts,
                )
                time.sleep(base_delay * attempt)
                continue
            return resp
        except (
            requests.exceptions.SSLError,
            requests.exceptions.ConnectionError,
            requests.exceptions.Timeout,
            requests.exceptions.ChunkedEncodingError,
        ) as exc:
            last_exc = exc
            if attempt < max_attempts:
                delay = base_delay * attempt
                log.warning(
                    "Transient transport error on %s %s (attempt %d/%d): %s — "
                    "retrying in %.1fs",
                    method,
                    url,
                    attempt,
                    max_attempts,
                    type(exc).__name__,
                    delay,
                )
                time.sleep(delay)
                continue
            break
    if last_exc is not None:
        raise last_exc
    raise RuntimeError(f"Exhausted {max_attempts} retries on {method} {url}")


def _get_token(credential: DefaultAzureCredential, scope: str) -> str:
    return credential.get_token(scope).token


def _data_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ── Project Connections ──────────────────────────────────────────────────────


def create_connection(
    arm_base: str,
    arm_token: str,
    arm_api_version: str,
    subscription_id: str,
    resource_group: str,
    account_name: str,
    project_name: str,
    connection_name: str,
    connection_type: str,
    target: str,
    credentials: dict | None = None,
    metadata: dict | None = None,
) -> dict | None:
    """Create a project connection via the ARM control plane.

    Foundry project connections live under the ARM resource
    Microsoft.CognitiveServices/accounts/projects/connections — the data-plane
    /connections endpoint returns 405 (Method Not Allowed) on PUT/POST.
    """
    url = (
        f"{arm_base}/subscriptions/{subscription_id}"
        f"/resourceGroups/{resource_group}"
        f"/providers/Microsoft.CognitiveServices/accounts/{account_name}"
        f"/projects/{project_name}/connections/{connection_name}"
        f"?api-version={arm_api_version}"
    )
    headers = _arm_headers(arm_token)

    # Check if exists
    check = _retry_request("GET", url, headers=headers)
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
    if metadata:
        body["properties"]["metadata"] = metadata

    resp = _retry_request("PUT", url, json=body, headers=headers)
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


def _arm_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def setup_connections(config: dict) -> dict:
    """Create all project connections from config. Returns connection IDs."""
    credential = DefaultAzureCredential()
    arm_token = _get_token(credential, "https://management.azure.com/.default")

    arm_base = "https://management.azure.com"
    arm_api_version = config.get("armApiVersion", "2026-01-15-preview")
    subscription_id = config["subscriptionId"]
    resource_group = config["resourceGroup"]
    account_name = config["accountName"]
    project_name = config["projectName"]
    connections_cfg = config.get("connections", {})
    prefix = config.get("prefix", "AISec")
    result = {}

    def _create(name: str, category: str, target: str) -> dict | None:
        return create_connection(
            arm_base=arm_base,
            arm_token=arm_token,
            arm_api_version=arm_api_version,
            subscription_id=subscription_id,
            resource_group=resource_group,
            account_name=account_name,
            project_name=project_name,
            connection_name=name,
            connection_type=category,
            target=target,
        )

    # AI Search connection
    if "aiSearch" in connections_cfg:
        ai_search = connections_cfg["aiSearch"]
        conn = _create(f"{prefix}-ai-search", "CognitiveSearch", ai_search.get("endpoint", ""))
        if conn:
            result["aiSearch"] = conn

    # Grounding with Bing Search — requires a pre-provisioned Microsoft.Bing/accounts
    # resource. The legacy Bing Search API is retired (aka.ms/BingAPIsRetirement);
    # Foundry's built-in bing_grounding tool consumes the successor service via a
    # project connection of category 'GroundingWithBingSearch'. We create the
    # connection here when the caller supplies a resourceId (preferred) or an
    # explicit endpoint/apiKey pair.
    if "bingSearch" in connections_cfg:
        bing = connections_cfg["bingSearch"]
        resource_id = bing.get("resourceId") or bing.get("id")
        bing_endpoint = bing.get("endpoint") or "https://api.bing.microsoft.com/"
        bing_metadata: dict[str, str] = {}
        if resource_id:
            bing_metadata["ResourceId"] = resource_id
        bing_conn_target = resource_id or bing_endpoint

        # GroundingWithBingSearch connections require ApiKey authType (AAD is rejected).
        # Prefer an explicit apiKey from config; otherwise fetch via listKeys on the
        # Microsoft.Bing/accounts resource when we have a resourceId.
        bing_api_key = bing.get("apiKey")
        if not bing_api_key and resource_id:
            keys_url = (
                f"{arm_base}{resource_id}/listKeys?api-version=2020-06-10"
            )
            try:
                keys_resp = _retry_request("POST", keys_url, headers=_arm_headers(arm_token))
                if keys_resp.status_code < 400:
                    keys_json = keys_resp.json()
                    bing_api_key = keys_json.get("key1") or keys_json.get("key2")
                else:
                    log.warning(
                        "Bing listKeys failed (HTTP %d): %s",
                        keys_resp.status_code,
                        keys_resp.text,
                    )
            except Exception as exc:  # noqa: BLE001
                log.warning("Bing listKeys error: %s", exc)

        bing_credentials = {"key": bing_api_key} if bing_api_key else None

        if bing_conn_target:
            conn = create_connection(
                arm_base=arm_base,
                arm_token=arm_token,
                arm_api_version=arm_api_version,
                subscription_id=subscription_id,
                resource_group=resource_group,
                account_name=account_name,
                project_name=project_name,
                connection_name=f"{prefix}-bing-grounding",
                connection_type="GroundingWithBingSearch",
                target=bing_conn_target,
                credentials=bing_credentials,
                metadata=bing_metadata or None,
            )
            if conn:
                result["bingSearch"] = conn
        else:
            log.info(
                "Bing Grounding connection skipped: no resourceId or endpoint "
                "set under workloads.foundry.connections.bingSearch.",
            )

    # Blob Storage connection — requires ContainerName + AccountName metadata,
    # not just the target endpoint.
    if "blobStorage" in connections_cfg:
        blob = connections_cfg["blobStorage"]
        container = blob.get("containerName") or blob.get("container")
        account = blob.get("accountName")
        if not account and blob.get("endpoint"):
            # Derive account name from the endpoint if not provided explicitly:
            # https://<account>.blob.core.windows.net → <account>
            from urllib.parse import urlparse
            host = urlparse(blob["endpoint"]).hostname or ""
            account = host.split(".", 1)[0] if host else ""
        if not container or not account:
            log.warning(
                "Blob Storage connection skipped: containerName and accountName "
                "(or endpoint) are required.",
            )
        else:
            conn = create_connection(
                arm_base=arm_base,
                arm_token=arm_token,
                arm_api_version=arm_api_version,
                subscription_id=subscription_id,
                resource_group=resource_group,
                account_name=account_name,
                project_name=project_name,
                connection_name=f"{prefix}-blob-storage",
                connection_type="AzureBlob",
                target=blob.get("endpoint", ""),
                metadata={
                    "ContainerName": container,
                    "AccountName": account,
                },
            )
            if conn:
                result["blobStorage"] = conn

    # SharePoint connection — required for the sharepoint_grounding tool.
    # Needs a siteUrl like https://<tenant>.sharepoint.com/sites/<site>.
    if "sharePoint" in connections_cfg:
        sp = connections_cfg["sharePoint"]
        site_url = sp.get("siteUrl", "")
        if not site_url:
            log.warning(
                "SharePoint connection skipped: sharePoint.siteUrl is required."
            )
        else:
            conn = _create(f"{prefix}-sharepoint", "SharePoint", site_url)
            if conn:
                result["sharePoint"] = conn

    # Application Insights connection — enables Foundry Tracing in the portal
    # and ships agent-run OTel spans to App Insights / Azure Monitor.
    # Foundry rejects ``authType: AAD`` for AppInsights — must use ApiKey with
    # the full connection string. We auto-derive the connection string from
    # the component via ARM so the caller only needs to set the resourceId.
    if "appInsights" in connections_cfg:
        ai_cfg = connections_cfg["appInsights"]
        ai_resource_id = ai_cfg.get("resourceId")
        ai_conn_string = ai_cfg.get("connectionString")
        if ai_resource_id and not ai_conn_string:
            lookup_url = (
                f"{arm_base}{ai_resource_id}?api-version=2020-02-02"
            )
            lookup_resp = _retry_request(
                "GET", lookup_url, headers=_arm_headers(arm_token)
            )
            if lookup_resp.status_code == 200:
                ai_conn_string = (
                    lookup_resp.json().get("properties", {}).get("ConnectionString")
                )
            else:
                log.warning(
                    "AppInsights resource lookup failed (HTTP %d): %s",
                    lookup_resp.status_code,
                    lookup_resp.text,
                )
        if not ai_resource_id or not ai_conn_string:
            log.warning(
                "AppInsights connection skipped: appInsights.resourceId "
                "(or explicit connectionString) is required."
            )
        else:
            conn = create_connection(
                arm_base=arm_base,
                arm_token=arm_token,
                arm_api_version=arm_api_version,
                subscription_id=subscription_id,
                resource_group=resource_group,
                account_name=account_name,
                project_name=project_name,
                connection_name=f"{prefix}-appinsights",
                connection_type="AppInsights",
                target=ai_resource_id,
                credentials={"key": ai_conn_string},
                metadata={"ApplicationInsightsConnectionString": ai_conn_string},
            )
            if conn:
                result["appInsights"] = conn

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
            # The preview API now REQUIRES vector_store_ids on file_search. If
            # the knowledge base upload failed or was partial, vector_store_ids
            # will be empty — skip the tool entirely rather than produce an
            # invalid payload that fails the whole agent create (and, under
            # our delete-then-create idempotency path, wipes the existing
            # agent).
            if not vector_store_ids:
                log.warning(
                    "file_search tool skipped: no vector_store_ids available "
                    "(upstream knowledge-base upload may have failed)."
                )
                continue
            definitions.append({
                "type": "file_search",
                "vector_store_ids": vector_store_ids,
            })

        elif tool_type == "azure_ai_search":
            conn_id = ""
            if connection_ids and "aiSearch" in connection_ids:
                conn_id = connection_ids["aiSearch"].get("id", "")
            if not conn_id:
                log.warning(
                    "azure_ai_search tool skipped: no AI Search project connection "
                    "available (the Search service may not have provisioned — check "
                    "eastus2 capacity / foundry-eval-infra.bicep output)."
                )
                continue
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
            # The preview API now requires project_connection_id on every
            # search_configurations entry (previously accepted empty/missing).
            # If no Grounding with Bing Search connection is configured on the
            # project we skip the tool rather than emit an invalid payload —
            # creating the agent otherwise fails the whole deploy.
            bing_conn_id = ""
            if connection_ids and "bingSearch" in connection_ids:
                bing_conn_id = connection_ids["bingSearch"].get("id", "")
            if not bing_conn_id:
                log.warning(
                    "bing_grounding tool skipped: no Grounding with Bing Search "
                    "connection configured (set workloads.foundry.connections.bingSearch)."
                )
                continue
            definitions.append({
                "type": "bing_grounding",
                "bing_grounding": {
                    "search_configurations": [{
                        "project_connection_id": bing_conn_id,
                        "market": "en-US",
                        "count": 5,
                    }],
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
            auth_cfg = openapi_cfg.get("auth", {"type": "anonymous"})
            if auth_cfg.get("type") == "managed_identity":
                auth = {
                    "type": "managed_identity",
                    "security_scheme": {
                        "type": auth_cfg.get("securitySchemeType", "oauth2"),
                        "audience": auth_cfg.get("audience", ""),
                    },
                }
            elif auth_cfg.get("type") == "connection":
                auth = {
                    "type": "connection",
                    "security_scheme": {
                        "type": auth_cfg.get("securitySchemeType", "oauth2"),
                    },
                    "connection_id": auth_cfg.get("connectionId", ""),
                }
            else:
                auth = {"type": "anonymous"}
            definitions.append({
                "type": "openapi",
                "openapi": {
                    "name": openapi_cfg.get("name", "api"),
                    "description": openapi_cfg.get("description", ""),
                    "spec": spec_obj,
                    "auth": auth,
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
            # Foundry prompt agents use a flat function schema (not OpenAI Chat
            # Completions style): name/description/parameters at the tool level.
            func_cfg = tool.get("function", tool.get("config", {}))
            definitions.append({
                "type": "function",
                "name": func_cfg.get("name", ""),
                "description": func_cfg.get("description", ""),
                "parameters": func_cfg.get("parameters", {}),
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
            # Nested key must match type (sharepoint_grounding_preview).
            # Prefer an explicit per-tool connectionId, fall back to the shared
            # project SharePoint connection. Skip the tool entirely if neither
            # is available — Foundry surfaces "missing configuration" on the
            # agent when an empty connection_id is passed.
            conn_id = tool.get("connectionId", "")
            if not conn_id and connection_ids and "sharePoint" in connection_ids:
                conn_id = connection_ids["sharePoint"].get("id", "")
            if not conn_id:
                log.warning(
                    "sharepoint_grounding tool skipped: no SharePoint connection "
                    "configured (set workloads.foundry.connections.sharePoint.siteUrl)."
                )
                continue
            definitions.append({
                "type": "sharepoint_grounding_preview",
                "sharepoint_grounding_preview": {
                    "connections": [{"connection_id": conn_id}]
                },
            })

        elif tool_type == "a2a":
            # a2a_preview is a Foundry preview tool. The public API shape is in
            # flux — prior builds rejected the per-peer {name, base_url} shape,
            # the tool-level {base_url}/{project_connection_id} shape, and
            # empty payloads. The safe default is to skip the tool so a
            # single broken payload doesn't abort the whole agent create.
            #
            # Opt-in experimental mode (workloads.foundry.experimentalA2A=true
            # in config → tool["experimental"]=True) emits a best-guess
            # {agents: [{name, base_url}]} payload so schema discovery can
            # keep progressing against live tenants. Failures are isolated
            # to the one agent with a2a; the rest continue.
            if not tool.get("experimental"):
                log.warning(
                    "a2a tool skipped: a2a_preview schema is not stable in the "
                    "current preview API. Set workloads.foundry.experimentalA2A=true "
                    "to opt into schema probing on this deploy."
                )
                continue

            peers = tool.get("peers") or []
            if not peers and agents_manifest:
                # Fall back to wiring every other deployed agent as a peer.
                peers = [
                    {"name": m.get("name"), "base_url": m.get("baseUrl")}
                    for m in agents_manifest
                    if m.get("name") and m.get("baseUrl")
                ]
            if not peers:
                log.warning("a2a experimental skipped: no peers available.")
                continue

            log.warning(
                "a2a EXPERIMENTAL enabled — emitting best-guess payload. "
                "Expect HTTP 400 on current preview; captured for schema discovery."
            )
            definitions.append({
                "type": "a2a_preview",
                "a2a_preview": {
                    "agents": [
                        {"name": p.get("name"), "base_url": p.get("base_url")}
                        for p in peers
                    ],
                },
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
    experimental_a2a = bool(config.get("experimentalA2A"))

    result = {}
    for agent in agents:
        agent_name = agent.get("name", "")
        agent_tools = agent.get("tools", [])
        if not agent_tools:
            continue

        # Propagate the top-level experimentalA2A flag into each a2a tool dict
        # so build_tool_definitions stays a pure function of its inputs.
        if experimental_a2a:
            agent_tools = [
                dict(t, experimental=True) if t.get("type") == "a2a" else t
                for t in agent_tools
            ]

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
