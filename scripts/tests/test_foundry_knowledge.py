"""Tests for foundry_knowledge.py — mocked API calls, no cloud connection required."""

import sys
import os
from unittest.mock import MagicMock, mock_open, patch

import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from foundry_knowledge import (
    cleanup_knowledge_base,
    create_vector_store,
    upload_file,
    upload_knowledge_base,
)


# ── Fixtures ──────────────────────────────────────────────────────────────────


@pytest.fixture
def base_config():
    return {
        "projectEndpoint": "https://test-account.services.ai.azure.com/api/projects/test-project",
        "agentApiVersion": "2025-05-15-preview",
        "prefix": "AISec",
        "knowledgeBase": {
            "HR-Helpdesk": ["hr_policies.txt", "benefits_guide.txt"],
        },
    }


@pytest.fixture
def cleanup_config():
    return {
        "projectEndpoint": "https://test-account.services.ai.azure.com/api/projects/test-project",
        "agentApiVersion": "2025-05-15-preview",
        "vectorStores": {
            "HR-Helpdesk": "vs-hr-abc123",
            "Compliance": "vs-compliance-def456",
        },
    }


# ── Upload File ───────────────────────────────────────────────────────────────


class TestUploadFile:
    @patch("foundry_knowledge.requests.post")
    def test_upload_success(self, mock_post):
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"id": "file-xyz123"}),
        )
        m = mock_open(read_data=b"file content")
        with patch("builtins.open", m):
            result = upload_file(
                "https://endpoint", "fake-token", "2025-05-15-preview", "/tmp/doc.txt"
            )
        assert result == "file-xyz123"
        mock_post.assert_called_once()

    @patch("foundry_knowledge.requests.post")
    def test_upload_failure(self, mock_post):
        mock_post.return_value = MagicMock(status_code=400, text="Bad request")
        m = mock_open(read_data=b"file content")
        with patch("builtins.open", m):
            result = upload_file(
                "https://endpoint", "fake-token", "2025-05-15-preview", "/tmp/doc.txt"
            )
        assert result is None


# ── Create Vector Store ───────────────────────────────────────────────────────


class TestCreateVectorStore:
    @patch("foundry_knowledge.time.sleep")
    @patch("foundry_knowledge.requests.get")
    @patch("foundry_knowledge.requests.post")
    def test_vector_store_created(self, mock_post, mock_get, mock_sleep):
        mock_post.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"id": "vs-new-abc123"}),
        )
        mock_get.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"status": "completed"}),
        )

        result = create_vector_store(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "AISec-HR-knowledge",
            ["file-abc", "file-def"],
        )
        assert result == "vs-new-abc123"
        mock_post.assert_called_once()
        mock_get.assert_called_once()

    @patch("foundry_knowledge.time.sleep")
    @patch("foundry_knowledge.requests.get")
    @patch("foundry_knowledge.requests.post")
    def test_vector_store_already_indexed(self, mock_post, mock_get, mock_sleep):
        mock_post.return_value = MagicMock(
            status_code=201,
            json=MagicMock(return_value={"id": "vs-existing-789"}),
        )
        # Immediate "completed" on first poll
        mock_get.return_value = MagicMock(
            status_code=200,
            json=MagicMock(return_value={"status": "completed"}),
        )

        result = create_vector_store(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "AISec-Compliance-knowledge",
            ["file-xyz"],
        )
        assert result == "vs-existing-789"
        # sleep called once before the single GET poll
        assert mock_sleep.call_count == 1

    @patch("foundry_knowledge.requests.post")
    def test_vector_store_creation_failure(self, mock_post):
        mock_post.return_value = MagicMock(status_code=500, text="Server error")

        result = create_vector_store(
            "https://endpoint",
            "fake-token",
            "2025-05-15-preview",
            "AISec-HR-knowledge",
            ["file-abc"],
        )
        assert result is None


# ── Upload Knowledge Base ─────────────────────────────────────────────────────


class TestUploadKnowledgeBase:
    @patch("foundry_knowledge.find_vector_store_by_name")
    @patch("foundry_knowledge.create_vector_store")
    @patch("foundry_knowledge.upload_file")
    @patch("foundry_knowledge.os.path.exists")
    @patch("foundry_knowledge.DefaultAzureCredential")
    def test_full_upload_flow(self, mock_cred, mock_exists, mock_upload, mock_vs, mock_find, base_config):
        mock_cred.return_value.get_token.return_value = MagicMock(token="fake-token")
        mock_exists.return_value = True
        mock_upload.side_effect = ["file-id-1", "file-id-2"]
        mock_vs.return_value = "vs-hr-new123"
        mock_find.return_value = None

        result = upload_knowledge_base(base_config)

        assert result == {"vectorStores": {"HR-Helpdesk": "vs-hr-new123"}}
        assert mock_upload.call_count == 2
        mock_vs.assert_called_once()
        # Verify the vector store was created with both file IDs
        call_args = mock_vs.call_args
        assert call_args[0][3] == "AISec-HR-Helpdesk-knowledge"
        assert call_args[0][4] == ["file-id-1", "file-id-2"]

    @patch("foundry_knowledge.find_vector_store_by_name")
    @patch("foundry_knowledge.os.path.exists")
    @patch("foundry_knowledge.DefaultAzureCredential")
    def test_missing_docs_skipped(self, mock_cred, mock_exists, mock_find, base_config, caplog):
        mock_cred.return_value.get_token.return_value = MagicMock(token="fake-token")
        mock_exists.return_value = False
        mock_find.return_value = None

        result = upload_knowledge_base(base_config)

        assert result == {"vectorStores": {}}
        assert "HR-Helpdesk" not in result["vectorStores"]


# ── Cleanup Knowledge Base ────────────────────────────────────────────────────


class TestCleanupKnowledgeBase:
    @patch("foundry_knowledge.requests.delete")
    @patch("foundry_knowledge.DefaultAzureCredential")
    def test_deletes_vector_stores(self, mock_cred, mock_delete, cleanup_config):
        mock_cred.return_value.get_token.return_value = MagicMock(token="fake-token")
        mock_delete.return_value = MagicMock(status_code=204)

        result = cleanup_knowledge_base(cleanup_config)

        assert set(result["deletedVectorStores"]) == {"HR-Helpdesk", "Compliance"}
        assert mock_delete.call_count == 2

    @patch("foundry_knowledge.requests.delete")
    @patch("foundry_knowledge.DefaultAzureCredential")
    def test_delete_failure_excluded_from_result(self, mock_cred, mock_delete, cleanup_config):
        mock_cred.return_value.get_token.return_value = MagicMock(token="fake-token")
        # First delete succeeds, second fails
        mock_delete.side_effect = [
            MagicMock(status_code=204),
            MagicMock(status_code=404, text="Not found"),
        ]

        result = cleanup_knowledge_base(cleanup_config)

        assert len(result["deletedVectorStores"]) == 1

    @patch("foundry_knowledge.DefaultAzureCredential")
    def test_empty_vector_stores(self, mock_cred):
        mock_cred.return_value.get_token.return_value = MagicMock(token="fake-token")
        config = {
            "projectEndpoint": "https://endpoint",
            "agentApiVersion": "2025-05-15-preview",
            "vectorStores": {},
        }
        result = cleanup_knowledge_base(config)
        assert result == {"deletedVectorStores": []}
