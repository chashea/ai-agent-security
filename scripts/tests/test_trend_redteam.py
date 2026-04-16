"""Tests for scripts/trend_redteam.py."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from scripts import trend_redteam as tr


def _manifest(foundry: dict) -> dict:
    return {"generatedAt": "2026-04-16T00:00:00Z", "data": {"foundry": foundry}}


def _write(tmp_path: Path, name: str, foundry: dict) -> Path:
    path = tmp_path / name
    path.write_text(json.dumps(_manifest(foundry)))
    return path


class TestExtractAsr:
    def test_flat_attack_success_rate(self):
        assert tr._extract_asr({"attack_success_rate": 0.12}) == pytest.approx(0.12)

    def test_percentage_normalized(self):
        assert tr._extract_asr({"attack_success_rate": 12.0}) == pytest.approx(0.12)

    def test_camel_case_key(self):
        assert tr._extract_asr({"overall": {"attackSuccessRate": 0.05}}) == pytest.approx(0.05)

    def test_asr_alias(self):
        assert tr._extract_asr({"summary": [{"asr": 0.3}]}) == pytest.approx(0.3)

    def test_none(self):
        assert tr._extract_asr(None) is None
        assert tr._extract_asr({"unrelated": 1}) is None


class TestFlattenMetrics:
    def test_nested(self):
        flat = tr._flatten_metrics({"quality": {"groundedness": 4.2}, "safety": {"violence": 0.1}})
        assert flat == {"quality.groundedness": 4.2, "safety.violence": 0.1}

    def test_ignores_bool_and_strings(self):
        flat = tr._flatten_metrics({"flag": True, "note": "x", "score": 0.9})
        assert flat == {"score": 0.9}

    def test_empty(self):
        assert tr._flatten_metrics({}) == {}
        assert tr._flatten_metrics(None) == {}


class TestExtractAgentAsr:
    def test_happy_path(self):
        foundry = {
            "redTeaming": {
                "agentScans": [
                    {"agentName": "A", "scorecard": {"attack_success_rate": 0.2}},
                    {"agentName": "B", "scorecard": {"overall": {"asr": 0.4}}},
                ]
            }
        }
        assert tr._extract_agent_asr(foundry) == {"A": 0.2, "B": 0.4}

    def test_missing_section(self):
        assert tr._extract_agent_asr({}) == {}
        assert tr._extract_agent_asr({"redTeaming": {}}) == {}

    def test_malformed_scans(self):
        foundry = {"redTeaming": {"agentScans": [{"scorecard": {"asr": 0.1}}]}}
        # no agent name → skipped
        assert tr._extract_agent_asr(foundry) == {}


class TestExtractAgentMetrics:
    def test_happy_path(self):
        foundry = {
            "evaluations": {
                "batchEvaluations": [
                    {"agentName": "A", "metrics": {"quality": {"groundedness": 4.1}}},
                    {"agentName": "B", "metrics": {"safety": {"violence": 0.0}}},
                ]
            }
        }
        result = tr._extract_agent_metrics(foundry)
        assert result == {
            "A": {"quality.groundedness": 4.1},
            "B": {"safety.violence": 0.0},
        }

    def test_missing(self):
        assert tr._extract_agent_metrics({}) == {}


class TestCompare:
    def test_asr_regression_detected(self):
        baseline = {"foundry": {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.10}}
        ]}}}
        current = {"foundry": {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.20}}
        ]}}}
        report = tr.compare(baseline, current, "base.json", "cur.json")
        assert len(report.regressions) == 1
        assert report.regressions[0].metric == "attack_success_rate"
        assert report.regressions[0].delta == pytest.approx(0.10)

    def test_asr_improvement_not_regression(self):
        baseline = {"foundry": {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.30}}
        ]}}}
        current = {"foundry": {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.10}}
        ]}}}
        report = tr.compare(baseline, current, "base.json", "cur.json")
        assert report.regressions == []
        assert len(report.asr_changes) == 1

    def test_metric_drop_regression(self):
        baseline = {"foundry": {"evaluations": {"batchEvaluations": [
            {"agentName": "A", "metrics": {"quality": {"groundedness": 4.5}}}
        ]}}}
        current = {"foundry": {"evaluations": {"batchEvaluations": [
            {"agentName": "A", "metrics": {"quality": {"groundedness": 4.0}}}
        ]}}}
        # default metric_threshold is 0.05 → a drop of 0.5 regresses
        report = tr.compare(baseline, current, "b", "c")
        assert len(report.regressions) == 1
        assert report.regressions[0].kind == "metric"
        assert report.regressions[0].delta == pytest.approx(-0.5)

    def test_metric_within_threshold(self):
        baseline = {"foundry": {"evaluations": {"batchEvaluations": [
            {"agentName": "A", "metrics": {"quality": {"groundedness": 4.50}}}
        ]}}}
        current = {"foundry": {"evaluations": {"batchEvaluations": [
            {"agentName": "A", "metrics": {"quality": {"groundedness": 4.48}}}
        ]}}}
        report = tr.compare(baseline, current, "b", "c", metric_threshold=0.05)
        assert report.regressions == []

    def test_missing_baseline_flagged(self):
        report = tr.compare(None, {"foundry": {}}, "(none)", "c")
        assert report.missing_baseline
        assert any("No baseline" in n for n in report.notes)

    def test_no_data_note(self):
        report = tr.compare({"foundry": {}}, {"foundry": {}}, "b", "c")
        assert any("no redteaming" in n.lower() for n in report.notes)

    def test_custom_asr_threshold_allows_small_increase(self):
        baseline = {"foundry": {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.10}}
        ]}}}
        current = {"foundry": {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.12}}
        ]}}}
        report = tr.compare(baseline, current, "b", "c", asr_threshold=0.05)
        assert report.regressions == []

    def test_new_agent_without_baseline(self):
        baseline = {"foundry": {"redTeaming": {"agentScans": []}}}
        current = {"foundry": {"redTeaming": {"agentScans": [
            {"agentName": "New", "scorecard": {"asr": 0.10}}
        ]}}}
        report = tr.compare(baseline, current, "b", "c")
        # Present in current, no baseline → reported but not a regression
        assert len(report.asr_changes) == 1
        assert report.asr_changes[0].baseline is None
        assert report.regressions == []


class TestCli:
    def test_auto_pick_two_most_recent(self, tmp_path: Path, capsys):
        # Older manifest has ASR 0.10; newer has ASR 0.25 → regression
        old = _write(tmp_path, "AISec_20260101-000000.json", {
            "redTeaming": {"agentScans": [
                {"agentName": "A", "scorecard": {"asr": 0.10}}
            ]}
        })
        new = _write(tmp_path, "AISec_20260202-000000.json", {
            "redTeaming": {"agentScans": [
                {"agentName": "A", "scorecard": {"asr": 0.25}}
            ]}
        })
        # Bump mtimes so order is deterministic
        import os
        import time
        os.utime(old, (time.time() - 100, time.time() - 100))
        os.utime(new, (time.time(), time.time()))

        rc = tr.main([
            "--manifest-dir", str(tmp_path),
            "--json",
            "--fail-on-regression",
        ])
        assert rc == 1
        payload = json.loads(capsys.readouterr().out)
        assert payload["currentPath"].endswith(new.name)
        assert payload["baselinePath"].endswith(old.name)
        assert len(payload["regressions"]) == 1

    def test_explicit_paths(self, tmp_path: Path, capsys):
        a = _write(tmp_path, "a.json", {})
        b = _write(tmp_path, "b.json", {
            "evaluations": {"batchEvaluations": [
                {"agentName": "A", "metrics": {"q": {"score": 1.0}}}
            ]}
        })
        rc = tr.main(["--baseline", str(a), "--current", str(b), "--json"])
        assert rc == 0
        payload = json.loads(capsys.readouterr().out)
        assert payload["baselinePath"] == str(a)

    def test_no_manifests(self, tmp_path: Path):
        with pytest.raises(SystemExit):
            tr.main(["--manifest-dir", str(tmp_path)])

    def test_text_output(self, tmp_path: Path, capsys):
        a = _write(tmp_path, "a.json", {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.1}}
        ]}})
        b = _write(tmp_path, "b.json", {"redTeaming": {"agentScans": [
            {"agentName": "A", "scorecard": {"asr": 0.2}}
        ]}})
        rc = tr.main(["--baseline", str(a), "--current", str(b), "--fail-on-regression"])
        out = capsys.readouterr().out
        assert rc == 1
        assert "REGRESSION" in out
        assert "Attack Success Rate" in out
