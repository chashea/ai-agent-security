#!/usr/bin/env python3
"""Foundry evaluation pipeline — batch eval, continuous eval, custom evaluators,
synthetic data generation, and prompt optimization.

Runs as post-deploy step after agents are created. Uses the Foundry data-plane
API and MCP-compatible evaluation endpoints.

Usage:
    python3.12 foundry_evals.py --action evaluate --config input.json
"""

import argparse
import json
import logging
import sys
import time

import requests
from azure.identity import DefaultAzureCredential

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger(__name__)


def _get_token(credential: DefaultAzureCredential, scope: str) -> str:
    return credential.get_token(scope).token


def _data_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _arm_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ── Prompt Optimization ──────────────────────────────────────────────────────


def optimize_prompt(
    project_endpoint: str,
    data_token: str,
    api_version: str,
    agent_name: str,
    instructions: str,
    model_deployment: str,
) -> dict:
    """Run prompt optimization on agent instructions. Returns optimization result."""
    url = f"{project_endpoint}/prompt-optimizations?api-version={api_version}"
    body = {
        "input": {
            "developerMessage": instructions,
            "deploymentName": model_deployment,
        }
    }
    resp = requests.post(url, json=body, headers=_data_headers(data_token), timeout=30)
    if resp.status_code < 400:
        result = resp.json()
        optimized = result.get("output", {}).get("optimizedMessage", instructions)
        log.info("Prompt optimized for %s (%d -> %d chars)", agent_name, len(instructions), len(optimized))
        return {
            "agentName": agent_name,
            "originalLength": len(instructions),
            "optimizedLength": len(optimized),
            "optimizedPrompt": optimized,
        }

    log.warning("Prompt optimization failed for '%s' (HTTP %d): %s", agent_name, resp.status_code, resp.text)
    return {"agentName": agent_name, "error": f"HTTP {resp.status_code}"}


# ── Custom Evaluator ─────────────────────────────────────────────────────────


def create_custom_evaluator(
    project_endpoint: str,
    data_token: str,
    api_version: str,
    evaluator_config: dict,
) -> dict | None:
    """Create a custom prompt-based evaluator. Returns evaluator info or None."""
    name = evaluator_config.get("name", "custom_evaluator")
    url = f"{project_endpoint}/evaluators?api-version={api_version}"

    # Check if exists
    check_url = f"{project_endpoint}/evaluators/{name}?api-version={api_version}"
    check = requests.get(check_url, headers=_data_headers(data_token), timeout=30)
    if check.status_code == 200:
        log.info("Custom evaluator already exists: %s", name)
        return {"name": name, "status": "exists"}

    body = {
        "name": name,
        "displayName": evaluator_config.get("displayName", name),
        "description": evaluator_config.get("description", ""),
        "type": "prompt",
        "category": evaluator_config.get("category", "quality"),
        "scoringType": evaluator_config.get("scoringType", "ordinal"),
        "promptText": evaluator_config.get("promptTemplate", ""),
        "minScore": evaluator_config.get("minScore", 1),
        "maxScore": evaluator_config.get("maxScore", 5),
    }

    resp = requests.post(url, json=body, headers=_data_headers(data_token), timeout=30)
    if resp.status_code < 400:
        result = resp.json()
        log.info("Created custom evaluator: %s", name)
        return {"name": name, "status": "created", "version": result.get("version", "1")}

    log.warning("Custom evaluator creation failed for '%s' (HTTP %d): %s", name, resp.status_code, resp.text)
    return None


# ── Batch Evaluation ─────────────────────────────────────────────────────────


def run_batch_evaluation(
    project_endpoint: str,
    data_token: str,
    api_version: str,
    agent_name: str,
    agent_version: str,
    evaluator_names: list[str],
    model_deployment: str,
    use_synthetic_data: bool = True,
    synthetic_count: int = 50,
) -> dict:
    """Run a batch evaluation against an agent. Returns evaluation results."""
    url = f"{project_endpoint}/evaluations?api-version={api_version}"

    eval_name = f"{agent_name}-security-eval"
    body: dict = {
        "displayName": eval_name,
        "description": f"Post-deploy security evaluation for {agent_name}",
        "target": {
            "type": "agent",
            "agentName": agent_name,
            "agentVersion": agent_version,
        },
        "evaluators": {},
    }

    # Configure evaluators
    for ev_name in evaluator_names:
        ev_config: dict = {"type": "builtin"}
        # Quality evaluators need a judge model
        quality_evals = {
            "coherence", "fluency", "relevance", "groundedness",
            "intent_resolution", "task_adherence",
        }
        if ev_name in quality_evals:
            ev_config["deploymentName"] = model_deployment
        body["evaluators"][ev_name] = ev_config

    # Data source: synthetic or manual
    if use_synthetic_data:
        body["data"] = {
            "type": "synthetic",
            "generationModelDeploymentName": model_deployment,
            "samplesCount": synthetic_count,
        }

    resp = requests.post(url, json=body, headers=_data_headers(data_token), timeout=30)
    if resp.status_code < 400:
        eval_result = resp.json()
        eval_id = eval_result.get("id", "")
        log.info("Started batch evaluation: %s (id: %s)", eval_name, eval_id)

        # Poll for completion
        return _poll_evaluation(project_endpoint, data_token, api_version, eval_id, agent_name)

    log.warning(
        "Batch evaluation failed for '%s' (HTTP %d): %s",
        agent_name, resp.status_code, resp.text,
    )
    return {"agentName": agent_name, "status": "failed", "error": f"HTTP {resp.status_code}"}


def _poll_evaluation(
    project_endpoint: str,
    data_token: str,
    api_version: str,
    eval_id: str,
    agent_name: str,
    timeout: int = 300,
) -> dict:
    """Poll evaluation run until complete. Returns results."""
    url = f"{project_endpoint}/evaluations/{eval_id}?api-version={api_version}"
    start = time.time()

    while time.time() - start < timeout:
        resp = requests.get(url, headers=_data_headers(data_token), timeout=30)
        if resp.status_code != 200:
            time.sleep(10)
            continue

        result = resp.json()
        status = result.get("status", "")

        if status == "Completed":
            metrics = result.get("metrics", {})
            log.info("Evaluation complete for %s: %s", agent_name, json.dumps(metrics, indent=2))
            return {
                "agentName": agent_name,
                "evaluationId": eval_id,
                "status": "completed",
                "metrics": metrics,
            }
        if status in ("Failed", "Canceled"):
            log.warning("Evaluation %s for %s: %s", status.lower(), agent_name, result.get("error", ""))
            return {"agentName": agent_name, "evaluationId": eval_id, "status": status.lower()}

        log.info("Evaluation in progress for %s: %s (%.0fs elapsed)", agent_name, status, time.time() - start)
        time.sleep(15)

    log.warning("Evaluation timed out for %s after %ds", agent_name, timeout)
    return {"agentName": agent_name, "evaluationId": eval_id, "status": "timeout"}


# ── Continuous Evaluation ────────────────────────────────────────────────────


def enable_continuous_evaluation(
    project_endpoint: str,
    data_token: str,
    api_version: str,
    agent_name: str,
    evaluator_names: list[str],
    model_deployment: str,
    sampling_rate: float = 0.1,
) -> dict:
    """Enable continuous evaluation on an agent."""
    url = f"{project_endpoint}/agents/{agent_name}/continuous-evaluation?api-version={api_version}"
    body = {
        "enabled": True,
        "evaluatorNames": evaluator_names,
        "deploymentName": model_deployment,
        "samplingRate": sampling_rate,
        "scenario": "standard",
    }
    resp = requests.put(url, json=body, headers=_data_headers(data_token), timeout=30)
    if resp.status_code < 400:
        log.info("Continuous evaluation enabled for %s (%.0f%% sampling)", agent_name, sampling_rate * 100)
        return {"agentName": agent_name, "status": "enabled", "samplingRate": sampling_rate}

    log.warning(
        "Continuous eval failed for '%s' (HTTP %d): %s",
        agent_name, resp.status_code, resp.text,
    )
    return {"agentName": agent_name, "status": "failed", "error": f"HTTP {resp.status_code}"}


# ── Full Evaluation Pipeline ─────────────────────────────────────────────────


def _evaluations_available(project_endpoint: str, data_token: str, api_version: str) -> bool:
    """Probe whether the evaluations/prompt-optimization endpoints exist on this
    project. Some Foundry project tiers/regions don't expose them, in which case
    every call returns 404 and we should skip the entire pipeline instead of
    spamming warnings."""
    url = f"{project_endpoint}/evaluations?api-version={api_version}"
    try:
        resp = requests.get(url, headers=_data_headers(data_token), timeout=10)
        return resp.status_code != 404
    except Exception:
        return False


def run_evaluation_pipeline(config: dict) -> dict:
    """Run the complete post-deploy evaluation pipeline."""
    credential = DefaultAzureCredential()
    data_token = _get_token(credential, "https://ai.azure.com/.default")

    project_endpoint = config["projectEndpoint"]
    # Evaluation endpoints (evaluators, evaluations, prompt-optimizations,
    # continuous-evaluation) require a newer api-version than the agents API.
    api_version = config.get("evalApiVersion", "2025-11-15-preview")
    agents = config.get("agents", [])
    eval_config = config.get("evaluations", {})
    model_deployment = config.get("modelDeploymentName", "gpt-4o")

    results: dict = {
        "promptOptimization": [],
        "customEvaluators": [],
        "batchEvaluations": [],
        "continuousEvaluation": [],
    }

    if not _evaluations_available(project_endpoint, data_token, api_version):
        log.warning(
            "Foundry evaluations endpoints not available on this project — skipping pipeline. "
            "(Requires Standard Agent Setup with the evaluation service enabled.)"
        )
        return results

    # Collect all evaluator names
    batch_evaluators = eval_config.get("batchEvaluators", {})
    all_evaluators = []
    for category_evals in batch_evaluators.values():
        all_evaluators.extend(category_evals)

    # Safety evaluators for continuous eval
    safety_evaluators = batch_evaluators.get("safety", [])

    # Step 8a: Prompt optimization
    if eval_config.get("promptOptimization", False):
        log.info("=== Step 8a: Prompt Optimization ===")
        for agent in agents:
            opt_result = optimize_prompt(
                project_endpoint, data_token, api_version,
                agent.get("name", ""),
                agent.get("instructions", ""),
                model_deployment,
            )
            results["promptOptimization"].append(opt_result)

    # Step 8b: Custom evaluators
    custom_evaluators = eval_config.get("customEvaluators", [])
    if custom_evaluators:
        log.info("=== Step 8b: Custom Evaluators ===")
        for ev_config in custom_evaluators:
            ev_result = create_custom_evaluator(
                project_endpoint, data_token, api_version, ev_config
            )
            if ev_result:
                results["customEvaluators"].append(ev_result)
                # Add custom evaluator to batch list
                all_evaluators.append(ev_config["name"])

    # Step 8c+8d: Batch evaluation (includes synthetic data generation)
    use_synthetic = eval_config.get("syntheticDataGeneration", True)
    log.info("=== Step 8c/8d: Batch Evaluation ===")
    for agent in agents:
        agent_name = agent.get("name", "")
        eval_result = run_batch_evaluation(
            project_endpoint, data_token, api_version,
            agent_name, str(agent.get("version", "1")),
            all_evaluators,
            model_deployment,
            use_synthetic_data=use_synthetic,
        )
        results["batchEvaluations"].append(eval_result)

    # Step 8e: Continuous evaluation
    continuous_cfg = eval_config.get("continuousEvaluation", {})
    sampling_rate = continuous_cfg.get("samplingRate", 0.1)
    if continuous_cfg:
        log.info("=== Step 8e: Continuous Evaluation ===")
        for agent in agents:
            cont_result = enable_continuous_evaluation(
                project_endpoint, data_token, api_version,
                agent.get("name", ""),
                safety_evaluators + ["coherence", "fluency"],
                model_deployment,
                sampling_rate=sampling_rate,
            )
            results["continuousEvaluation"].append(cont_result)

    return results


# ── CLI ──────────────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="Foundry evaluation pipeline")
    parser.add_argument(
        "--action",
        required=True,
        choices=["evaluate"],
        help="Action to perform",
    )
    parser.add_argument("--config", required=True, help="Path to JSON config file")
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    result = run_evaluation_pipeline(config)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log.error("Fatal error: %s", exc)
        sys.exit(1)
