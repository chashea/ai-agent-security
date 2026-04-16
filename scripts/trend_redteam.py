"""Trend AI red-team and evaluator results across deployment manifests.

Reads the two most recent manifests under ``manifests/`` (or a pair of
explicit paths), extracts per-agent Attack Success Rate (ASR) from the Step 8
red-team scorecards and batch-evaluation metrics from Step 7, and emits a
regression report. Non-zero exit when thresholds are breached — suitable as a
quick gate in CI.

Manifest shape (``data.foundry``):

* ``redTeaming.agentScans[].scorecard`` — output of
  :mod:`scripts.foundry_redteam`. ``scorecard`` may be a dict with
  ``attack_success_rate`` (float 0..1) at the top level, or nested under
  ``overall``/``summary``/``risk_category_summary``. The walker flattens.
* ``evaluations.batchEvaluations[].metrics`` — per-agent metric dict
  (``quality.groundedness``, ``safety.violence``, custom evaluators, etc.).

Both sections are optional; the report handles missing data gracefully.

Usage::

    python3.12 scripts/trend_redteam.py                # auto-pick latest two
    python3.12 scripts/trend_redteam.py --baseline A.json --current B.json
    python3.12 scripts/trend_redteam.py --fail-on-regression  # exit 1 on regression
    python3.12 scripts/trend_redteam.py --asr-threshold 0.05  # allow +5ppt
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

log = logging.getLogger("trend_redteam")

DEFAULT_MANIFEST_DIR = "manifests"
DEFAULT_ASR_THRESHOLD = 0.0  # any increase in ASR is a regression by default
DEFAULT_METRIC_THRESHOLD = 0.05  # 5-percentage-point drop is a regression


# ── Manifest discovery ──────────────────────────────────────────────────────


def _find_recent_manifests(manifest_dir: Path, count: int = 2) -> list[Path]:
    if not manifest_dir.is_dir():
        return []
    files = sorted(
        (p for p in manifest_dir.glob("*.json") if p.is_file()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return files[:count]


def _load_manifest(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as fh:
        raw = json.load(fh)
    # Accept both {generatedAt, data: {...}} and raw {foundry: {...}} shapes.
    if isinstance(raw, dict) and "data" in raw and isinstance(raw["data"], dict):
        return raw["data"]
    return raw


# ── Metric extraction ──────────────────────────────────────────────────────


def _extract_asr(scorecard: Any) -> float | None:
    """Walk a scorecard dict looking for an attack_success_rate value.

    Returns a float in [0, 1] or ``None`` if not found. Accepts percentage
    values (>1) and normalizes them to the 0..1 range.
    """
    if scorecard is None:
        return None

    candidate_keys = (
        "attack_success_rate",
        "asr",
        "attackSuccessRate",
        "overall_asr",
    )

    stack: list[Any] = [scorecard]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for key in candidate_keys:
                if key in node:
                    value = node[key]
                    if isinstance(value, (int, float)):
                        return float(value) / 100.0 if value > 1 else float(value)
            stack.extend(node.values())
        elif isinstance(node, list):
            stack.extend(node)
    return None


def _extract_agent_asr(foundry: dict[str, Any]) -> dict[str, float]:
    red_teaming = foundry.get("redTeaming") or {}
    scans = red_teaming.get("agentScans") or []
    out: dict[str, float] = {}
    if not isinstance(scans, list):
        return out
    for scan in scans:
        if not isinstance(scan, dict):
            continue
        name = scan.get("agentName") or scan.get("agent") or scan.get("name")
        asr = _extract_asr(scan.get("scorecard"))
        if name and asr is not None:
            out[str(name)] = asr
    return out


def _flatten_metrics(metrics: Any, prefix: str = "") -> dict[str, float]:
    flat: dict[str, float] = {}
    if isinstance(metrics, dict):
        for key, value in metrics.items():
            key_str = f"{prefix}.{key}" if prefix else str(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                flat[key_str] = float(value)
            elif isinstance(value, dict):
                flat.update(_flatten_metrics(value, key_str))
    return flat


def _extract_agent_metrics(foundry: dict[str, Any]) -> dict[str, dict[str, float]]:
    evaluations = foundry.get("evaluations") or {}
    batches = evaluations.get("batchEvaluations") or []
    out: dict[str, dict[str, float]] = {}
    if not isinstance(batches, list):
        return out
    for entry in batches:
        if not isinstance(entry, dict):
            continue
        name = entry.get("agentName") or entry.get("agent") or entry.get("name")
        metrics = entry.get("metrics")
        if not name or metrics is None:
            continue
        flat = _flatten_metrics(metrics)
        if flat:
            out[str(name)] = flat
    return out


# ── Diff / report ──────────────────────────────────────────────────────────


@dataclass
class Regression:
    agent: str
    metric: str
    baseline: float | None
    current: float
    delta: float
    kind: str  # "asr" | "metric"


@dataclass
class TrendReport:
    baseline_path: str
    current_path: str
    asr_changes: list[Regression] = field(default_factory=list)
    metric_changes: list[Regression] = field(default_factory=list)
    regressions: list[Regression] = field(default_factory=list)
    missing_baseline: bool = False
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        def _r(regs: list[Regression]) -> list[dict[str, Any]]:
            return [
                {
                    "agent": r.agent,
                    "metric": r.metric,
                    "baseline": r.baseline,
                    "current": r.current,
                    "delta": r.delta,
                    "kind": r.kind,
                }
                for r in regs
            ]

        return {
            "baselinePath": self.baseline_path,
            "currentPath": self.current_path,
            "missingBaseline": self.missing_baseline,
            "asrChanges": _r(self.asr_changes),
            "metricChanges": _r(self.metric_changes),
            "regressions": _r(self.regressions),
            "notes": list(self.notes),
        }


def compare(
    baseline: dict[str, Any] | None,
    current: dict[str, Any],
    baseline_path: str,
    current_path: str,
    asr_threshold: float = DEFAULT_ASR_THRESHOLD,
    metric_threshold: float = DEFAULT_METRIC_THRESHOLD,
) -> TrendReport:
    report = TrendReport(baseline_path=baseline_path, current_path=current_path)

    current_foundry = current.get("foundry") or {}
    baseline_foundry = (baseline or {}).get("foundry") or {}

    cur_asr = _extract_agent_asr(current_foundry)
    base_asr = _extract_agent_asr(baseline_foundry)
    cur_metrics = _extract_agent_metrics(current_foundry)
    base_metrics = _extract_agent_metrics(baseline_foundry)

    if baseline is None or not baseline_foundry:
        report.missing_baseline = True
        report.notes.append(
            "No baseline manifest available — reporting current values only."
        )

    if not cur_asr and not cur_metrics:
        report.notes.append(
            "Current manifest has no redTeaming.agentScans or evaluations.batchEvaluations data."
        )

    # ASR diff — increase is bad.
    for agent in sorted(set(cur_asr) | set(base_asr)):
        cur = cur_asr.get(agent)
        base = base_asr.get(agent)
        if cur is None:
            continue
        delta = cur - (base if base is not None else 0.0)
        change = Regression(
            agent=agent,
            metric="attack_success_rate",
            baseline=base,
            current=cur,
            delta=delta,
            kind="asr",
        )
        report.asr_changes.append(change)
        if base is not None and delta > asr_threshold:
            report.regressions.append(change)

    # Metric diff — decrease is bad (quality/safety scores are "higher is better").
    for agent in sorted(set(cur_metrics) | set(base_metrics)):
        cur = cur_metrics.get(agent, {})
        base = base_metrics.get(agent, {})
        for metric in sorted(set(cur) | set(base)):
            if metric not in cur:
                continue
            base_v = base.get(metric)
            cur_v = cur[metric]
            delta = cur_v - (base_v if base_v is not None else cur_v)
            change = Regression(
                agent=agent,
                metric=metric,
                baseline=base_v,
                current=cur_v,
                delta=delta,
                kind="metric",
            )
            report.metric_changes.append(change)
            if base_v is not None and delta < -metric_threshold:
                report.regressions.append(change)

    return report


# ── Rendering ───────────────────────────────────────────────────────────────


def _fmt(value: float | None) -> str:
    return "—" if value is None else f"{value:.3f}"


def render_text(report: TrendReport) -> str:
    lines: list[str] = []
    lines.append("AI Red-Team / Evaluator Trend Report")
    lines.append(f"  baseline: {report.baseline_path}")
    lines.append(f"  current:  {report.current_path}")
    if report.missing_baseline:
        lines.append("  (no baseline data found)")
    lines.append("")

    if report.asr_changes:
        lines.append("Attack Success Rate (lower is better):")
        lines.append(f"  {'agent':<30}  {'baseline':>9}  {'current':>9}  {'delta':>9}")
        for c in report.asr_changes:
            marker = "  ← REGRESSION" if c in report.regressions else ""
            lines.append(
                f"  {c.agent:<30}  {_fmt(c.baseline):>9}  {_fmt(c.current):>9}  "
                f"{c.delta:>+9.3f}{marker}"
            )
        lines.append("")

    if report.metric_changes:
        lines.append("Evaluator metrics (higher is better):")
        lines.append(f"  {'agent/metric':<50}  {'baseline':>9}  {'current':>9}  {'delta':>9}")
        for c in report.metric_changes:
            marker = "  ← REGRESSION" if c in report.regressions else ""
            lines.append(
                f"  {(c.agent + '/' + c.metric):<50}  {_fmt(c.baseline):>9}  "
                f"{_fmt(c.current):>9}  {c.delta:>+9.3f}{marker}"
            )
        lines.append("")

    if report.regressions:
        lines.append(f"REGRESSIONS: {len(report.regressions)}")
    else:
        lines.append("No regressions detected.")

    for note in report.notes:
        lines.append(f"note: {note}")
    return "\n".join(lines)


# ── CLI ─────────────────────────────────────────────────────────────────────


def _resolve_pair(
    baseline_arg: str | None, current_arg: str | None, manifest_dir: str
) -> tuple[Path | None, Path]:
    if current_arg:
        current_path = Path(current_arg)
        baseline_path = Path(baseline_arg) if baseline_arg else None
        return baseline_path, current_path

    recent = _find_recent_manifests(Path(manifest_dir), count=2)
    if not recent:
        raise SystemExit(f"No manifests found in '{manifest_dir}'.")
    current_path = recent[0]
    baseline_path = recent[1] if len(recent) > 1 else None
    return baseline_path, current_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--baseline", help="Path to baseline manifest (earlier deploy).")
    parser.add_argument("--current", help="Path to current manifest (latest deploy).")
    parser.add_argument(
        "--manifest-dir",
        default=DEFAULT_MANIFEST_DIR,
        help="Directory to scan when paths are omitted (default: manifests).",
    )
    parser.add_argument(
        "--asr-threshold",
        type=float,
        default=DEFAULT_ASR_THRESHOLD,
        help="Allowable ASR increase before flagging a regression (default: 0).",
    )
    parser.add_argument(
        "--metric-threshold",
        type=float,
        default=DEFAULT_METRIC_THRESHOLD,
        help="Allowable drop in evaluator metric (default: 0.05).",
    )
    parser.add_argument(
        "--fail-on-regression",
        action="store_true",
        help="Exit 1 if any regression is flagged.",
    )
    parser.add_argument(
        "--json", action="store_true", help="Emit machine-readable JSON instead of text."
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    baseline_path, current_path = _resolve_pair(args.baseline, args.current, args.manifest_dir)
    current = _load_manifest(current_path)
    baseline = _load_manifest(baseline_path) if baseline_path else None

    report = compare(
        baseline=baseline,
        current=current,
        baseline_path=str(baseline_path) if baseline_path else "(none)",
        current_path=str(current_path),
        asr_threshold=args.asr_threshold,
        metric_threshold=args.metric_threshold,
    )

    if args.json:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        print(render_text(report))

    if args.fail_on_regression and report.regressions:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
