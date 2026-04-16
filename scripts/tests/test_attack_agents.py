"""Tests for the adversarial attack harness.

Network calls are never made — we stub the HTTP layer via a fake session and
exercise the pure-Python paths (catalog, filters, classifier, summariser,
runner orchestration, CLI list/dry-run).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts import attack_agents as aa
from scripts.attack_prompts import ALL_ATTACKS, CATEGORIES, select


# ---------------------------------------------------------------------------
# Catalog integrity
# ---------------------------------------------------------------------------


class TestCatalog:
    def test_has_all_expected_categories(self) -> None:
        expected = {
            "prompt_injection",
            "jailbreak",
            "indirect_injection",
            "sensitive_data_exfil",
            "pii_harvest",
            "harmful_content",
            "protected_material",
            "credential_fishing",
            "groundedness_violation",
        }
        assert expected.issubset(set(CATEGORIES))

    def test_ids_unique(self) -> None:
        ids = [a.id for a in ALL_ATTACKS]
        assert len(ids) == len(set(ids)), "duplicate attack ids"

    def test_all_fields_populated(self) -> None:
        for a in ALL_ATTACKS:
            assert a.id and a.category and a.prompt and a.expected_detection
            assert a.severity in {"low", "medium", "high", "critical"}
            assert isinstance(a.prompt, str) and len(a.prompt) > 10

    def test_catalog_is_non_trivial(self) -> None:
        # If someone strips the library down we want a loud signal.
        assert len(ALL_ATTACKS) >= 20
        assert len(CATEGORIES) >= 8

    def test_select_by_category(self) -> None:
        picked = select(categories=["jailbreak"])
        assert picked
        assert all(a.category == "jailbreak" for a in picked)

    def test_select_by_severity(self) -> None:
        picked = select(severities=["critical"])
        assert picked
        assert all(a.severity == "critical" for a in picked)

    def test_select_by_ids(self) -> None:
        picked = select(ids=["pi-001-classic-ignore", "jb-001-dan"])
        assert {a.id for a in picked} == {"pi-001-classic-ignore", "jb-001-dan"}

    def test_select_and_semantics(self) -> None:
        picked = select(categories=["credential_fishing"], severities=["critical"])
        assert picked
        assert all(a.category == "credential_fishing" and a.severity == "critical" for a in picked)

    def test_select_no_matches(self) -> None:
        assert select(ids=["does-not-exist"]) == []


# ---------------------------------------------------------------------------
# classify_response
# ---------------------------------------------------------------------------


class TestClassify:
    def test_200_is_ok(self) -> None:
        assert aa.classify_response(200, "anything") == aa.OUTCOME_OK

    def test_network_error(self) -> None:
        assert aa.classify_response(0, "retries exhausted") == aa.OUTCOME_NETWORK

    def test_content_filter_block(self) -> None:
        body = json.dumps({"error": {"code": "content_filter", "message": "blocked"}})
        assert aa.classify_response(400, body) == aa.OUTCOME_BLOCKED_CONTENT

    def test_jailbreak_block(self) -> None:
        body = json.dumps({"error": {"code": "jailbreak", "message": "Jailbreak attempt detected"}})
        assert aa.classify_response(400, body) == aa.OUTCOME_BLOCKED_JAILBREAK

    def test_prompt_shield_direct(self) -> None:
        body = json.dumps({"error": {"innererror": {"code": "prompt_shield"}}})
        assert aa.classify_response(400, body) == aa.OUTCOME_BLOCKED_PROMPT_SHIELD

    def test_prompt_shield_indirect(self) -> None:
        body = json.dumps({"error": {"code": "IndirectAttack"}})
        assert aa.classify_response(400, body) == aa.OUTCOME_BLOCKED_PROMPT_SHIELD

    def test_other_400(self) -> None:
        assert aa.classify_response(400, "{}") == aa.OUTCOME_BLOCKED_OTHER

    def test_auth_error(self) -> None:
        assert aa.classify_response(401, "nope") == aa.OUTCOME_ERROR

    def test_5xx_error(self) -> None:
        assert aa.classify_response(503, "svc unavailable") == aa.OUTCOME_ERROR


# ---------------------------------------------------------------------------
# Runner + summarise
# ---------------------------------------------------------------------------


class FakeResp:
    def __init__(self, status: int, body: dict | str):
        self.status_code = status
        self._body = body

    def json(self):
        if isinstance(self._body, dict):
            return self._body
        raise ValueError("not json")

    @property
    def text(self) -> str:
        return self._body if isinstance(self._body, str) else json.dumps(self._body)


class FakeSession:
    def __init__(self, responses: list[FakeResp]):
        self._responses = list(responses)
        self.calls: list[dict] = []

    def post(self, url, json=None, headers=None, timeout=None):  # noqa: A002
        self.calls.append({"url": url, "json": json, "headers": headers, "timeout": timeout})
        if not self._responses:
            return FakeResp(200, {"choices": [{"message": {"content": "fallback"}}]})
        return self._responses.pop(0)


def _agents() -> list[dict]:
    return [{"name": "AISec-HR"}, {"name": "AISec-Finance"}]


def test_run_attacks_dry_run(monkeypatch: pytest.MonkeyPatch) -> None:
    picked = select(ids=["pi-001-classic-ignore", "jb-001-dan"])
    results = aa.run_attacks(
        agents=_agents(),
        attacks=picked,
        config_agents={},
        base_url="https://example.invalid",
        model_deployment="gpt-4o-mini",
        token="",
        end_user_id="u1",
        dry_run=True,
        sleep_between=0,
    )
    assert len(results) == 4  # 2 attacks * 2 agents
    assert {r.outcome for r in results} == {aa.OUTCOME_DRY_RUN}
    assert {r.agent for r in results} == {"HR", "Finance"}


def test_run_attacks_agent_filter_short_name() -> None:
    picked = select(ids=["pi-001-classic-ignore"])
    results = aa.run_attacks(
        agents=_agents(),
        attacks=picked,
        config_agents={},
        base_url="https://example.invalid",
        model_deployment="gpt-4o-mini",
        token="",
        end_user_id="u1",
        dry_run=True,
        agent_filter=["HR"],
        sleep_between=0,
    )
    assert [r.agent for r in results] == ["HR"]


def test_run_attacks_agent_filter_full_name() -> None:
    picked = select(ids=["pi-001-classic-ignore"])
    results = aa.run_attacks(
        agents=_agents(),
        attacks=picked,
        config_agents={},
        base_url="https://example.invalid",
        model_deployment="gpt-4o-mini",
        token="",
        end_user_id="u1",
        dry_run=True,
        agent_filter=["AISec-Finance"],
        sleep_between=0,
    )
    assert [r.agent for r in results] == ["Finance"]


def test_run_attacks_uses_session_and_classifies() -> None:
    picked = select(ids=["pi-001-classic-ignore", "pii-001-ssn"])
    # HR agent → 1st attack content-filtered, 2nd ok.
    # Finance → 1st jailbreak block, 2nd ok.
    session = FakeSession([
        FakeResp(400, {"error": {"code": "content_filter"}}),
        FakeResp(200, {"choices": [{"message": {"content": "noted"}}]}),
        FakeResp(400, {"error": {"code": "jailbreak"}}),
        FakeResp(200, {"choices": [{"message": {"content": "ok"}}]}),
    ])
    results = aa.run_attacks(
        agents=_agents(),
        attacks=picked,
        config_agents={"AISec-HR": {"instructions": "You are HR."}},
        base_url="https://x.example",
        model_deployment="gpt-4o-mini",
        token="tok",
        end_user_id="u1",
        sleep_between=0,
        session=session,
    )
    assert [r.outcome for r in results] == [
        aa.OUTCOME_BLOCKED_CONTENT,
        aa.OUTCOME_OK,
        aa.OUTCOME_BLOCKED_JAILBREAK,
        aa.OUTCOME_OK,
    ]
    # user_security_context is attached to every call.
    for call in session.calls:
        usc = call["json"]["user_security_context"]
        assert usc["endUserId"] == "u1"
        assert usc["applicationName"].startswith("AISec-")


def test_summarise_counts() -> None:
    results = [
        aa.AttackResult("HR", "a1", "jailbreak", "high", "x", 400, aa.OUTCOME_BLOCKED_JAILBREAK, "..."),
        aa.AttackResult("HR", "a2", "pii_harvest", "medium", "x", 200, aa.OUTCOME_OK, "..."),
        aa.AttackResult("Finance", "a1", "jailbreak", "high", "x", 200, aa.OUTCOME_OK, "..."),
    ]
    s = aa.summarise(results)
    assert s["total"] == 3
    assert s["byOutcome"][aa.OUTCOME_OK] == 2
    assert s["byOutcome"][aa.OUTCOME_BLOCKED_JAILBREAK] == 1
    assert s["byCategory"]["jailbreak"]["blocked"] == 1
    assert s["byAgent"]["HR"]["total"] == 2


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def test_aoai_host_strips_path() -> None:
    manifest = {
        "data": {
            "foundry": {
                "projectEndpoint": "https://acct.services.ai.azure.com/api/projects/Proj"
            }
        }
    }
    assert aa.aoai_host(manifest) == "https://acct.services.ai.azure.com"


def test_latest_manifest_picks_newest(tmp_path: Path) -> None:
    (tmp_path / "AISec_20200101.json").write_text("{}")
    (tmp_path / "AISec_20260101.json").write_text("{}")
    (tmp_path / "ignored.json").write_text("{}")
    assert aa.latest_manifest(tmp_path).name == "AISec_20260101.json"


def test_latest_manifest_raises_when_empty(tmp_path: Path) -> None:
    with pytest.raises(SystemExit):
        aa.latest_manifest(tmp_path)


def test_load_agents_from_config_missing(tmp_path: Path) -> None:
    # REPO_ROOT-based lookup — pass a bogus root.
    assert aa.load_agents_from_config(tmp_path) == {}


def test_load_agents_from_config_parses(tmp_path: Path) -> None:
    (tmp_path / "config.json").write_text(json.dumps({
        "workloads": {"foundry": {"agents": [
            {"name": "AISec-HR", "instructions": "You are HR."},
            {"name": "AISec-Finance", "instructions": "You are Finance."},
        ]}}
    }))
    out = aa.load_agents_from_config(tmp_path)
    assert set(out.keys()) == {"AISec-HR", "AISec-Finance"}
    assert out["AISec-HR"]["instructions"] == "You are HR."


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def test_cli_list_prints_catalog(capsys: pytest.CaptureFixture[str]) -> None:
    rc = aa.main(["--list"])
    assert rc == 0
    out = capsys.readouterr().out
    assert "pi-001-classic-ignore" in out
    assert "jb-001-dan" in out


def test_cli_filters_select_nothing(capsys: pytest.CaptureFixture[str]) -> None:
    rc = aa.main(["--attack-id", "no-such-attack"])
    assert rc == 2


def test_cli_dry_run_writes_output(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    # Point manifest dir + repo root at a temp location so we don't touch
    # real files.
    manifest = tmp_path / "AISec_20260101.json"
    manifest.write_text(json.dumps({
        "data": {"foundry": {
            "projectEndpoint": "https://acct.services.ai.azure.com/api/projects/Proj",
            "modelDeploymentName": "gpt-4o-mini",
            "agents": [{"name": "AISec-HR"}],
        }}
    }))
    (tmp_path / "config.json").write_text(json.dumps({
        "workloads": {"foundry": {"agents": [{"name": "AISec-HR", "instructions": "hr"}]}}
    }))
    monkeypatch.setattr(aa, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(aa, "MANIFEST_DIR", tmp_path)
    out_path = tmp_path / "report.json"
    rc = aa.main([
        "--manifest", str(manifest),
        "--dry-run",
        "--attack-id", "pi-001-classic-ignore",
        "--output", str(out_path),
    ])
    assert rc == 0
    report = json.loads(out_path.read_text())
    assert report["summary"]["total"] == 1
    assert report["results"][0]["outcome"] == aa.OUTCOME_DRY_RUN
    assert report["results"][0]["agent"] == "HR"
