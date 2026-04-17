"""Unit tests for foundry_search_index.py."""

from unittest.mock import MagicMock, patch


from scripts.foundry_search_index import (
    _doc_id,
    _index_body,
    _read_doc,
    cleanup_search_index,
    create_or_update_index,
    embed_text,
    populate_search_index,
    upload_documents,
)


# ── Helpers ──────────────────────────────────────────────────────────────────


def test_doc_id_is_stable_and_safe():
    a = _doc_id("HR-Helpdesk", "hr_pto_policy.md")
    b = _doc_id("HR-Helpdesk", "hr_pto_policy.md")
    c = _doc_id("Finance-Analyst", "hr_pto_policy.md")
    assert a == b
    assert a != c
    assert all(ch.isalnum() or ch in "_-" for ch in a)
    assert len(a) <= 220


def test_index_body_has_required_fields():
    body = _index_body("test-index")
    assert body["name"] == "test-index"
    field_names = {f["name"] for f in body["fields"]}
    assert {"id", "title", "content", "agent_scope", "source_file", "embedding"} <= field_names
    embed = next(f for f in body["fields"] if f["name"] == "embedding")
    assert embed["dimensions"] == 1536
    assert embed["vectorSearchProfile"] == "aisec-vector-profile"
    assert body["semantic"]["defaultConfiguration"] == "aisec-semantic"
    assert body["vectorSearch"]["algorithms"][0]["kind"] == "hnsw"


def test_read_doc_uses_h1_title(tmp_path):
    p = tmp_path / "x.md"
    p.write_text("# My Title\n\nbody text\n")
    title, content = _read_doc(str(p))
    assert title == "My Title"
    assert "body text" in content


def test_read_doc_falls_back_to_filename(tmp_path):
    p = tmp_path / "no_title.md"
    p.write_text("no heading here\n")
    title, _ = _read_doc(str(p))
    assert title == "no_title"


# ── Index lifecycle ──────────────────────────────────────────────────────────


@patch("scripts.foundry_search_index._retry_request")
def test_create_or_update_index_success(mock_req):
    mock_req.return_value = MagicMock(status_code=204)
    ok = create_or_update_index("https://search.endpoint", "tok", "idx")
    assert ok is True
    args, kwargs = mock_req.call_args
    assert args[0] == "PUT"
    assert "/indexes/idx" in args[1]
    assert kwargs["json"]["name"] == "idx"


@patch("scripts.foundry_search_index._retry_request")
def test_create_or_update_index_failure(mock_req):
    mock_req.return_value = MagicMock(status_code=400, text="bad")
    assert create_or_update_index("https://search.endpoint", "tok", "idx") is False


# ── Embeddings ───────────────────────────────────────────────────────────────


@patch("scripts.foundry_search_index._retry_request")
def test_embed_text_success(mock_req):
    mock_req.return_value = MagicMock(
        status_code=200,
        json=lambda: {"data": [{"embedding": [0.1] * 1536}]},
    )
    vec = embed_text("https://oai.endpoint", "tok", "text-embedding-3-small", "2024-10-21", "hello")
    assert vec is not None
    assert len(vec) == 1536


@patch("scripts.foundry_search_index._retry_request")
def test_embed_text_wrong_dim_returns_none(mock_req):
    mock_req.return_value = MagicMock(
        status_code=200,
        json=lambda: {"data": [{"embedding": [0.1] * 256}]},
    )
    assert embed_text("https://oai.endpoint", "tok", "m", "v", "x") is None


@patch("scripts.foundry_search_index._retry_request")
def test_embed_text_http_error_returns_none(mock_req):
    mock_req.return_value = MagicMock(status_code=500, text="boom")
    assert embed_text("https://oai.endpoint", "tok", "m", "v", "x") is None


# ── Document upload ──────────────────────────────────────────────────────────


@patch("scripts.foundry_search_index._retry_request")
def test_upload_documents_batches_and_counts(mock_req):
    mock_req.return_value = MagicMock(
        status_code=200,
        json=lambda: {"value": [{"key": "a", "status": True}, {"key": "b", "status": True}]},
    )
    docs = [{"id": f"d{i}", "title": "t", "content": "c"} for i in range(2)]
    accepted = upload_documents("https://search.endpoint", "tok", "idx", docs, batch_size=50)
    assert accepted == 2


def test_upload_documents_empty_returns_zero():
    assert upload_documents("https://search.endpoint", "tok", "idx", []) == 0


# ── Top-level orchestration ──────────────────────────────────────────────────


def test_populate_skips_when_no_search_endpoint():
    result = populate_search_index({"searchEndpoint": ""})
    assert result["documentsUploaded"] == 0
    assert result["skipped"] == "no searchEndpoint"


def test_populate_skips_when_no_openai_endpoint():
    result = populate_search_index({"searchEndpoint": "https://s.search.windows.net"})
    assert result["documentsUploaded"] == 0
    assert "openaiEndpoint" in result["skipped"]


@patch("scripts.foundry_search_index.upload_documents")
@patch("scripts.foundry_search_index.embed_text")
@patch("scripts.foundry_search_index.create_or_update_index")
@patch("scripts.foundry_search_index.os.path.exists")
@patch("scripts.foundry_search_index._read_doc")
@patch("scripts.foundry_search_index.DefaultAzureCredential")
def test_populate_full_flow(
    mock_cred, mock_read, mock_exists, mock_create, mock_embed, mock_upload
):
    mock_cred.return_value.get_token.return_value = MagicMock(token="tok")
    mock_exists.return_value = True
    mock_read.return_value = ("Title", "body")
    mock_create.return_value = True
    mock_embed.return_value = [0.0] * 1536
    mock_upload.return_value = 2

    result = populate_search_index(
        {
            "searchEndpoint": "https://s.search.windows.net",
            "openaiEndpoint": "https://oai.cog.azure.com",
            "indexName": "test-idx",
            "knowledgeBase": {"HR-Helpdesk": ["a.md", "b.md"]},
        }
    )
    assert result["indexName"] == "test-idx"
    assert result["documentsUploaded"] == 2
    assert result["documentsAttempted"] == 2
    assert mock_embed.call_count == 2
    docs_arg = mock_upload.call_args[0][3]
    assert {d["agent_scope"] for d in docs_arg} == {"HR-Helpdesk"}


@patch("scripts.foundry_search_index.delete_index")
@patch("scripts.foundry_search_index.DefaultAzureCredential")
def test_cleanup_returns_index_name_on_success(mock_cred, mock_delete):
    mock_cred.return_value.get_token.return_value = MagicMock(token="tok")
    mock_delete.return_value = True
    result = cleanup_search_index(
        {"searchEndpoint": "https://s.search.windows.net", "indexName": "test-idx"}
    )
    assert result["deletedIndex"] == "test-idx"


def test_cleanup_skips_without_endpoint():
    result = cleanup_search_index({})
    assert result["deletedIndex"] is None
    assert result["skipped"] == "no searchEndpoint"
