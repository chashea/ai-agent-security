"""Tests for demo_traffic.py — mocked HTTP calls, no cloud connection required."""

import json
from unittest.mock import MagicMock, patch

import requests

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from demo_traffic import _chat_completion, _load_agents_from_config


# ── Config Loading ───────────────────────────────────────────────────────────


FAKE_CONFIG = {
    "workloads": {
        "foundry": {
            "agents": [
                {"name": "HR-Helpdesk", "instructions": "You are HR."},
                {"name": "Finance-Bot", "instructions": "You are Finance."},
            ]
        }
    }
}


class TestLoadAgentsFromConfig:
    def test_parses_config_and_returns_agents(self, tmp_path):
        (tmp_path / "config.json").write_text(json.dumps(FAKE_CONFIG))
        with patch("demo_traffic.REPO_ROOT", tmp_path):
            agents = _load_agents_from_config()
        assert set(agents.keys()) == {"HR-Helpdesk", "Finance-Bot"}
        assert agents["HR-Helpdesk"]["instructions"] == "You are HR."

    def test_empty_agents_returns_empty(self, tmp_path):
        (tmp_path / "config.json").write_text(
            json.dumps({"workloads": {"foundry": {"agents": []}}})
        )
        with patch("demo_traffic.REPO_ROOT", tmp_path):
            assert _load_agents_from_config() == {}


# ── Chat Completion / Retry Logic ────────────────────────────────────────────


CALL_KWARGS = dict(
    base_url="https://test.openai.azure.com",
    model_deployment="gpt-4o",
    token="fake-token",
    system="You are a bot.",
    user="Hello",
    end_user_id="user-uuid",
    application_name="AISec-Test",
)


class TestChatCompletion:
    @patch("demo_traffic.time.sleep")
    @patch("demo_traffic.requests.post")
    def test_success_returns_content(self, mock_post, _sleep):
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={
                "choices": [{"message": {"content": "PTO policy is 15 days."}}],
            }),
        )
        status, text = _chat_completion(**CALL_KWARGS)
        assert status == 200
        assert "PTO" in text

    @patch("demo_traffic.time.sleep")
    @patch("demo_traffic.requests.post")
    def test_user_security_context_in_body(self, mock_post, _sleep):
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"choices": [{"message": {"content": "ok"}}]}),
        )
        _chat_completion(**CALL_KWARGS)
        body = mock_post.call_args[1]["json"]
        usc = body["user_security_context"]
        assert usc["endUserId"] == "user-uuid"
        assert usc["applicationName"] == "AISec-Test"

    @patch("demo_traffic.time.sleep")
    @patch("demo_traffic.requests.post")
    def test_retries_on_connection_error_then_succeeds(self, mock_post, _sleep):
        ok_resp = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"choices": [{"message": {"content": "ok"}}]}),
        )
        mock_post.side_effect = [requests.exceptions.ConnectionError("reset"), ok_resp]
        status, text = _chat_completion(**CALL_KWARGS)
        assert status == 200
        assert mock_post.call_count == 2

    @patch("demo_traffic.time.sleep")
    @patch("demo_traffic.requests.post")
    def test_retries_on_timeout_then_succeeds(self, mock_post, _sleep):
        ok_resp = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"choices": [{"message": {"content": "ok"}}]}),
        )
        mock_post.side_effect = [requests.exceptions.Timeout("timed out"), ok_resp]
        status, text = _chat_completion(**CALL_KWARGS)
        assert status == 200

    @patch("demo_traffic.time.sleep")
    @patch("demo_traffic.requests.post")
    def test_gives_up_after_max_retries(self, mock_post, _sleep):
        mock_post.side_effect = requests.exceptions.ConnectionError("down")
        status, text = _chat_completion(**CALL_KWARGS)
        assert status == 0
        assert "retries exhausted" in text
        assert mock_post.call_count == 6  # 6 attempts per the retry loop

    @patch("demo_traffic.time.sleep")
    @patch("demo_traffic.requests.post")
    def test_retries_on_500(self, mock_post, _sleep):
        ok_resp = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"choices": [{"message": {"content": "ok"}}]}),
        )
        mock_post.side_effect = [MagicMock(status_code=503), ok_resp]
        status, _ = _chat_completion(**CALL_KWARGS)
        assert status == 200
        assert mock_post.call_count == 2
