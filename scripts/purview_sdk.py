#!/usr/bin/env python3
"""Microsoft Purview SDK wrapper for the Graph `dataSecurityAndGovernance` APIs.

This module is a reference library for Foundry agent runtimes that want to
send prompts and responses into Microsoft Purview so that DLP, Insider Risk,
Communication Compliance, eDiscovery, and Audit solutions can see them.

It wraps two Microsoft Graph beta endpoints:

- POST /users/{id}/dataSecurityAndGovernance/protectionScopes/compute
- POST /users/{id}/dataSecurityAndGovernance/processContent

Docs:
- https://learn.microsoft.com/graph/api/userprotectionscopecontainer-compute
- https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent

Integration context: see `docs/foundry-purview-integration.md` §2, §3, §5.2.

A runtime caller (a bot, a Function App, an Agent Framework middleware) is
expected to:
    1. On session start, call `compute_protection_scopes` to discover which
       policies apply to the user × app. Cache the result until `cacheValidUntil`.
    2. On every prompt, call `process_content` with activity="uploadText" BEFORE
       forwarding to the model. If any `policyAction` is `restrictAccess`, block.
    3. On every model response, call `process_content` with activity="downloadText"
       for audit. Responses are captured even if enforcement is audit-only.

This module does NOT run automatically at deploy time. Wiring it into the
request path belongs in the runtime that fronts the Foundry agent baseUrl.

Usage as a library:
    from purview_sdk import PurviewClient, ProcessActivity

    client = PurviewClient()
    scopes = client.compute_protection_scopes(
        user_id="user@contoso.com",
        activities=[ProcessActivity.UPLOAD_TEXT, ProcessActivity.DOWNLOAD_TEXT],
        app_entra_id="11111111-2222-3333-4444-555555555555",
    )
    result = client.process_content(
        user_id="user@contoso.com",
        text="What is the revenue forecast?",
        activity=ProcessActivity.UPLOAD_TEXT,
        app_entra_id="11111111-2222-3333-4444-555555555555",
        app_name="AISec-Finance-Analyst",
    )
    if result.blocked:
        return "Blocked by DLP policy: " + ", ".join(result.policy_actions)

Usage as a CLI (for smoke testing against a real tenant):
    python3.12 purview_sdk.py compute-scopes \\
        --user-id user@contoso.com \\
        --app-id 11111111-2222-3333-4444-555555555555

    python3.12 purview_sdk.py process \\
        --user-id user@contoso.com \\
        --app-id 11111111-2222-3333-4444-555555555555 \\
        --app-name AISec-Finance-Analyst \\
        --activity uploadText \\
        --text "What is the revenue forecast?"
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import logging
import sys
import uuid
from enum import Enum
from typing import Any, Iterable, Optional

import requests
from azure.identity import DefaultAzureCredential

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)


GRAPH_BASE = "https://graph.microsoft.com/beta"
GRAPH_SCOPE = "https://graph.microsoft.com/.default"
DEFAULT_TIMEOUT = 30


class ProcessActivity(str, Enum):
    """Activities accepted by the Graph `processContent` API.

    Foundry prompts use `uploadText`; model responses use `downloadText`.
    """

    UPLOAD_TEXT = "uploadText"
    DOWNLOAD_TEXT = "downloadText"
    UPLOAD_FILE = "uploadFile"
    DOWNLOAD_FILE = "downloadFile"


@dataclasses.dataclass
class ProcessContentResult:
    """Normalized response from `processContent`.

    `blocked` is True when any policy action is `restrictAccess`. Runtime
    callers should short-circuit the model call in that case.
    """

    protection_scope_state: Optional[str]
    policy_actions: list[str]
    blocked: bool
    raw: dict


class PurviewSdkError(RuntimeError):
    """Raised for any non-2xx response from Microsoft Graph."""

    def __init__(self, status: int, body: str):
        super().__init__(f"Graph returned {status}: {body[:500]}")
        self.status = status
        self.body = body


class PurviewClient:
    """Thin wrapper around the Graph `dataSecurityAndGovernance` endpoints.

    Token handling:
        - If `token` is provided, it is used verbatim (runtime callers that
          already hold a user-context bearer token should pass it in).
        - Otherwise a `DefaultAzureCredential` is used to fetch an app-context
          token. Per `docs/foundry-purview-integration.md` §3, app-context
          tokens DO NOT trigger Purview DLP/IRM/CC enforcement — they only
          populate Audit + DSPM activity explorer. Pass a user token to get
          real enforcement.
    """

    def __init__(
        self,
        *,
        token: Optional[str] = None,
        credential: Optional[DefaultAzureCredential] = None,
        session: Optional[requests.Session] = None,
        timeout: int = DEFAULT_TIMEOUT,
    ) -> None:
        self._token = token
        self._credential = credential
        self._session = session or requests.Session()
        self._timeout = timeout

    # ── token ────────────────────────────────────────────────────────────────

    def _auth_header(self) -> dict:
        if self._token:
            return {"Authorization": f"Bearer {self._token}"}
        cred = self._credential or DefaultAzureCredential()
        token = cred.get_token(GRAPH_SCOPE).token
        return {"Authorization": f"Bearer {token}"}

    def _post(self, url: str, body: dict) -> dict:
        headers = {**self._auth_header(), "Content-Type": "application/json"}
        log.debug("POST %s", url)
        resp = self._session.post(
            url, headers=headers, json=body, timeout=self._timeout
        )
        if not resp.ok:
            raise PurviewSdkError(resp.status_code, resp.text)
        if not resp.content:
            return {}
        return resp.json()

    # ── computeProtectionScopes ──────────────────────────────────────────────

    def compute_protection_scopes(
        self,
        *,
        user_id: str,
        activities: Iterable[ProcessActivity],
        app_entra_id: str,
    ) -> dict:
        """Discover which Purview policies apply to user × app × activity.

        Runtime callers should invoke this once per session and cache the
        result until `cacheValidUntil`. The returned `executionMode` tells you
        whether a scope is `evaluateInline` (blocking) or `evaluateOffline`
        (audit-only). If no inline scope applies, you can skip calling
        `process_content` on prompts and just emit audit events.

        Spec: https://learn.microsoft.com/graph/api/userprotectionscopecontainer-compute
        """
        url = f"{GRAPH_BASE}/users/{user_id}/dataSecurityAndGovernance/protectionScopes/compute"
        body = {
            "activities": ",".join(a.value for a in activities),
            "locations": [
                {
                    "@odata.type": "#microsoft.graph.policyLocationApplication",
                    "value": app_entra_id,
                }
            ],
        }
        return self._post(url, body)

    # ── processContent ───────────────────────────────────────────────────────

    def process_content(
        self,
        *,
        user_id: str,
        text: str,
        activity: ProcessActivity,
        app_entra_id: str,
        app_name: str,
        app_version: str = "1.0.0",
        correlation_id: Optional[str] = None,
    ) -> ProcessContentResult:
        """Submit a prompt or response to Purview for enforcement + audit.

        `activity` is `uploadText` for user prompts and `downloadText` for
        model responses. `app_entra_id` is the object ID of the Entra-
        registered application that `New-DlpComplianceRule` scopes target.
        `correlation_id` threads a prompt and its matching response together
        in Activity Explorer — pass the same value on both calls.

        Spec: https://learn.microsoft.com/graph/api/userdatasecurityandgovernance-processcontent
        """
        url = f"{GRAPH_BASE}/users/{user_id}/dataSecurityAndGovernance/processContent"
        identifier = correlation_id or str(uuid.uuid4())
        body = {
            "contentToProcess": {
                "contentEntries": [
                    {
                        "@odata.type": "#microsoft.graph.processContentMetadata",
                        "identifier": identifier,
                        "content": {
                            "@odata.type": "#microsoft.graph.textContent",
                            "data": text,
                        },
                        "name": f"{app_name}-{activity.value}",
                        "correlationId": identifier,
                        "sequenceNumber": 0,
                    }
                ],
                "activityMetadata": {"activity": activity.value},
                "deviceMetadata": {
                    "operatingSystemSpecifications": {
                        "operatingSystemPlatform": "Linux",
                        "operatingSystemVersion": "server",
                    }
                },
                "protectedAppMetadata": {
                    "name": app_name,
                    "version": app_version,
                    "applicationLocation": {
                        "@odata.type": "#microsoft.graph.policyLocationApplication",
                        "value": app_entra_id,
                    },
                },
                "integratedAppMetadata": {
                    "name": app_name,
                    "version": app_version,
                },
            }
        }
        raw = self._post(url, body)
        return _parse_process_content(raw)


def _parse_process_content(raw: dict) -> ProcessContentResult:
    """Extract the fields a runtime caller actually needs.

    Graph `processContent` returns a structure whose exact shape has shifted
    across preview revisions. We tolerate both the flat `policyActions` form
    and the nested `protectionScopeState` + `processingActions` form: pull
    whichever is present, dedupe the action strings, and flag `blocked` when
    any action name contains `restrict`.
    """

    actions: list[str] = []
    for key in ("policyActions", "processingActions"):
        for entry in raw.get(key, []) or []:
            if isinstance(entry, dict):
                action = entry.get("action") or entry.get("actionType")
                if action:
                    actions.append(action)
            elif isinstance(entry, str):
                actions.append(entry)

    deduped = list(dict.fromkeys(actions))
    blocked = any("restrict" in a.lower() for a in deduped)

    return ProcessContentResult(
        protection_scope_state=raw.get("protectionScopeState"),
        policy_actions=deduped,
        blocked=blocked,
        raw=raw,
    )


# ── CLI ──────────────────────────────────────────────────────────────────────


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="purview_sdk",
        description="Smoke-test Microsoft Purview Graph APIs against a tenant.",
    )
    sub = parser.add_subparsers(dest="action", required=True)

    scopes = sub.add_parser(
        "compute-scopes",
        help="Call POST /users/{id}/dataSecurityAndGovernance/protectionScopes/compute",
    )
    scopes.add_argument("--user-id", required=True)
    scopes.add_argument("--app-id", required=True, help="Entra app object ID")
    scopes.add_argument(
        "--activities",
        default="uploadText,downloadText",
        help="Comma-separated activities (default: uploadText,downloadText)",
    )

    proc = sub.add_parser(
        "process",
        help="Call POST /users/{id}/dataSecurityAndGovernance/processContent",
    )
    proc.add_argument("--user-id", required=True)
    proc.add_argument("--app-id", required=True, help="Entra app object ID")
    proc.add_argument("--app-name", required=True)
    proc.add_argument(
        "--activity",
        required=True,
        choices=[a.value for a in ProcessActivity],
    )
    proc.add_argument("--text", required=True)
    proc.add_argument("--correlation-id", default=None)

    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = _build_parser().parse_args(argv)
    client = PurviewClient()
    try:
        if args.action == "compute-scopes":
            activities = [
                ProcessActivity(a.strip())
                for a in args.activities.split(",")
                if a.strip()
            ]
            out: Any = client.compute_protection_scopes(
                user_id=args.user_id,
                activities=activities,
                app_entra_id=args.app_id,
            )
        elif args.action == "process":
            result = client.process_content(
                user_id=args.user_id,
                text=args.text,
                activity=ProcessActivity(args.activity),
                app_entra_id=args.app_id,
                app_name=args.app_name,
                correlation_id=args.correlation_id,
            )
            out = {
                "protectionScopeState": result.protection_scope_state,
                "policyActions": result.policy_actions,
                "blocked": result.blocked,
                "raw": result.raw,
            }
        else:
            raise SystemExit(f"Unknown action: {args.action}")
    except PurviewSdkError as exc:
        log.error("Graph call failed: %s", exc)
        return 1

    print(json.dumps(out, indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
