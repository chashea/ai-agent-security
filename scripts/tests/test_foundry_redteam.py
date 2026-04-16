"""Tests for foundry_redteam.py — mocked API calls, no cloud connection required."""

import sys
import os
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from foundry_redteam import (
    _build_agent_callback,
    _resolve_attack_strategies,
    _resolve_risk_categories,
    run_redteam_pipeline,
    CLOUD_SUPPORTED_REGIONS,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def local_config():
    return {
        "projectEndpoint": "https://test-account.services.ai.azure.com/api/projects/test-project",
        "agentApiVersion": "2025-05-15-preview",
        "subscriptionId": "00000000-0000-0000-0000-000000000000",
        "resourceGroup": "rg-test",
        "projectName": "test-project",
        "modelDeploymentName": "gpt-4o",
        "location": "eastus",
        "agents": [
            {"id": "agent-001", "name": "HR-Helpdesk", "version": "1"},
        ],
        "redTeaming": {
            "enabled": True,
            "mode": "local",
            "riskCategories": ["violence", "hate_unfairness"],
            "numObjectives": 2,
            "attackStrategies": {
                "easy": ["Base64", "Flip"],
            },
        },
    }


@pytest.fixture
def disabled_config():
    return {
        "projectEndpoint": "https://test.services.ai.azure.com/api/projects/p",
        "redTeaming": {"enabled": False},
    }


# ── Risk category resolution ─────────────────────────────────────────────────


def test_resolve_risk_categories():
    mock_rc = MagicMock()
    mock_rc.Violence = "violence_enum"
    mock_rc.HateUnfairness = "hate_enum"
    mock_rc.Sexual = "sexual_enum"

    result = _resolve_risk_categories(["violence", "hate_unfairness", "sexual"], mock_rc)
    assert result == ["violence_enum", "hate_enum", "sexual_enum"]


def test_resolve_risk_categories_unknown():
    mock_rc = MagicMock(spec=[])
    result = _resolve_risk_categories(["nonexistent"], mock_rc)
    assert result == []


# ── Attack strategy resolution ────────────────────────────────────────────────


def test_resolve_attack_strategies():
    mock_as = MagicMock()
    mock_as.Base64 = "base64_strat"
    mock_as.Flip = "flip_strat"

    result = _resolve_attack_strategies({"easy": ["Base64", "Flip"]}, mock_as)
    assert "base64_strat" in result
    assert "flip_strat" in result


def test_resolve_attack_strategies_unknown():
    mock_as = MagicMock(spec=[])
    result = _resolve_attack_strategies({"easy": ["UnknownStrategy"]}, mock_as)
    assert result == []


# ── Agent callback ────────────────────────────────────────────────────────────


class test_build_agent_callback_success:
    """Test that the callback creates thread, sends message, runs, polls, and returns text."""

    def test_callback_returns_text(self):
        mock_responses = [
            # create thread
            MagicMock(status_code=200, json=lambda: {"id": "thread-123"}, raise_for_status=lambda: None),
            # add message
            MagicMock(status_code=200, raise_for_status=lambda: None),
            # create run
            MagicMock(status_code=200, json=lambda: {"id": "run-456"}, raise_for_status=lambda: None),
            # poll run status
            MagicMock(status_code=200, json=lambda: {"status": "completed"}, raise_for_status=lambda: None),
            # get messages
            MagicMock(
                status_code=200,
                json=lambda: {
                    "data": [{"content": [{"type": "text", "text": {"value": "Agent response"}}]}]
                },
                raise_for_status=lambda: None,
            ),
            # delete thread
            MagicMock(status_code=200),
        ]
        with patch("foundry_redteam.requests") as mock_req:
            mock_req.post.side_effect = mock_responses[:3]
            mock_req.get.side_effect = mock_responses[3:5]
            mock_req.delete.return_value = mock_responses[5]

            callback = _build_agent_callback(
                "https://test.ai.azure.com/api/projects/p",
                "fake-token",
                "agent-001",
                "2025-05-15-preview",
            )
            result = callback("Tell me something harmful")
            assert result == "Agent response"


class test_build_agent_callback_error:
    """Test that callback returns error string on failure."""

    def test_callback_handles_exception(self):
        with patch("foundry_redteam.requests") as mock_req:
            mock_req.post.side_effect = Exception("Connection refused")
            mock_req.delete.return_value = MagicMock(status_code=200)

            callback = _build_agent_callback(
                "https://test.ai.azure.com/api/projects/p",
                "fake-token",
                "agent-001",
                "2025-05-15-preview",
            )
            result = callback("test")
            assert "[Error:" in result


# ── Pipeline disabled ─────────────────────────────────────────────────────────


def test_pipeline_disabled(disabled_config):
    result = run_redteam_pipeline(disabled_config, "scan")
    assert result["mode"] == "disabled"
    assert result["agentScans"] == []


# ── Cloud region gating ──────────────────────────────────────────────────────


def test_cloud_supported_regions():
    assert "eastus2" in CLOUD_SUPPORTED_REGIONS
    assert "francecentral" in CLOUD_SUPPORTED_REGIONS
    assert "eastus" not in CLOUD_SUPPORTED_REGIONS


# ── Cloud scan falls back on unsupported region ──────────────────────────────


@patch("foundry_redteam.run_local_scan")
@patch("foundry_redteam.DefaultAzureCredential")
def test_cloud_scan_fallback_on_bad_region(mock_cred, mock_local, local_config):
    local_config["redTeaming"]["mode"] = "cloud"
    local_config["location"] = "eastus"  # not in supported regions
    mock_local.return_value = {"mode": "local", "agentScans": []}

    from foundry_redteam import run_cloud_scan
    result = run_cloud_scan(local_config)
    mock_local.assert_called_once()
    assert result["mode"] == "local"
