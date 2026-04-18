"""Tests for demo_security_triage.py — mocked Graph + Foundry REST."""

import json
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from demo_security_triage import (  # noqa: E402
    _build_triage_prompt,
    _find_latest_manifest,
    _load_triage_context,
    _rank_alerts,
    run_triage,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def sample_manifest(tmp_path: Path) -> Path:
    manifest = {
        "generatedAt": "2026-04-17T12:00:00Z",
        "data": {
            "foundry": {
                "projectEndpoint": "https://test.services.ai.azure.com/api/projects/p",
                "agents": [
                    {"id": "AISec-HR-Helpdesk", "name": "AISec-HR-Helpdesk"},
                    {"id": "AISec-Security-Triage", "name": "AISec-Security-Triage"},
                ],
            }
        },
    }
    path = tmp_path / "manifests" / "AISec_20260417-120000.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(manifest))
    return path


@pytest.fixture
def sample_alerts() -> list[dict]:
    return [
        {"id": "a1", "severity": "low", "createdDateTime": "2026-04-17T10:00:00Z", "title": "low alert"},
        {"id": "a2", "severity": "high", "createdDateTime": "2026-04-17T11:00:00Z", "title": "high alert newer"},
        {"id": "a3", "severity": "high", "createdDateTime": "2026-04-17T09:00:00Z", "title": "high alert older"},
        {"id": "a4", "severity": "medium", "createdDateTime": "2026-04-17T10:30:00Z", "title": "medium alert"},
    ]


# ── Manifest + context loading ────────────────────────────────────────────────


def test_find_latest_manifest_picks_newest(tmp_path: Path):
    d = tmp_path / "manifests"
    d.mkdir()
    (d / "old.json").write_text("{}")
    newest = d / "new.json"
    newest.write_text("{}")
    # Force distinct mtimes
    os.utime(d / "old.json", (1000, 1000))
    os.utime(newest, (2000, 2000))
    assert _find_latest_manifest(d) == newest


def test_find_latest_manifest_missing(tmp_path: Path):
    assert _find_latest_manifest(tmp_path / "does-not-exist") is None


def test_load_triage_context(sample_manifest: Path):
    ctx = _load_triage_context(sample_manifest, "Security-Triage")
    assert ctx["project_endpoint"] == "https://test.services.ai.azure.com/api/projects/p"
    assert ctx["agent_name"] == "AISec-Security-Triage"
    assert ctx["agent_id"] == "AISec-Security-Triage"


def test_load_triage_context_no_match(sample_manifest: Path):
    with pytest.raises(RuntimeError, match="No agent matching"):
        _load_triage_context(sample_manifest, "Nonexistent-Agent")


# ── Alert ranking ─────────────────────────────────────────────────────────────


def test_rank_alerts_high_severity_first(sample_alerts: list[dict]):
    top3 = _rank_alerts(sample_alerts, top=3)
    # Expect high (newer first), then high (older), then medium
    assert [a["id"] for a in top3] == ["a2", "a3", "a4"]


def test_rank_alerts_respects_top_limit(sample_alerts: list[dict]):
    top2 = _rank_alerts(sample_alerts, top=2)
    assert len(top2) == 2
    assert top2[0]["id"] == "a2"


# ── Prompt building ───────────────────────────────────────────────────────────


def test_build_triage_prompt_includes_alert_fields():
    alert = {
        "id": "alert-xyz",
        "title": "Suspicious inbox forwarding",
        "severity": "high",
        "serviceSource": "microsoftDefenderForOffice365",
    }
    prompt = _build_triage_prompt(alert)
    assert "Triage this Defender XDR alert" in prompt
    assert "alert-xyz" in prompt
    assert "Suspicious inbox forwarding" in prompt
    assert "microsoftDefenderForOffice365" in prompt


# ── run_triage (thread/message/run/poll/messages/delete) ──────────────────────


def test_run_triage_happy_path():
    mock_responses = [
        # POST /threads
        MagicMock(json=lambda: {"id": "thread-1"}, raise_for_status=lambda: None),
        # POST /threads/.../messages
        MagicMock(raise_for_status=lambda: None),
        # POST /threads/.../runs
        MagicMock(json=lambda: {"id": "run-1"}, raise_for_status=lambda: None),
        # GET /threads/.../runs/run-1 -> completed
        MagicMock(json=lambda: {"status": "completed"}, raise_for_status=lambda: None),
        # GET /threads/.../messages -> assistant reply
        MagicMock(
            json=lambda: {
                "data": [
                    {
                        "role": "assistant",
                        "content": [
                            {"type": "text", "text": {"value": "Medium-severity phishing attempt. Recommend isolating mailbox and reviewing audit log."}}
                        ],
                    }
                ]
            },
            raise_for_status=lambda: None,
        ),
    ]
    with patch("demo_security_triage.requests") as mock_req:
        mock_req.post.side_effect = mock_responses[:3]
        mock_req.get.side_effect = mock_responses[3:5]
        mock_req.delete.return_value = MagicMock()

        result = run_triage(
            project_endpoint="https://test.services.ai.azure.com/api/projects/p",
            data_token="fake-token",
            agent_id="AISec-Security-Triage",
            prompt="triage me",
            api_version="2025-05-15-preview",
        )
    assert result["run_status"] == "completed"
    assert "phishing" in result["assistant_response"]
    assert result["error"] is None
    assert result["duration_ms"] >= 0


def test_run_triage_failed_run_status():
    with patch("demo_security_triage.requests") as mock_req:
        mock_req.post.side_effect = [
            MagicMock(json=lambda: {"id": "thread-1"}, raise_for_status=lambda: None),
            MagicMock(raise_for_status=lambda: None),
            MagicMock(json=lambda: {"id": "run-1"}, raise_for_status=lambda: None),
        ]
        mock_req.get.return_value = MagicMock(
            json=lambda: {"status": "failed"}, raise_for_status=lambda: None
        )
        mock_req.delete.return_value = MagicMock()
        result = run_triage(
            project_endpoint="https://test.services.ai.azure.com/api/projects/p",
            data_token="fake-token",
            agent_id="AISec-Security-Triage",
            prompt="triage me",
            api_version="2025-05-15-preview",
            poll_attempts=1,
            poll_interval_s=0,
        )
    assert result["run_status"] == "failed"
    assert result["assistant_response"] == ""
    assert result["error"] is None


def test_run_triage_exception_captured():
    with patch("demo_security_triage.requests") as mock_req:
        mock_req.post.side_effect = Exception("network kaboom")
        mock_req.delete.return_value = MagicMock()
        result = run_triage(
            project_endpoint="https://test.services.ai.azure.com/api/projects/p",
            data_token="fake-token",
            agent_id="AISec-Security-Triage",
            prompt="triage me",
            api_version="2025-05-15-preview",
            poll_attempts=1,
            poll_interval_s=0,
        )
    assert result["run_status"] == "unknown"
    assert result["assistant_response"] == ""
    assert "network kaboom" in (result["error"] or "")
