#!/usr/bin/env python3
"""Foundry AI Red Teaming pipeline — automated adversarial probing of deployed
agents using Microsoft's AI Red Teaming Agent (PyRIT-backed local scans) and
Foundry cloud-based red teaming with taxonomy support.

Local mode uses azure-ai-evaluation[redteam] SDK to run content/model risk
scans. Cloud mode uses azure-ai-projects SDK to create red team evals with
agentic risk categories (prohibited actions, sensitive data leakage, task
adherence) and attack strategies.

Usage:
    python3.12 foundry_redteam.py --action scan --config input.json
    python3.12 foundry_redteam.py --action cloud-scan --config input.json
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

CLOUD_SUPPORTED_REGIONS = {"eastus2", "francecentral", "swedencentral", "switzerlandwest", "northcentralus"}


def _get_token(credential: DefaultAzureCredential, scope: str) -> str:
    return credential.get_token(scope).token


def _data_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ── Risk category mapping ────────────────────────────────────────────────────

_RISK_CATEGORY_MAP = {
    "violence": "Violence",
    "hate_unfairness": "HateUnfairness",
    "sexual": "Sexual",
    "self_harm": "SelfHarm",
    "protected_material": "ProtectedMaterial",
    "code_vulnerability": "CodeVulnerability",
    "ungrounded_attributes": "UngroundedAttributes",
}

_ATTACK_STRATEGY_MAP = {
    "AnsiAttack": "AnsiAttack",
    "AsciiArt": "AsciiArt",
    "AsciiSmuggler": "AsciiSmuggler",
    "Atbash": "Atbash",
    "Base64": "Base64",
    "Binary": "Binary",
    "Caesar": "Caesar",
    "CharacterSpace": "CharacterSpace",
    "CharSwap": "CharSwap",
    "Diacritic": "Diacritic",
    "Flip": "Flip",
    "Leetspeak": "Leetspeak",
    "Morse": "Morse",
    "ROT13": "ROT13",
    "SuffixAppend": "SuffixAppend",
    "StringJoin": "StringJoin",
    "UnicodeConfusable": "UnicodeConfusable",
    "UnicodeSubstitution": "UnicodeSubstitution",
    "Url": "Url",
    "Jailbreak": "Jailbreak",
    "IndirectAttack": "IndirectAttack",
    "Tense": "Tense",
    "Multiturn": "Multiturn",
    "Crescendo": "Crescendo",
    "EASY": "EASY",
    "MODERATE": "MODERATE",
    "DIFFICULT": "DIFFICULT",
}


# ── Local Red Teaming (azure-ai-evaluation[redteam]) ────────────────────────


def _import_redteam():
    """Lazy import of azure-ai-evaluation[redteam]. Returns (RedTeam, RiskCategory, AttackStrategy)
    or raises ImportError with install instructions."""
    try:
        from azure.ai.evaluation.red_team import AttackStrategy, RedTeam, RiskCategory
        return RedTeam, RiskCategory, AttackStrategy
    except ImportError:
        raise ImportError(
            "azure-ai-evaluation[redteam] is required for local red teaming. "
            "Install with: pip install 'azure-ai-evaluation[redteam]'"
        )


def _build_agent_callback(project_endpoint: str, data_token: str, agent_id: str, api_version: str):
    """Build a callback function that sends a prompt to a Foundry agent and
    returns the response. Creates a transient thread per prompt and cleans up."""

    def callback(query: str) -> str:
        headers = _data_headers(data_token)
        thread_id = None
        try:
            # Create thread
            thread_resp = requests.post(
                f"{project_endpoint}/threads?api-version={api_version}",
                json={},
                headers=headers,
                timeout=30,
            )
            thread_resp.raise_for_status()
            thread_id = thread_resp.json()["id"]

            # Add message
            requests.post(
                f"{project_endpoint}/threads/{thread_id}/messages?api-version={api_version}",
                json={"role": "user", "content": query},
                headers=headers,
                timeout=30,
            ).raise_for_status()

            # Create run
            run_resp = requests.post(
                f"{project_endpoint}/threads/{thread_id}/runs?api-version={api_version}",
                json={"assistant_id": agent_id},
                headers=headers,
                timeout=30,
            )
            run_resp.raise_for_status()
            run_id = run_resp.json()["id"]

            # Poll for completion
            for _ in range(60):
                status_resp = requests.get(
                    f"{project_endpoint}/threads/{thread_id}/runs/{run_id}?api-version={api_version}",
                    headers=headers,
                    timeout=15,
                )
                status_resp.raise_for_status()
                status = status_resp.json().get("status", "")
                if status in ("completed", "failed", "cancelled", "expired"):
                    break
                time.sleep(2)

            if status != "completed":
                return f"[Agent run {status}]"

            # Get messages
            msgs_resp = requests.get(
                f"{project_endpoint}/threads/{thread_id}/messages?api-version={api_version}&order=desc&limit=1",
                headers=headers,
                timeout=15,
            )
            msgs_resp.raise_for_status()
            messages = msgs_resp.json().get("data", [])
            if messages:
                content_blocks = messages[0].get("content", [])
                text_parts = [b.get("text", {}).get("value", "") for b in content_blocks if b.get("type") == "text"]
                return " ".join(text_parts) if text_parts else "[No text response]"
            return "[No response]"

        except Exception as exc:
            log.warning("Agent callback error for %s: %s", agent_id, exc)
            return f"[Error: {exc}]"
        finally:
            # Clean up transient thread
            if thread_id:
                try:
                    requests.delete(
                        f"{project_endpoint}/threads/{thread_id}?api-version={api_version}",
                        headers=headers,
                        timeout=10,
                    )
                except Exception:
                    pass

    return callback


def _resolve_risk_categories(categories: list, RiskCategory):
    """Map config string names to SDK RiskCategory enum values."""
    resolved = []
    for cat in categories:
        sdk_name = _RISK_CATEGORY_MAP.get(cat)
        if sdk_name and hasattr(RiskCategory, sdk_name):
            resolved.append(getattr(RiskCategory, sdk_name))
        else:
            log.warning("Unknown risk category '%s' — skipping", cat)
    return resolved


def _resolve_attack_strategies(strategy_config: dict, AttackStrategy):
    """Map config attack strategy names to SDK AttackStrategy values."""
    strategies = []
    for complexity, names in strategy_config.items():
        if isinstance(names, list):
            for name in names:
                if hasattr(AttackStrategy, name):
                    strategies.append(getattr(AttackStrategy, name))
                else:
                    log.warning("Unknown attack strategy '%s' — skipping", name)
        elif isinstance(names, str):
            if hasattr(AttackStrategy, names):
                strategies.append(getattr(AttackStrategy, names))
    # Also resolve complexity groups (EASY, MODERATE, DIFFICULT)
    for group in ("EASY", "MODERATE", "DIFFICULT"):
        if group in strategy_config and hasattr(AttackStrategy, group):
            strategies.append(getattr(AttackStrategy, group))
    return strategies


def run_local_scan(config: dict) -> dict:
    """Run local red teaming scans against deployed agents."""
    import asyncio

    RedTeam, RiskCategory, AttackStrategy = _import_redteam()
    credential = DefaultAzureCredential()
    data_token = _get_token(credential, "https://ai.azure.com/.default")

    project_endpoint = config["projectEndpoint"]
    api_version = config.get("agentApiVersion", "2025-05-15-preview")
    agents = config.get("agents", [])
    rt_config = config.get("redTeaming", {})

    # Build azure_ai_project dict for SDK
    azure_ai_project = {
        "subscription_id": config.get("subscriptionId", ""),
        "resource_group_name": config.get("resourceGroup", ""),
        "project_name": config.get("projectName", ""),
    }
    # If project endpoint is provided, use it directly (Foundry project format)
    project_endpoint_url = config.get("projectEndpoint", "")
    if project_endpoint_url:
        azure_ai_project = project_endpoint_url

    # Resolve risk categories (local only supports content/model risks)
    risk_cats = _resolve_risk_categories(
        rt_config.get("riskCategories", ["violence", "hate_unfairness", "sexual", "self_harm"]),
        RiskCategory,
    )
    num_objectives = rt_config.get("numObjectives", 5)

    # Resolve attack strategies
    attack_strategies = _resolve_attack_strategies(
        rt_config.get("attackStrategies", {}),
        AttackStrategy,
    )

    results = {
        "mode": "local",
        "agentScans": [],
    }

    async def _scan_agent(agent: dict) -> dict:
        agent_name = agent.get("name", "unknown")
        agent_id = agent.get("id", "")
        log.info("Red teaming agent '%s' (id=%s)...", agent_name, agent_id)

        try:
            red_team = RedTeam(
                azure_ai_project=azure_ai_project,
                credential=credential,
                risk_categories=risk_cats if risk_cats else None,
                num_objectives=num_objectives,
            )

            callback = _build_agent_callback(project_endpoint, data_token, agent_id, api_version)

            scan_kwargs = {"target": callback}
            if attack_strategies:
                scan_kwargs["attack_strategies"] = attack_strategies
            scan_kwargs["scan_name"] = f"RedTeam-{agent_name}"

            scan_result = await red_team.scan(**scan_kwargs)

            scorecard = {}
            if hasattr(scan_result, "to_dict"):
                scorecard = scan_result.to_dict()
            elif isinstance(scan_result, dict):
                scorecard = scan_result
            else:
                scorecard = {"raw": str(scan_result)}

            log.info("Scan complete for '%s'", agent_name)
            return {
                "agentName": agent_name,
                "agentId": agent_id,
                "status": "completed",
                "scorecard": scorecard,
            }

        except Exception as exc:
            log.error("Red team scan failed for '%s': %s", agent_name, exc)
            return {
                "agentName": agent_name,
                "agentId": agent_id,
                "status": "failed",
                "error": str(exc),
            }

    async def _run_all():
        for agent in agents:
            result = await _scan_agent(agent)
            results["agentScans"].append(result)

    asyncio.run(_run_all())
    return results


# ── Cloud Red Teaming (azure-ai-projects SDK) ───────────────────────────────


def run_cloud_scan(config: dict) -> dict:
    """Run cloud-based red teaming with taxonomy support for agentic risks."""
    from azure.ai.projects import AIProjectClient
    from azure.ai.projects.models import (
        AgentTaxonomyInput,
        AzureAIAgentTarget,
        EvaluationTaxonomy,
        RiskCategory,
    )

    credential = DefaultAzureCredential()
    project_endpoint = config["projectEndpoint"]
    agents = config.get("agents", [])
    rt_config = config.get("redTeaming", {})
    model_deployment = config.get("modelDeploymentName", "gpt-4o")
    location = config.get("location", "eastus")

    # Region check
    location_normalized = location.lower().replace(" ", "").replace("-", "")
    if location_normalized not in CLOUD_SUPPORTED_REGIONS:
        log.warning(
            "Cloud red teaming requires a supported region (%s). Current: '%s'. "
            "Falling back to local scan.",
            ", ".join(sorted(CLOUD_SUPPORTED_REGIONS)),
            location,
        )
        return run_local_scan(config)

    # Agentic risk categories for cloud mode
    agentic_risk_map = {
        "prohibited_actions": RiskCategory.PROHIBITED_ACTIONS,
        "sensitive_data_leakage": RiskCategory.SENSITIVE_DATA_LEAKAGE,
        "task_adherence": RiskCategory.TASK_ADHERENCE,
    }
    agentic_cats = []
    for cat in rt_config.get("agentRiskCategories", ["prohibited_actions", "sensitive_data_leakage", "task_adherence"]):
        if cat in agentic_risk_map:
            agentic_cats.append(agentic_risk_map[cat])
        else:
            log.warning("Unknown agentic risk category '%s' — skipping", cat)

    attack_strats = []
    for complexity, names in rt_config.get("attackStrategies", {}).items():
        if isinstance(names, list):
            attack_strats.extend(names)
        elif isinstance(names, str):
            attack_strats.append(names)

    num_turns = rt_config.get("numTurns", 5)

    results = {
        "mode": "cloud",
        "agentScans": [],
    }

    with AIProjectClient(endpoint=project_endpoint, credential=credential) as project_client:
        client = project_client.get_openai_client()

        for agent in agents:
            agent_name = agent.get("name", "unknown")
            agent_id = agent.get("id", "")
            agent_version_str = str(agent.get("version", "1"))
            log.info("Cloud red teaming agent '%s'...", agent_name)

            try:
                # Step 1: Create red team eval with built-in evaluators
                testing_criteria = []
                if RiskCategory.PROHIBITED_ACTIONS in agentic_cats:
                    testing_criteria.append({
                        "type": "azure_ai_evaluator",
                        "name": "Prohibited Actions",
                        "evaluator_name": "builtin.prohibited_actions",
                        "evaluator_version": "1",
                    })
                if RiskCategory.TASK_ADHERENCE in agentic_cats:
                    testing_criteria.append({
                        "type": "azure_ai_evaluator",
                        "name": "Task Adherence",
                        "evaluator_name": "builtin.task_adherence",
                        "evaluator_version": "1",
                        "initialization_parameters": {"deployment_name": model_deployment},
                    })
                if RiskCategory.SENSITIVE_DATA_LEAKAGE in agentic_cats:
                    testing_criteria.append({
                        "type": "azure_ai_evaluator",
                        "name": "Sensitive Data Leakage",
                        "evaluator_name": "builtin.sensitive_data_leakage",
                        "evaluator_version": "1",
                    })

                red_team = client.evals.create(
                    name=f"RedTeam-{agent_name}",
                    data_source_config={"type": "azure_ai_source", "scenario": "red_team"},
                    testing_criteria=testing_criteria,
                )
                log.info("Created red team eval: %s", red_team.id)

                # Step 2: Create taxonomy for prohibited actions
                target = AzureAIAgentTarget(
                    name=agent_name,
                    version=agent_version_str,
                )

                taxonomy_risk_cats = [c for c in agentic_cats if c == RiskCategory.PROHIBITED_ACTIONS]
                taxonomy = None
                if taxonomy_risk_cats:
                    taxonomy = project_client.beta.evaluation_taxonomies.create(
                        name=agent_name,
                        body=EvaluationTaxonomy(
                            description=f"Red team taxonomy for {agent_name}",
                            taxonomy_input=AgentTaxonomyInput(
                                risk_categories=taxonomy_risk_cats,
                                target=target,
                            ),
                        ),
                    )
                    log.info("Created taxonomy: %s", taxonomy.id)

                # Step 3: Create run with attack strategies
                item_gen_params = {
                    "type": "red_team_taxonomy",
                    "attack_strategies": attack_strats if attack_strats else ["Flip", "Base64", "Jailbreak"],
                    "num_turns": num_turns,
                }
                if taxonomy:
                    item_gen_params["source"] = {"type": "file_id", "id": taxonomy.id}

                eval_run = client.evals.runs.create(
                    eval_id=red_team.id,
                    name=f"RedTeam-Run-{agent_name}",
                    data_source={
                        "type": "azure_ai_red_team",
                        "item_generation_params": item_gen_params,
                        "target": target.as_dict(),
                    },
                )
                log.info("Created run: %s (status: %s)", eval_run.id, eval_run.status)

                # Step 4: Poll for completion
                for _ in range(120):
                    run = client.evals.runs.retrieve(run_id=eval_run.id, eval_id=red_team.id)
                    log.info("Run %s status: %s", eval_run.id, run.status)
                    if run.status in ("completed", "failed", "canceled"):
                        break
                    time.sleep(10)

                # Step 5: Collect output items
                output_items = []
                if run.status == "completed":
                    items = list(client.evals.runs.output_items.list(
                        run_id=eval_run.id,
                        eval_id=red_team.id,
                    ))
                    for item in items:
                        if hasattr(item, "to_dict"):
                            output_items.append(item.to_dict())
                        elif isinstance(item, dict):
                            output_items.append(item)
                        else:
                            output_items.append({"raw": str(item)})

                results["agentScans"].append({
                    "agentName": agent_name,
                    "agentId": agent_id,
                    "redTeamId": red_team.id,
                    "runId": eval_run.id,
                    "status": run.status,
                    "outputItemCount": len(output_items),
                    "outputItems": output_items[:50],
                })

            except Exception as exc:
                log.error("Cloud red team failed for '%s': %s", agent_name, exc)
                results["agentScans"].append({
                    "agentName": agent_name,
                    "agentId": agent_id,
                    "status": "failed",
                    "error": str(exc),
                })

    return results


# ── Dispatch ─────────────────────────────────────────────────────────────────


def run_redteam_pipeline(config: dict, action: str) -> dict:
    """Route to local or cloud red teaming based on action."""
    rt_config = config.get("redTeaming", {})
    if not rt_config.get("enabled", True):
        log.info("Red teaming is disabled in config — skipping.")
        return {"mode": "disabled", "agentScans": []}

    if action == "cloud-scan":
        return run_cloud_scan(config)
    else:
        return run_local_scan(config)


# ── CLI ──────────────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="Foundry AI Red Teaming pipeline")
    parser.add_argument(
        "--action",
        required=True,
        choices=["scan", "cloud-scan"],
        help="Action: 'scan' (local) or 'cloud-scan' (cloud-based)",
    )
    parser.add_argument("--config", required=True, help="Path to JSON config file")
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    result = run_redteam_pipeline(config, args.action)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log.error("Fatal error: %s", exc)
        sys.exit(1)
