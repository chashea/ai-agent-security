"""Tests for the HTML renderer in scripts/trend_redteam.py."""

from __future__ import annotations

import json
from pathlib import Path

from scripts import trend_redteam as tr


def _manifest(foundry: dict) -> dict:
    return {"generatedAt": "2026-04-17T00:00:00Z", "data": {"foundry": foundry}}


def _write(tmp_path: Path, name: str, foundry: dict) -> Path:
    path = tmp_path / name
    path.write_text(json.dumps(_manifest(foundry)))
    return path


def _sample_report(tmp_path: Path) -> tr.TrendReport:
    baseline = _write(
        tmp_path,
        "base.json",
        {
            "redTeaming": {
                "agentScans": [
                    {"agentName": "HR-Helpdesk", "scorecard": {"attack_success_rate": 0.20}},
                    {"agentName": "Sales-Research", "scorecard": {"attack_success_rate": 0.30}},
                ]
            },
            "evaluations": {
                "batchEvaluations": [
                    {"agentName": "HR-Helpdesk", "metrics": {"quality": {"groundedness": 4.0}}},
                ]
            },
        },
    )
    current = _write(
        tmp_path,
        "cur.json",
        {
            "redTeaming": {
                "agentScans": [
                    # HR-Helpdesk: ASR up → regression
                    {"agentName": "HR-Helpdesk", "scorecard": {"attack_success_rate": 0.35}},
                    # Sales-Research: ASR down → improvement
                    {"agentName": "Sales-Research", "scorecard": {"attack_success_rate": 0.10}},
                ]
            },
            "evaluations": {
                "batchEvaluations": [
                    # HR-Helpdesk groundedness drops → regression
                    {"agentName": "HR-Helpdesk", "metrics": {"quality": {"groundedness": 3.7}}},
                ]
            },
        },
    )
    b = tr._load_manifest(baseline)
    c = tr._load_manifest(current)
    return tr.compare(
        baseline=b,
        current=c,
        baseline_path=str(baseline),
        current_path=str(current),
    )


def test_render_html_contains_table_and_rows(tmp_path: Path):
    report = _sample_report(tmp_path)
    html_output = tr.render_html(report)
    assert "<!DOCTYPE html>" in html_output
    assert "Attack Success Rate" in html_output
    assert "HR-Helpdesk" in html_output
    assert "Sales-Research" in html_output
    assert "Evaluator Metrics" in html_output
    assert "quality.groundedness" in html_output


def test_render_html_marks_regression_rows(tmp_path: Path):
    report = _sample_report(tmp_path)
    html_output = tr.render_html(report)
    # HR-Helpdesk row should carry the regression class (ASR went up)
    assert "regression" in html_output
    # Badge indicating detected regressions appears in the header
    assert "REGRESSIONS DETECTED" in html_output


def test_render_html_marks_improvements(tmp_path: Path):
    report = _sample_report(tmp_path)
    html_output = tr.render_html(report)
    # Sales-Research ASR dropped → improvement class present
    assert "improvement" in html_output


def test_render_html_clean_when_no_regressions(tmp_path: Path):
    # Identical baseline and current → no regressions.
    foundry = {
        "redTeaming": {
            "agentScans": [
                {"agentName": "HR-Helpdesk", "scorecard": {"attack_success_rate": 0.20}},
            ]
        }
    }
    path = _write(tmp_path, "same.json", foundry)
    m = tr._load_manifest(path)
    report = tr.compare(
        baseline=m,
        current=m,
        baseline_path=str(path),
        current_path=str(path),
    )
    html_output = tr.render_html(report)
    assert "CLEAN" in html_output
    assert "REGRESSIONS DETECTED" not in html_output


def test_render_html_empty_sections(tmp_path: Path):
    # Manifest with no redTeaming or evaluations data.
    path = _write(tmp_path, "empty.json", {})
    m = tr._load_manifest(path)
    report = tr.compare(
        baseline=None,
        current=m,
        baseline_path="(none)",
        current_path=str(path),
    )
    html_output = tr.render_html(report)
    assert "No ASR data" in html_output
    assert "No evaluator metrics" in html_output


def test_cli_writes_html_file(tmp_path: Path, capsys):
    baseline = _write(
        tmp_path,
        "base.json",
        {"redTeaming": {"agentScans": [{"agentName": "A", "scorecard": {"asr": 0.1}}]}},
    )
    current = _write(
        tmp_path,
        "cur.json",
        {"redTeaming": {"agentScans": [{"agentName": "A", "scorecard": {"asr": 0.2}}]}},
    )
    out_html = tmp_path / "report.html"
    rc = tr.main(
        [
            "--baseline",
            str(baseline),
            "--current",
            str(current),
            "--html",
            str(out_html),
        ]
    )
    assert rc == 0
    assert out_html.is_file()
    content = out_html.read_text()
    assert "<!DOCTYPE html>" in content
    assert "Attack Success Rate" in content
