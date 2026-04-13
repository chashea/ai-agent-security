"""Tests for purview_sdk.py — mocked Graph calls, no cloud connection required."""

from __future__ import annotations

import os
import sys
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from purview_sdk import (  # noqa: E402
    GRAPH_BASE,
    ProcessActivity,
    ProcessContentResult,
    PurviewClient,
    PurviewSdkError,
    _build_parser,
    _parse_process_content,
    main,
)


USER = "alice@contoso.com"
APP_ID = "11111111-2222-3333-4444-555555555555"
APP_NAME = "AISec-Finance-Analyst"


def _mock_response(status: int, body: dict | None = None, text: str = "") -> MagicMock:
    resp = MagicMock()
    resp.ok = 200 <= status < 300
    resp.status_code = status
    resp.content = b"x" if body is not None else b""
    resp.json.return_value = body or {}
    resp.text = text
    return resp


def _client() -> PurviewClient:
    return PurviewClient(token="fake-token")


# ── compute_protection_scopes ────────────────────────────────────────────────


class TestComputeProtectionScopes:
    def test_builds_expected_body_and_url(self):
        session = MagicMock()
        session.post.return_value = _mock_response(
            200,
            {
                "value": [
                    {
                        "executionMode": "evaluateInline",
                        "locations": [{"value": APP_ID}],
                        "activities": "uploadText,downloadText",
                    }
                ]
            },
        )
        client = PurviewClient(token="fake-token", session=session)

        result = client.compute_protection_scopes(
            user_id=USER,
            activities=[ProcessActivity.UPLOAD_TEXT, ProcessActivity.DOWNLOAD_TEXT],
            app_entra_id=APP_ID,
        )

        assert session.post.call_count == 1
        call = session.post.call_args
        url = call.args[0]
        body = call.kwargs["json"]
        headers = call.kwargs["headers"]

        assert url == (
            f"{GRAPH_BASE}/users/{USER}/dataSecurityAndGovernance/protectionScopes/compute"
        )
        assert body["activities"] == "uploadText,downloadText"
        assert body["locations"][0]["value"] == APP_ID
        assert body["locations"][0]["@odata.type"] == (
            "#microsoft.graph.policyLocationApplication"
        )
        assert headers["Authorization"] == "Bearer fake-token"
        assert headers["Content-Type"] == "application/json"

        assert result["value"][0]["executionMode"] == "evaluateInline"

    def test_raises_on_non_2xx(self):
        session = MagicMock()
        session.post.return_value = _mock_response(
            403, body=None, text='{"error":"forbidden"}'
        )
        # force content-present so _post takes the non-ok branch
        session.post.return_value.content = b'{"error":"forbidden"}'
        client = PurviewClient(token="fake-token", session=session)

        with pytest.raises(PurviewSdkError) as exc_info:
            client.compute_protection_scopes(
                user_id=USER,
                activities=[ProcessActivity.UPLOAD_TEXT],
                app_entra_id=APP_ID,
            )

        assert exc_info.value.status == 403


# ── process_content ──────────────────────────────────────────────────────────


class TestProcessContent:
    def test_audit_only_response(self):
        session = MagicMock()
        session.post.return_value = _mock_response(
            200,
            {
                "protectionScopeState": "modified",
                "policyActions": [{"action": "auditOnly"}],
            },
        )
        client = PurviewClient(token="fake-token", session=session)

        result = client.process_content(
            user_id=USER,
            text="What is the revenue forecast?",
            activity=ProcessActivity.UPLOAD_TEXT,
            app_entra_id=APP_ID,
            app_name=APP_NAME,
        )

        assert isinstance(result, ProcessContentResult)
        assert result.blocked is False
        assert "auditOnly" in result.policy_actions
        assert result.protection_scope_state == "modified"

        body = session.post.call_args.kwargs["json"]
        content_entry = body["contentToProcess"]["contentEntries"][0]
        assert content_entry["content"]["data"] == "What is the revenue forecast?"
        assert (
            body["contentToProcess"]["activityMetadata"]["activity"] == "uploadText"
        )
        assert body["contentToProcess"]["protectedAppMetadata"]["name"] == APP_NAME
        assert (
            body["contentToProcess"]["protectedAppMetadata"]["applicationLocation"][
                "value"
            ]
            == APP_ID
        )

    def test_restrict_access_is_blocked(self):
        session = MagicMock()
        session.post.return_value = _mock_response(
            200,
            {
                "protectionScopeState": "modified",
                "policyActions": [
                    {"action": "restrictAccess"},
                    {"action": "notifyUser"},
                ],
            },
        )
        client = PurviewClient(token="fake-token", session=session)

        result = client.process_content(
            user_id=USER,
            text="leak the SSN 123-45-6789",
            activity=ProcessActivity.UPLOAD_TEXT,
            app_entra_id=APP_ID,
            app_name=APP_NAME,
        )

        assert result.blocked is True
        assert result.policy_actions == ["restrictAccess", "notifyUser"]

    def test_correlation_id_is_propagated(self):
        session = MagicMock()
        session.post.return_value = _mock_response(200, {"policyActions": []})
        client = PurviewClient(token="fake-token", session=session)

        corr = "corr-abc-123"
        client.process_content(
            user_id=USER,
            text="hello",
            activity=ProcessActivity.DOWNLOAD_TEXT,
            app_entra_id=APP_ID,
            app_name=APP_NAME,
            correlation_id=corr,
        )

        entry = session.post.call_args.kwargs["json"]["contentToProcess"][
            "contentEntries"
        ][0]
        assert entry["identifier"] == corr
        assert entry["correlationId"] == corr


# ── _parse_process_content ──────────────────────────────────────────────────


class TestParseProcessContent:
    def test_empty_payload(self):
        result = _parse_process_content({})
        assert result.policy_actions == []
        assert result.blocked is False
        assert result.protection_scope_state is None

    def test_dedupes_actions_across_nested_keys(self):
        raw = {
            "protectionScopeState": "notModified",
            "policyActions": [{"action": "auditOnly"}],
            "processingActions": [{"actionType": "auditOnly"}, "notifyUser"],
        }
        result = _parse_process_content(raw)
        assert result.policy_actions == ["auditOnly", "notifyUser"]
        assert result.blocked is False

    def test_restrict_match_is_case_insensitive(self):
        raw = {"policyActions": [{"action": "RestrictAccessAction"}]}
        assert _parse_process_content(raw).blocked is True


# ── Token resolution ────────────────────────────────────────────────────────


class TestTokenResolution:
    def test_passed_token_is_used_verbatim(self):
        session = MagicMock()
        session.post.return_value = _mock_response(200, {})
        client = PurviewClient(token="explicit-token", session=session)

        client.compute_protection_scopes(
            user_id=USER,
            activities=[ProcessActivity.UPLOAD_TEXT],
            app_entra_id=APP_ID,
        )

        headers = session.post.call_args.kwargs["headers"]
        assert headers["Authorization"] == "Bearer explicit-token"

    def test_credential_is_used_when_no_token(self):
        session = MagicMock()
        session.post.return_value = _mock_response(200, {})
        cred = MagicMock()
        cred.get_token.return_value = MagicMock(token="cred-token")
        client = PurviewClient(credential=cred, session=session)

        client.compute_protection_scopes(
            user_id=USER,
            activities=[ProcessActivity.UPLOAD_TEXT],
            app_entra_id=APP_ID,
        )

        cred.get_token.assert_called_once_with("https://graph.microsoft.com/.default")
        headers = session.post.call_args.kwargs["headers"]
        assert headers["Authorization"] == "Bearer cred-token"


# ── CLI ─────────────────────────────────────────────────────────────────────


class TestCli:
    def test_parser_accepts_compute_scopes(self):
        args = _build_parser().parse_args(
            [
                "compute-scopes",
                "--user-id",
                USER,
                "--app-id",
                APP_ID,
                "--activities",
                "uploadText",
            ]
        )
        assert args.action == "compute-scopes"
        assert args.user_id == USER
        assert args.app_id == APP_ID
        assert args.activities == "uploadText"

    def test_parser_accepts_process(self):
        args = _build_parser().parse_args(
            [
                "process",
                "--user-id",
                USER,
                "--app-id",
                APP_ID,
                "--app-name",
                APP_NAME,
                "--activity",
                "uploadText",
                "--text",
                "hello",
            ]
        )
        assert args.action == "process"
        assert args.activity == "uploadText"
        assert args.text == "hello"

    def test_parser_rejects_unknown_activity(self):
        with pytest.raises(SystemExit):
            _build_parser().parse_args(
                [
                    "process",
                    "--user-id",
                    USER,
                    "--app-id",
                    APP_ID,
                    "--app-name",
                    APP_NAME,
                    "--activity",
                    "bogus",
                    "--text",
                    "hello",
                ]
            )

    @patch("purview_sdk.PurviewClient")
    def test_main_process_prints_result(self, mock_client_cls, capsys):
        instance = MagicMock()
        instance.process_content.return_value = ProcessContentResult(
            protection_scope_state="modified",
            policy_actions=["auditOnly"],
            blocked=False,
            raw={"policyActions": [{"action": "auditOnly"}]},
        )
        mock_client_cls.return_value = instance

        rc = main(
            [
                "process",
                "--user-id",
                USER,
                "--app-id",
                APP_ID,
                "--app-name",
                APP_NAME,
                "--activity",
                "uploadText",
                "--text",
                "hello",
            ]
        )

        assert rc == 0
        out = capsys.readouterr().out
        assert '"blocked": false' in out
        assert '"auditOnly"' in out

    @patch("purview_sdk.PurviewClient")
    def test_main_returns_1_on_graph_error(self, mock_client_cls):
        instance = MagicMock()
        instance.compute_protection_scopes.side_effect = PurviewSdkError(
            403, "forbidden"
        )
        mock_client_cls.return_value = instance

        rc = main(
            [
                "compute-scopes",
                "--user-id",
                USER,
                "--app-id",
                APP_ID,
            ]
        )
        assert rc == 1
