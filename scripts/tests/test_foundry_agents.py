"""Tests for foundry_agents.py — mocked API calls, no cloud connection required."""

import json
from unittest.mock import MagicMock, patch

import pytest

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from foundry_agents import (
    create_agent,
    delete_agent,
    deploy,
    enable_purview_governance,
    publish_application,
    remove,
    unpublish_application,
)


# ── Fixtures ─────────────────────────────────────────────────────────────────


@pytest.fixture
def deploy_config():
    return {
        "projectEndpoint": "https://test-account.services.ai.azure.com/api/projects/test-project",
        "accountName": "test-account",
        "projectName": "test-project",
        "subscriptionId": "00000000-0000-0000-0000-000000000000",
        "resourceGroup": "rg-test",
        "prefix": "AISec",
        "agents": [
            {
                "name": "HR-Helpdesk",
                "model": "gpt-4o",
                "instructions": "You are an HR assistant.",
                "description": "HR bot",
            }
        ],
        "agentApiVersion": "2025-05-15-preview",
        "appApiVersion": "2025-10-01-preview",
        "toolDefinitions": {
            "HR-Helpdesk": [
                {"type": "code_interpreter"},
                {"type": "file_search", "vector_store_ids": ["vs-hr-abc123"]},
            ]
        },
    }


@pytest.fixture
def remove_config():
    return {
        "projectEndpoint": "https://test-account.services.ai.azure.com/api/projects/test-project",
        "accountName": "test-account",
        "projectName": "test-project",
        "subscriptionId": "00000000-0000-0000-0000-000000000000",
        "resourceGroup": "rg-test",
        "agents": [
            {"id": "agent-uuid-123", "name": "AISec-HR-Helpdesk"},
        ],
        "agentApiVersion": "2025-05-15-preview",
        "appApiVersion": "2025-10-01-preview",
    }


# ── Purview Governance ───────────────────────────────────────────────────────


class TestEnablePurviewGovernance:
    @patch("foundry_agents.requests.put")
    def test_success(self, mock_put):
        mock_put.return_value = MagicMock(status_code=200)
        result = enable_purview_governance(
            "https://test.ai.azure.com/api/projects/p", "fake-token", "2025-05-15-preview"
        )
        assert result is True
        mock_put.assert_called_once()

    @patch("foundry_agents.requests.put")
    def test_failure_returns_false(self, mock_put):
        mock_put.return_value = MagicMock(status_code=500, text="Internal error")
        result = enable_purview_governance(
            "https://test.ai.azure.com/api/projects/p", "fake-token", "2025-05-15-preview"
        )
        assert result is False


# ── Agent CRUD ───────────────────────────────────────────────────────────────


class TestCreateAgent:
    @patch("foundry_agents.requests.post")
    @patch("foundry_agents.requests.delete")
    @patch("foundry_agents.requests.get")
    def test_agent_already_exists(self, mock_get, mock_delete, mock_post):
        mock_get.return_value = MagicMock(status_code=200)
        mock_delete.return_value = MagicMock(status_code=204)
        mock_post.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"id": "uuid-replaced", "name": "AISec-HR"}),
        )
        result = create_agent(
            "https://endpoint", "token", "v1", "AISec-HR", "gpt-4o", "instructions"
        )
        assert result is not None
        assert result["name"] == "AISec-HR"
        mock_delete.assert_called_once()
        mock_post.assert_called_once()

    @patch("foundry_agents.requests.post")
    @patch("foundry_agents.requests.get")
    def test_agent_created(self, mock_get, mock_post):
        mock_get.return_value = MagicMock(status_code=404)
        mock_post.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"id": "uuid-1", "name": "AISec-HR"}),
        )
        result = create_agent(
            "https://endpoint", "token", "v1", "AISec-HR", "gpt-4o", "instructions"
        )
        assert result["id"] == "uuid-1"

    @patch("foundry_agents.requests.post")
    @patch("foundry_agents.requests.get")
    def test_agent_creation_failure(self, mock_get, mock_post):
        mock_get.return_value = MagicMock(status_code=404)
        mock_post.return_value = MagicMock(status_code=400, text="Bad request")
        result = create_agent(
            "https://endpoint", "token", "v1", "AISec-HR", "gpt-4o", "instructions"
        )
        assert result is None

    @patch("foundry_agents.requests.post")
    @patch("foundry_agents.requests.get")
    def test_agent_created_with_tools(self, mock_get, mock_post):
        mock_get.return_value = MagicMock(status_code=404)
        mock_post.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"id": "uuid-tools", "name": "AISec-HR"}),
        )
        tools = [{"type": "code_interpreter"}, {"type": "file_search"}]
        result = create_agent(
            "https://endpoint", "token", "v1", "AISec-HR", "gpt-4o", "instructions",
            tools=tools,
        )
        assert result is not None
        # Verify tools appear in the POST payload body
        call_kwargs = mock_post.call_args
        posted_body = call_kwargs[1]["json"] if "json" in call_kwargs[1] else call_kwargs[0][1]
        assert posted_body["definition"]["tools"] == tools

    @patch("foundry_agents.requests.post")
    @patch("foundry_agents.requests.get")
    def test_agent_created_without_tools(self, mock_get, mock_post):
        mock_get.return_value = MagicMock(status_code=404)
        mock_post.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"id": "uuid-notools", "name": "AISec-HR"}),
        )
        result = create_agent(
            "https://endpoint", "token", "v1", "AISec-HR", "gpt-4o", "instructions"
        )
        assert result is not None
        call_kwargs = mock_post.call_args
        posted_body = call_kwargs[1]["json"] if "json" in call_kwargs[1] else call_kwargs[0][1]
        assert "tools" not in posted_body["definition"]


class TestDeleteAgent:
    @patch("foundry_agents.requests.delete")
    def test_success(self, mock_delete):
        mock_delete.return_value = MagicMock(status_code=204)
        assert delete_agent("https://endpoint", "token", "v1", "uuid-1", "AISec-HR") is True

    @patch("foundry_agents.requests.delete")
    def test_not_found(self, mock_delete):
        mock_delete.return_value = MagicMock(status_code=404, text="Not found")
        assert delete_agent("https://endpoint", "token", "v1", "uuid-1", "AISec-HR") is False


# ── Application Publishing ───────────────────────────────────────────────────


class TestPublishApplication:
    @patch("foundry_agents.requests.get")
    def test_already_published(self, mock_get):
        mock_get.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"properties": {"baseUrl": "https://base.url"}}),
        )
        result = publish_application(
            "/sub/rg/account", "project", "token", "v1", "AISec-HR"
        )
        assert result == "https://base.url"

    @patch("foundry_agents.requests.put")
    @patch("foundry_agents.requests.get")
    def test_publish_new(self, mock_get, mock_put):
        mock_get.return_value = MagicMock(status_code=404)
        mock_put.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"properties": {"baseUrl": "https://new.url"}}),
        )
        result = publish_application(
            "/sub/rg/account", "project", "token", "v1", "AISec-HR"
        )
        assert result == "https://new.url"


class TestUnpublishApplication:
    @patch("foundry_agents.requests.delete")
    def test_success(self, mock_delete):
        mock_delete.return_value = MagicMock(status_code=204)
        assert unpublish_application(
            "/sub/rg/account", "project", "token", "v1", "AISec-HR"
        ) is True


# ── Full Deploy/Remove ───────────────────────────────────────────────────────


class TestDeploy:
    @patch("foundry_agents.publish_application")
    @patch("foundry_agents.create_agent")
    @patch("foundry_agents.enable_purview_governance")
    @patch("foundry_agents._get_token")
    def test_deploy_flow(self, mock_token, mock_gov, mock_create, mock_publish, deploy_config):
        mock_token.return_value = "fake-token"
        mock_gov.return_value = True
        mock_create.return_value = {"id": "uuid-1", "name": "AISec-HR-Helpdesk", "model": "gpt-4o"}
        mock_publish.return_value = "https://base.url"

        result = deploy(deploy_config)

        assert result["purviewIntegrationEnabled"] is True
        assert len(result["agents"]) == 1
        assert result["agents"][0]["baseUrl"] == "https://base.url"

        # Verify tools were passed through from toolDefinitions to create_agent
        create_call_kwargs = mock_create.call_args[1]
        assert create_call_kwargs["tools"] == deploy_config["toolDefinitions"]["HR-Helpdesk"]
        # toolCount is set on the agent when tools are present
        assert result["agents"][0]["toolCount"] == 2


class TestRemove:
    @patch("foundry_agents.delete_agent")
    @patch("foundry_agents.unpublish_application")
    @patch("foundry_agents._get_token")
    def test_remove_flow(self, mock_token, mock_unpub, mock_delete, remove_config):
        mock_token.return_value = "fake-token"
        mock_unpub.return_value = True
        mock_delete.return_value = True

        result = remove(remove_config)

        assert "AISec-HR-Helpdesk" in result["removedApplications"]
        assert "AISec-HR-Helpdesk" in result["removedAgents"]


# ── JSON Output Contract ────────────────────────────────────────────────────


class TestJsonContract:
    @patch("foundry_agents.publish_application")
    @patch("foundry_agents.create_agent")
    @patch("foundry_agents.enable_purview_governance")
    @patch("foundry_agents._get_token")
    def test_deploy_output_is_valid_json(self, mock_token, mock_gov, mock_create, mock_publish, deploy_config):
        mock_token.return_value = "fake-token"
        mock_gov.return_value = True
        mock_create.return_value = {"id": "uuid-1", "name": "AISec-HR-Helpdesk", "model": "gpt-4o"}
        mock_publish.return_value = "https://base.url"

        result = deploy(deploy_config)
        serialized = json.dumps(result)
        parsed = json.loads(serialized)

        assert "purviewIntegrationEnabled" in parsed
        assert "agents" in parsed
        assert isinstance(parsed["agents"], list)
