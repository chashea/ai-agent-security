"""Tests for foundry_tools.py — mocked API calls, no cloud connection required."""

import sys
import os
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from foundry_tools import (
    build_tool_definitions,
    build_tools,
    create_connection,
    setup_connections,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def base_config():
    return {
        "projectEndpoint": "https://test-account.services.ai.azure.com/api/projects/test-project",
        "agentApiVersion": "2025-05-15-preview",
        "prefix": "AISec",
        "connections": {
            "aiSearch": {"endpoint": "https://search.search.windows.net"},
            "bingSearch": {},
        },
        "agents": [
            {
                "name": "HR-Helpdesk",
                "tools": [{"type": "code_interpreter"}, {"type": "file_search"}],
            },
            {
                "name": "Compliance",
                "tools": [{"type": "azure_ai_search", "indexName": "compliance-index"}],
            },
        ],
        "connectionIds": {
            "aiSearch": {"id": "conn-ai-search-123"},
            "bingSearch": {"id": "conn-bing-123"},
        },
        "vectorStores": {
            "HR-Helpdesk": "vs-hr-abc123",
        },
    }


# ── Build Tool Definitions ─────────────────────────────────────────────────────


class TestBuildToolDefinitions:
    def test_code_interpreter_tool(self):
        result = build_tool_definitions([{"type": "code_interpreter"}])
        assert result == [{"type": "code_interpreter"}]

    def test_file_search_with_vector_stores(self):
        result = build_tool_definitions(
            [{"type": "file_search"}],
            vector_store_ids=["vs-abc123", "vs-def456"],
        )
        assert len(result) == 1
        assert result[0]["type"] == "file_search"
        assert result[0]["vector_store_ids"] == ["vs-abc123", "vs-def456"]

    def test_file_search_without_vector_stores_is_skipped(self):
        result = build_tool_definitions([{"type": "file_search"}])
        assert result == []

    def test_azure_ai_search_tool(self):
        connection_ids = {"aiSearch": {"id": "conn-search-999"}}
        result = build_tool_definitions(
            [{"type": "azure_ai_search", "indexName": "my-index"}],
            connection_ids=connection_ids,
        )
        assert len(result) == 1
        tool = result[0]
        assert tool["type"] == "azure_ai_search"
        indexes = tool["azure_ai_search"]["indexes"]
        assert len(indexes) == 1
        assert indexes[0]["project_connection_id"] == "conn-search-999"
        assert indexes[0]["index_name"] == "my-index"

    def test_bing_grounding_tool_with_connection(self):
        connection_ids = {"bingSearch": {"id": "conn-bing-777"}}
        result = build_tool_definitions(
            [{"type": "bing_grounding"}],
            connection_ids=connection_ids,
        )
        assert len(result) == 1
        tool = result[0]
        assert tool["type"] == "bing_grounding"
        configs = tool["bing_grounding"]["search_configurations"]
        assert len(configs) == 1
        assert configs[0]["project_connection_id"] == "conn-bing-777"

    def test_bing_grounding_tool_skipped_when_no_connection(self):
        # No project connection — bing_grounding is skipped (API requires
        # project_connection_id; emitting an empty/missing value causes deploy
        # failure). See CLAUDE.md "Bing grounding requires a project connection."
        result = build_tool_definitions([{"type": "bing_grounding"}])
        assert result == []

    def test_function_tool(self):
        func_def = {
            "type": "function",
            "function": {
                "name": "get_policy",
                "description": "Retrieve a compliance policy",
                "parameters": {
                    "type": "object",
                    "properties": {"policy_id": {"type": "string"}},
                    "required": ["policy_id"],
                },
            },
        }
        result = build_tool_definitions([func_def])
        assert len(result) == 1
        tool = result[0]
        # Foundry prompt agents use a flat function schema: name/description/parameters
        # at the tool level, not nested under "function".
        assert tool["type"] == "function"
        assert tool["name"] == "get_policy"
        assert tool["description"] == "Retrieve a compliance policy"
        assert "parameters" in tool

    def test_openapi_tool(self):
        openapi_def = {
            "type": "openapi",
            "config": {
                "name": "compliance-api",
                "description": "Compliance REST API",
                "url": "https://api.example.com",
                "paths": {"/policies": {"get": {}}},
            },
        }
        result = build_tool_definitions([openapi_def])
        assert len(result) == 1
        tool = result[0]
        assert tool["type"] == "openapi"
        spec = tool["openapi"]["spec"]
        assert spec["openapi"] == "3.0.1"
        assert spec["info"]["title"] == "compliance-api"
        assert spec["servers"][0]["url"] == "https://api.example.com"

    def test_image_generation_tool(self):
        result = build_tool_definitions([{"type": "image_generation"}])
        assert result == [{"type": "image_generation"}]

    def test_sharepoint_grounding_with_project_connection(self):
        # Uses the shared project SharePoint connection from connection_ids
        connection_ids = {"sharePoint": {"id": "conn-sp-123"}}
        result = build_tool_definitions(
            [{"type": "sharepoint_grounding"}],
            connection_ids=connection_ids,
        )
        assert len(result) == 1
        tool = result[0]
        assert tool["type"] == "sharepoint_grounding_preview"
        assert tool["sharepoint_grounding_preview"]["connections"][0]["connection_id"] == "conn-sp-123"

    def test_sharepoint_grounding_with_inline_connection(self):
        # Agent-level connectionId takes precedence over the shared one
        result = build_tool_definitions(
            [{"type": "sharepoint_grounding", "connectionId": "conn-inline-999"}],
        )
        assert len(result) == 1
        assert result[0]["sharepoint_grounding_preview"]["connections"][0]["connection_id"] == "conn-inline-999"

    def test_sharepoint_grounding_skipped_when_no_connection(self):
        # No connection configured → tool is skipped, not emitted with empty ID
        result = build_tool_definitions([{"type": "sharepoint_grounding"}])
        assert result == []

    def test_mcp_tool(self):
        mcp_def = {
            "type": "mcp",
            "config": {
                "serverLabel": "my-mcp-server",
                "serverUrl": "https://mcp.example.com",
                "requireApproval": "never",
            },
        }
        result = build_tool_definitions([mcp_def])
        assert len(result) == 1
        tool = result[0]
        assert tool["type"] == "mcp"
        assert tool["server_label"] == "my-mcp-server"
        assert tool["server_url"] == "https://mcp.example.com"

    def test_empty_tools_list(self):
        result = build_tool_definitions([])
        assert result == []


# ── Setup Connections ─────────────────────────────────────────────────────────


class TestSetupConnections:
    @staticmethod
    def _base_config():
        return {
            "subscriptionId": "00000000-0000-0000-0000-000000000000",
            "resourceGroup": "rg-test",
            "accountName": "test-account",
            "projectName": "test-project",
            "armApiVersion": "2026-01-15-preview",
            "prefix": "AISec",
            "connections": {
                "aiSearch": {"endpoint": "https://search.search.windows.net"},
            },
        }

    @patch("foundry_tools.DefaultAzureCredential")
    @patch("foundry_tools.requests.put")
    @patch("foundry_tools.requests.get")
    def test_creates_ai_search_connection(self, mock_get, mock_put, mock_cred):
        mock_cred.return_value.get_token.return_value = MagicMock(token="fake-token")
        mock_get.return_value = MagicMock(status_code=404)
        mock_put.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"id": "conn-new-123"}),
        )

        result = setup_connections(self._base_config())
        assert "aiSearch" in result["connections"]
        assert result["connections"]["aiSearch"]["id"] == "conn-new-123"
        mock_put.assert_called_once()

    @patch("foundry_tools.DefaultAzureCredential")
    @patch("foundry_tools.requests.get")
    def test_connection_already_exists(self, mock_get, mock_cred):
        mock_cred.return_value.get_token.return_value = MagicMock(token="fake-token")
        mock_get.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"id": "existing-conn-id"}),
        )

        result = setup_connections(self._base_config())
        assert result["connections"]["aiSearch"]["id"] == "existing-conn-id"

    @patch("foundry_tools.requests.put")
    @patch("foundry_tools.requests.get")
    def test_connection_failure_returns_none(self, mock_get, mock_put):
        mock_get.return_value = MagicMock(status_code=404)
        mock_put.return_value = MagicMock(status_code=400, text="Bad request")

        result = create_connection(
            arm_base="https://management.azure.com",
            arm_token="fake-token",
            arm_api_version="2026-01-15-preview",
            subscription_id="00000000-0000-0000-0000-000000000000",
            resource_group="rg-test",
            account_name="test-account",
            project_name="test-project",
            connection_name="AISec-ai-search",
            connection_type="CognitiveSearch",
            target="https://search.search.windows.net",
        )
        assert result is None


# ── Build Tools ────────────────────────────────────────────────────────────────


class TestBuildTools:
    def test_builds_tools_for_multiple_agents(self, base_config):
        result = build_tools(base_config)
        tool_defs = result["toolDefinitions"]

        assert "HR-Helpdesk" in tool_defs
        assert "Compliance" in tool_defs

        hr_tools = tool_defs["HR-Helpdesk"]
        types = [t["type"] for t in hr_tools]
        assert "code_interpreter" in types
        assert "file_search" in types

        # file_search should have the vector store ID injected from config
        fs_tool = next(t for t in hr_tools if t["type"] == "file_search")
        assert fs_tool.get("vector_store_ids") == ["vs-hr-abc123"]

        compliance_tools = tool_defs["Compliance"]
        assert compliance_tools[0]["type"] == "azure_ai_search"

    def test_agents_without_tools_excluded(self):
        config = {
            "projectEndpoint": "https://endpoint",
            "agents": [
                {"name": "NoTools"},
                {"name": "WithTools", "tools": [{"type": "code_interpreter"}]},
            ],
        }
        result = build_tools(config)
        assert "NoTools" not in result["toolDefinitions"]
        assert "WithTools" in result["toolDefinitions"]


class TestA2aTool:
    """a2a_preview: requires an Agent2Agent project connection (category Agent2Agent)."""

    def test_a2a_emits_project_connection_id_when_connection_available(self):
        defs = build_tool_definitions(
            agent_tools=[{"type": "a2a"}],
            connection_ids={"a2a": {"id": "/subscriptions/sub/.../connections/aisec-a2a"}},
        )
        assert len(defs) == 1
        tool = defs[0]
        assert tool["type"] == "a2a_preview"
        assert tool["project_connection_id"] == "/subscriptions/sub/.../connections/aisec-a2a"

    def test_a2a_accepts_explicit_connection_id(self):
        defs = build_tool_definitions(
            agent_tools=[{"type": "a2a", "connectionId": "conn-override"}],
        )
        assert len(defs) == 1
        assert defs[0]["project_connection_id"] == "conn-override"

    def test_a2a_skipped_when_no_connection(self, caplog):
        defs = build_tool_definitions(
            agent_tools=[{"type": "a2a"}],
            connection_ids={},
        )
        assert defs == []
        assert any("a2a tool skipped" in r.message for r in caplog.records)

    def test_a2a_propagated_via_build_tools(self):
        config = {
            "projectEndpoint": "https://endpoint",
            "connectionIds": {"a2a": {"id": "conn-1"}},
            "agents": [
                {"name": "A", "tools": [{"type": "a2a"}]},
                {"name": "B", "tools": [{"type": "a2a"}]},
            ],
        }
        result = build_tools(config)
        for agent in ("A", "B"):
            defs = result["toolDefinitions"][agent]
            assert len(defs) == 1
            assert defs[0]["type"] == "a2a_preview"
            assert defs[0]["project_connection_id"] == "conn-1"
