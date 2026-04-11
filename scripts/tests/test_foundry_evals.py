"""Tests for foundry_evals.py — mocked API calls, no cloud connection required."""

import sys
import os
from unittest.mock import MagicMock, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from foundry_evals import (
    create_custom_evaluator,
    enable_continuous_evaluation,
    optimize_prompt,
    run_batch_evaluation,
    run_evaluation_pipeline,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def pipeline_config():
    return {
        "projectEndpoint": "https://test-account.services.ai.azure.com/api/projects/test-project",
        "agentApiVersion": "2025-05-15-preview",
        "modelDeploymentName": "gpt-4o",
        "agents": [
            {
                "name": "HR-Helpdesk",
                "instructions": "You are an HR assistant.",
                "version": 1,
            }
        ],
        "evaluations": {
            "promptOptimization": True,
            "syntheticDataGeneration": True,
            "batchEvaluators": {
                "quality": ["coherence", "fluency"],
                "safety": ["hate_unfairness", "violence"],
            },
            "customEvaluators": [
                {
                    "name": "policy_adherence",
                    "displayName": "Policy Adherence",
                    "description": "Checks policy adherence",
                    "promptTemplate": "Rate adherence from 1 to 5.",
                }
            ],
            "continuousEvaluation": {
                "samplingRate": 0.1,
            },
        },
    }


# ── Prompt Optimization ───────────────────────────────────────────────────────


class TestOptimizePrompt:
    @patch("foundry_evals.requests.post")
    def test_success(self, mock_post):
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={
                "output": {"optimizedMessage": "You are a highly effective HR assistant."}
            }),
        )

        result = optimize_prompt(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "HR-Helpdesk",
            "You are an HR assistant.",
            "gpt-4o",
        )

        assert result["agentName"] == "HR-Helpdesk"
        assert result["optimizedPrompt"] == "You are a highly effective HR assistant."
        assert "originalLength" in result
        assert "optimizedLength" in result
        assert "error" not in result

    @patch("foundry_evals.requests.post")
    def test_failure(self, mock_post):
        mock_post.return_value = MagicMock(status_code=500, text="Internal server error")

        result = optimize_prompt(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "HR-Helpdesk",
            "You are an HR assistant.",
            "gpt-4o",
        )

        assert result["agentName"] == "HR-Helpdesk"
        assert "error" in result
        assert "500" in result["error"]


# ── Custom Evaluator ──────────────────────────────────────────────────────────


class TestCustomEvaluator:
    @patch("foundry_evals.requests.post")
    @patch("foundry_evals.requests.get")
    def test_create_evaluator(self, mock_get, mock_post):
        mock_get.return_value = MagicMock(status_code=404)
        mock_post.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"version": "1"}),
        )

        evaluator_config = {
            "name": "policy_adherence",
            "displayName": "Policy Adherence",
            "description": "Checks if responses adhere to company policy",
            "promptTemplate": "Rate from 1 to 5.",
        }
        result = create_custom_evaluator(
            "https://endpoint", "fake-token", "2025-05-15-preview", evaluator_config
        )

        assert result is not None
        assert result["name"] == "policy_adherence"
        assert result["status"] == "created"
        mock_post.assert_called_once()

    @patch("foundry_evals.requests.get")
    def test_evaluator_already_exists(self, mock_get):
        mock_get.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"name": "policy_adherence"}),
        )

        evaluator_config = {"name": "policy_adherence"}
        result = create_custom_evaluator(
            "https://endpoint", "fake-token", "2025-05-15-preview", evaluator_config
        )

        assert result is not None
        assert result["status"] == "exists"

    @patch("foundry_evals.requests.post")
    @patch("foundry_evals.requests.get")
    def test_create_evaluator_failure(self, mock_get, mock_post):
        mock_get.return_value = MagicMock(status_code=404)
        mock_post.return_value = MagicMock(status_code=400, text="Bad request")

        result = create_custom_evaluator(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            {"name": "bad_evaluator"},
        )
        assert result is None


# ── Batch Evaluation ──────────────────────────────────────────────────────────


class TestBatchEvaluation:
    @patch("foundry_evals.time.sleep")
    @patch("foundry_evals.requests.get")
    @patch("foundry_evals.requests.post")
    def test_starts_eval_and_polls(self, mock_post, mock_get, mock_sleep):
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"id": "eval-run-abc123"}),
        )
        mock_get.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={
                "status": "Completed",
                "metrics": {"coherence": 4.2, "fluency": 4.5},
            }),
        )

        result = run_batch_evaluation(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "HR-Helpdesk",
            "1",
            ["coherence", "fluency"],
            "gpt-4o",
        )

        assert result["agentName"] == "HR-Helpdesk"
        assert result["status"] == "completed"
        assert result["evaluationId"] == "eval-run-abc123"
        assert result["metrics"]["coherence"] == 4.2
        mock_post.assert_called_once()
        mock_get.assert_called_once()

    @patch("foundry_evals.requests.post")
    def test_eval_failure(self, mock_post):
        mock_post.return_value = MagicMock(status_code=400, text="Bad request")

        result = run_batch_evaluation(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "HR-Helpdesk",
            "1",
            ["coherence"],
            "gpt-4o",
        )

        assert result["agentName"] == "HR-Helpdesk"
        assert result["status"] == "failed"
        assert "error" in result

    @patch("foundry_evals.time.sleep")
    @patch("foundry_evals.requests.get")
    @patch("foundry_evals.requests.post")
    def test_eval_polls_until_completed(self, mock_post, mock_get, mock_sleep):
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"id": "eval-run-poll123"}),
        )
        # First two polls return "Running", third returns "Completed"
        mock_get.side_effect = [
            MagicMock(status_code=200, json=MagicMock(return_value={"status": "Running"})),
            MagicMock(status_code=200, json=MagicMock(return_value={"status": "Running"})),
            MagicMock(
                status_code=200,
                json=MagicMock(return_value={"status": "Completed", "metrics": {}}),
            ),
        ]

        result = run_batch_evaluation(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "HR-Helpdesk",
            "1",
            ["coherence"],
            "gpt-4o",
        )

        assert result["status"] == "completed"
        assert mock_get.call_count == 3


# ── Continuous Evaluation ─────────────────────────────────────────────────────


class TestContinuousEvaluation:
    @patch("foundry_evals.requests.put")
    def test_enable_success(self, mock_put):
        mock_put.return_value = MagicMock(status_code=200)

        result = enable_continuous_evaluation(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "HR-Helpdesk",
            ["hate_unfairness", "violence"],
            "gpt-4o",
            sampling_rate=0.1,
        )

        assert result["agentName"] == "HR-Helpdesk"
        assert result["status"] == "enabled"
        assert result["samplingRate"] == 0.1
        mock_put.assert_called_once()

    @patch("foundry_evals.requests.put")
    def test_enable_failure(self, mock_put):
        mock_put.return_value = MagicMock(status_code=400, text="Bad request")

        result = enable_continuous_evaluation(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "HR-Helpdesk",
            ["coherence"],
            "gpt-4o",
        )

        assert result["agentName"] == "HR-Helpdesk"
        assert result["status"] == "failed"
        assert "error" in result


# ── Full Evaluation Pipeline ──────────────────────────────────────────────────


class TestEvalPipeline:
    @patch("foundry_evals.enable_continuous_evaluation")
    @patch("foundry_evals.run_batch_evaluation")
    @patch("foundry_evals.create_custom_evaluator")
    @patch("foundry_evals.optimize_prompt")
    @patch("foundry_evals._get_token")
    @patch("foundry_evals.DefaultAzureCredential")
    def test_full_pipeline(
        self,
        mock_cred,
        mock_token,
        mock_opt,
        mock_evaluator,
        mock_batch,
        mock_cont,
        pipeline_config,
    ):
        mock_cred.return_value = MagicMock()
        mock_token.return_value = "fake-token"

        mock_opt.return_value = {
            "agentName": "HR-Helpdesk",
            "originalLength": 28,
            "optimizedLength": 45,
            "optimizedPrompt": "You are a highly effective HR assistant.",
        }
        mock_evaluator.return_value = {"name": "policy_adherence", "status": "created"}
        mock_batch.return_value = {
            "agentName": "HR-Helpdesk",
            "evaluationId": "eval-123",
            "status": "completed",
            "metrics": {"coherence": 4.2},
        }
        mock_cont.return_value = {
            "agentName": "HR-Helpdesk",
            "status": "enabled",
            "samplingRate": 0.1,
        }

        result = run_evaluation_pipeline(pipeline_config)

        # All four sections must be present in the result
        assert "promptOptimization" in result
        assert "customEvaluators" in result
        assert "batchEvaluations" in result
        assert "continuousEvaluation" in result

        assert len(result["promptOptimization"]) == 1
        assert result["promptOptimization"][0]["agentName"] == "HR-Helpdesk"

        assert len(result["customEvaluators"]) == 1
        assert result["customEvaluators"][0]["name"] == "policy_adherence"

        assert len(result["batchEvaluations"]) == 1
        assert result["batchEvaluations"][0]["status"] == "completed"

        assert len(result["continuousEvaluation"]) == 1
        assert result["continuousEvaluation"][0]["status"] == "enabled"

        mock_opt.assert_called_once()
        mock_evaluator.assert_called_once()
        mock_batch.assert_called_once()
        mock_cont.assert_called_once()
