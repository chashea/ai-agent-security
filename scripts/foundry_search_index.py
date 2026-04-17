#!/usr/bin/env python3
"""Foundry Azure AI Search index — create, populate, cleanup.

Builds the shared ``aisec-compliance-index`` that the ``azure_ai_search`` tool
on every business-domain agent (HR, Finance, IT, Kusto, Entra, Defender)
points at. Without this module, the AI Search tool resolves to a non-existent
index and queries fail silently.

Index design:
    Hybrid (keyword + vector) + semantic ranker, with per-agent filtering via
    the ``agent_scope`` field. Documents are the same markdown corpus that
    file_search ingests (``scripts/demo_docs/``) so demos can compare the two
    knowledge surfaces side-by-side.

Fields:
    id            string,  key, retrievable
    title         string,  searchable, retrievable
    content       string,  searchable, retrievable
    agent_scope   string,  filterable, facetable, retrievable
    source_file   string,  filterable, retrievable
    embedding     Collection(Edm.Single), vector(1536), retrievable=false

Vectors come from the Foundry Azure OpenAI ``text-embedding-3-small``
deployment (1536 dims) that ``FoundryInfra.psm1`` provisions on every deploy.

Usage::

    python3.12 foundry_search_index.py --action populate --config input.json
    python3.12 foundry_search_index.py --action cleanup  --config input.json

Input JSON contract::

    {
      "searchEndpoint":   "https://<service>.search.windows.net",
      "indexName":        "aisec-compliance-index",
      "openaiEndpoint":   "https://<account>.openai.azure.com",
      "embeddingsModel":  "text-embedding-3-small",
      "embeddingsApiVersion": "2024-10-21",
      "knowledgeBase": {
        "<agent_name>": ["<file1.md>", "<file2.md>", ...],
        ...
      }
    }

The script is idempotent: it (re)creates the index definition each run (Search
accepts updates that don't change key/vector dimensions) and upserts documents
by id (``<agent_scope>__<source_file_basename>``).
"""

import argparse
import hashlib
import json
import logging
import os
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

DEMO_DOCS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "demo_docs")
SEARCH_API_VERSION = "2024-07-01"
EMBED_DIM = 1536  # text-embedding-3-small


# ── Token / retry helpers ────────────────────────────────────────────────────


def _get_token(credential: DefaultAzureCredential, scope: str) -> str:
    return credential.get_token(scope).token


def _retry_request(
    method: str,
    url: str,
    max_attempts: int = 8,
    base_delay: float = 2.0,
    **kwargs,
) -> requests.Response:
    """HTTP with retry on transport errors and 5xx responses.

    Search returns 503 during index recreation; embeddings can return 429.
    Both are transient. 4xx (other than 429) raises immediately.
    """
    kwargs.setdefault("timeout", 30)
    method_func = getattr(requests, method.lower())
    for attempt in range(1, max_attempts + 1):
        try:
            resp = method_func(url, **kwargs)
            retriable = resp.status_code in (429,) or 500 <= resp.status_code < 600
            if retriable and attempt < max_attempts:
                delay = base_delay * attempt
                log.warning(
                    "HTTP %d on %s %s (attempt %d/%d) — retrying in %.1fs",
                    resp.status_code,
                    method,
                    url.split("?")[0],
                    attempt,
                    max_attempts,
                    delay,
                )
                time.sleep(delay)
                continue
            return resp
        except (
            requests.exceptions.SSLError,
            requests.exceptions.ConnectionError,
            requests.exceptions.Timeout,
            requests.exceptions.ChunkedEncodingError,
        ) as exc:
            if attempt >= max_attempts:
                raise
            delay = base_delay * attempt
            log.warning(
                "Transient %s on %s %s (attempt %d/%d) — retrying in %.1fs",
                type(exc).__name__,
                method,
                url.split("?")[0],
                attempt,
                max_attempts,
                delay,
            )
            time.sleep(delay)
    raise RuntimeError(f"Exhausted retries for {method} {url}")


# ── Index definition ─────────────────────────────────────────────────────────


def _index_body(name: str) -> dict:
    return {
        "name": name,
        "fields": [
            {"name": "id", "type": "Edm.String", "key": True, "filterable": True, "retrievable": True},
            {"name": "title", "type": "Edm.String", "searchable": True, "retrievable": True},
            {"name": "content", "type": "Edm.String", "searchable": True, "retrievable": True, "analyzer": "en.microsoft"},
            {"name": "agent_scope", "type": "Edm.String", "filterable": True, "facetable": True, "retrievable": True},
            {"name": "source_file", "type": "Edm.String", "filterable": True, "retrievable": True},
            {
                "name": "embedding",
                "type": "Collection(Edm.Single)",
                "searchable": True,
                "retrievable": False,
                "dimensions": EMBED_DIM,
                "vectorSearchProfile": "aisec-vector-profile",
            },
        ],
        "vectorSearch": {
            "algorithms": [
                {
                    "name": "aisec-hnsw",
                    "kind": "hnsw",
                    "hnswParameters": {"m": 4, "efConstruction": 400, "efSearch": 500, "metric": "cosine"},
                }
            ],
            "profiles": [{"name": "aisec-vector-profile", "algorithm": "aisec-hnsw"}],
        },
        "semantic": {
            "defaultConfiguration": "aisec-semantic",
            "configurations": [
                {
                    "name": "aisec-semantic",
                    "prioritizedFields": {
                        "titleField": {"fieldName": "title"},
                        "prioritizedContentFields": [{"fieldName": "content"}],
                        "prioritizedKeywordsFields": [{"fieldName": "agent_scope"}],
                    },
                }
            ],
        },
    }


def create_or_update_index(search_endpoint: str, mgmt_token: str, name: str) -> bool:
    """PUT the index definition. Returns True on success."""
    url = f"{search_endpoint}/indexes/{name}?api-version={SEARCH_API_VERSION}"
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {mgmt_token}"}
    body = _index_body(name)
    resp = _retry_request("PUT", url, json=body, headers=headers)
    if resp.status_code < 400:
        log.info("Index '%s' created/updated.", name)
        return True
    log.error("Index PUT failed (HTTP %d): %s", resp.status_code, resp.text[:500])
    return False


def delete_index(search_endpoint: str, mgmt_token: str, name: str) -> bool:
    url = f"{search_endpoint}/indexes/{name}?api-version={SEARCH_API_VERSION}"
    headers = {"Authorization": f"Bearer {mgmt_token}"}
    resp = _retry_request("DELETE", url, headers=headers)
    if resp.status_code in (204, 404):
        log.info("Index '%s' deleted (or did not exist).", name)
        return True
    log.warning("Index DELETE returned HTTP %d: %s", resp.status_code, resp.text[:200])
    return False


# ── Embeddings (Azure OpenAI) ────────────────────────────────────────────────


def embed_text(
    openai_endpoint: str,
    openai_token: str,
    deployment: str,
    api_version: str,
    text: str,
) -> list[float] | None:
    url = f"{openai_endpoint}/openai/deployments/{deployment}/embeddings?api-version={api_version}"
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {openai_token}"}
    body = {"input": text}
    try:
        resp = _retry_request("POST", url, json=body, headers=headers)
    except Exception as exc:
        log.warning("Embedding call exhausted retries: %s", exc)
        return None
    if resp.status_code >= 400:
        log.warning("Embeddings HTTP %d: %s", resp.status_code, resp.text[:200])
        return None
    data = resp.json().get("data", [])
    if not data:
        return None
    vec = data[0].get("embedding")
    if not isinstance(vec, list) or len(vec) != EMBED_DIM:
        log.warning("Embedding had unexpected shape (len=%s).", len(vec) if isinstance(vec, list) else "n/a")
        return None
    return vec


# ── Document upload ──────────────────────────────────────────────────────────


def _doc_id(agent_scope: str, source_file: str) -> str:
    """Stable, Search-safe key (alnum + `_`/`-`/`=`) derived from scope + file."""
    raw = f"{agent_scope}__{source_file}"
    digest = hashlib.sha1(raw.encode("utf-8")).hexdigest()[:12]
    safe = "".join(c if c.isalnum() else "_" for c in raw)[:200]
    return f"{safe}_{digest}"


def _read_doc(path: str) -> tuple[str, str]:
    """Return (title, content). Title = first markdown H1 or filename stem."""
    with open(path, encoding="utf-8") as f:
        text = f.read()
    title = os.path.splitext(os.path.basename(path))[0]
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("# "):
            title = s.lstrip("# ").strip() or title
            break
    return title, text


def upload_documents(
    search_endpoint: str,
    mgmt_token: str,
    index_name: str,
    docs: list[dict],
    batch_size: int = 50,
) -> int:
    """Upsert documents in batches. Returns count of accepted docs."""
    if not docs:
        return 0
    url = f"{search_endpoint}/indexes/{index_name}/docs/index?api-version={SEARCH_API_VERSION}"
    headers = {"Content-Type": "application/json", "Authorization": f"Bearer {mgmt_token}"}
    accepted = 0
    for i in range(0, len(docs), batch_size):
        batch = docs[i : i + batch_size]
        body = {"value": [{**d, "@search.action": "mergeOrUpload"} for d in batch]}
        resp = _retry_request("POST", url, json=body, headers=headers)
        if resp.status_code >= 400:
            log.warning(
                "Document batch %d-%d failed (HTTP %d): %s",
                i,
                i + len(batch),
                resp.status_code,
                resp.text[:300],
            )
            continue
        for r in resp.json().get("value", []):
            if r.get("status"):
                accepted += 1
            else:
                log.warning("Doc %s rejected: %s", r.get("key"), r.get("errorMessage"))
    return accepted


# ── Top-level orchestration ──────────────────────────────────────────────────


def populate_search_index(config: dict) -> dict:
    search_endpoint = config.get("searchEndpoint", "").rstrip("/")
    if not search_endpoint:
        log.warning("searchEndpoint missing from config — AI Search index population skipped.")
        return {"indexName": None, "documentsUploaded": 0, "skipped": "no searchEndpoint"}

    index_name = config.get("indexName") or "aisec-compliance-index"
    openai_endpoint = config.get("openaiEndpoint", "").rstrip("/")
    embeddings_model = config.get("embeddingsModel") or "text-embedding-3-small"
    embeddings_api_version = config.get("embeddingsApiVersion") or "2024-10-21"
    knowledge_base = config.get("knowledgeBase", {}) or {}

    if not openai_endpoint:
        log.warning("openaiEndpoint missing — cannot generate embeddings; skipping index.")
        return {"indexName": index_name, "documentsUploaded": 0, "skipped": "no openaiEndpoint"}

    credential = DefaultAzureCredential()
    mgmt_token = _get_token(credential, "https://search.azure.com/.default")
    openai_token = _get_token(credential, "https://cognitiveservices.azure.com/.default")

    if not create_or_update_index(search_endpoint, mgmt_token, index_name):
        return {"indexName": index_name, "documentsUploaded": 0, "skipped": "index PUT failed"}

    docs = []
    for agent_name, files in knowledge_base.items():
        for fname in files:
            path = os.path.join(DEMO_DOCS_DIR, fname)
            if not os.path.exists(path):
                log.warning("Skipping missing doc: %s", path)
                continue
            title, content = _read_doc(path)
            embedding = embed_text(
                openai_endpoint, openai_token, embeddings_model, embeddings_api_version, content
            )
            if not embedding:
                log.warning("Skipping doc due to embedding failure: %s", fname)
                continue
            docs.append(
                {
                    "id": _doc_id(agent_name, fname),
                    "title": title,
                    "content": content,
                    "agent_scope": agent_name,
                    "source_file": fname,
                    "embedding": embedding,
                }
            )

    accepted = upload_documents(search_endpoint, mgmt_token, index_name, docs)
    log.info("Uploaded %d/%d documents to index '%s'.", accepted, len(docs), index_name)
    return {"indexName": index_name, "documentsUploaded": accepted, "documentsAttempted": len(docs)}


def cleanup_search_index(config: dict) -> dict:
    search_endpoint = config.get("searchEndpoint", "").rstrip("/")
    index_name = config.get("indexName") or "aisec-compliance-index"
    if not search_endpoint:
        return {"deletedIndex": None, "skipped": "no searchEndpoint"}
    credential = DefaultAzureCredential()
    mgmt_token = _get_token(credential, "https://search.azure.com/.default")
    deleted = delete_index(search_endpoint, mgmt_token, index_name)
    return {"deletedIndex": index_name if deleted else None}


# ── CLI ──────────────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="Foundry AI Search index operations")
    parser.add_argument("--action", required=True, choices=["populate", "cleanup"])
    parser.add_argument("--config", required=True, help="Path to JSON config file")
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    if args.action == "populate":
        result = populate_search_index(config)
    else:
        result = cleanup_search_index(config)

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log.error("Fatal error: %s", exc)
        sys.exit(1)
