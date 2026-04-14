#!/usr/bin/env python3
"""Foundry knowledge base — vector store creation and demo document upload.

Creates per-agent vector stores, uploads demo documents from scripts/demo_docs/,
and returns vector store IDs for injection into file_search tool definitions.

Usage:
    python3.12 foundry_knowledge.py --action upload --config input.json
    python3.12 foundry_knowledge.py --action cleanup --config input.json
"""

import argparse
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


def _retry_request(
    method: str,
    url: str,
    max_attempts: int = 10,
    base_delay: float = 3.0,
    **kwargs,
) -> requests.Response:
    """requests.{method} with retry on SSL / timeout / 5xx errors.

    Freshly-created Foundry accounts on ``services.ai.azure.com`` can return
    transient SSL EOF errors and connection timeouts for 2-5 minutes after
    provisioning. This wrapper retries those transport-class failures with
    exponential backoff. Non-retriable errors (4xx, auth) raise immediately.
    """
    method_func = getattr(requests, method.lower())
    last_exc: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            resp = method_func(url, **kwargs)
            if 500 <= resp.status_code < 600 and attempt < max_attempts:
                log.warning(
                    "HTTP %d on %s %s (attempt %d/%d) — retrying",
                    resp.status_code,
                    method,
                    url,
                    attempt,
                    max_attempts,
                )
                time.sleep(base_delay * attempt)
                continue
            return resp
        except (
            requests.exceptions.SSLError,
            requests.exceptions.ConnectionError,
            requests.exceptions.Timeout,
            requests.exceptions.ChunkedEncodingError,
        ) as exc:
            last_exc = exc
            if attempt < max_attempts:
                delay = base_delay * attempt
                log.warning(
                    "Transient transport error on %s %s (attempt %d/%d): %s — "
                    "retrying in %.1fs",
                    method,
                    url,
                    attempt,
                    max_attempts,
                    type(exc).__name__,
                    delay,
                )
                time.sleep(delay)
                continue
            break
    if last_exc is not None:
        raise last_exc
    raise RuntimeError(f"Exhausted {max_attempts} retries on {method} {url}")


def _get_token(credential: DefaultAzureCredential, scope: str) -> str:
    return credential.get_token(scope).token


def _data_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


# ── File Upload ──────────────────────────────────────────────────────────────


def upload_file(
    project_endpoint: str, data_token: str, api_version: str, file_path: str
) -> str | None:
    """Upload a file to the Foundry project. Returns file ID or None.

    Reads the file content into memory before the request so the retry
    wrapper can re-send the same bytes on a transient SSL failure. The
    previous implementation passed an open file handle inside a `with`
    block, which worked on the first attempt but sent 0 bytes on every
    retry because the stream was already at EOF — Foundry rejected with
    HTTP 400 "File is empty." even though the file was non-empty on disk.
    """
    url = f"{project_endpoint}/files?api-version={api_version}"
    headers = {"Authorization": f"Bearer {data_token}"}

    filename = os.path.basename(file_path)
    with open(file_path, "rb") as f:
        file_bytes = f.read()

    files = {"file": (filename, file_bytes, "application/octet-stream")}
    data = {"purpose": "assistants"}
    try:
        resp = _retry_request("POST", url, headers=headers, files=files, data=data)
    except Exception as exc:
        # Transient transport errors exhausted the retry budget. Return None
        # so the caller treats this file as skipped rather than propagating
        # to sys.exit(1). One flaky upload should not abort the whole
        # knowledge-base step — other agents still deserve their vector
        # stores.
        log.warning("File upload exhausted retries for '%s': %s — skipping", filename, exc)
        return None

    if resp.status_code < 400:
        file_id = resp.json().get("id", "")
        log.info("Uploaded file: %s -> %s", filename, file_id)
        return file_id

    log.warning("File upload failed for '%s' (HTTP %d): %s", filename, resp.status_code, resp.text)
    return None


# ── Vector Store ─────────────────────────────────────────────────────────────


def create_vector_store(
    project_endpoint: str,
    data_token: str,
    api_version: str,
    name: str,
    file_ids: list[str],
) -> str | None:
    """Create a vector store with the given files. Returns vector store ID or None."""
    url = f"{project_endpoint}/vector_stores?api-version={api_version}"
    body = {"name": name, "file_ids": file_ids}
    try:
        resp = _retry_request("POST", url, json=body, headers=_data_headers(data_token))
    except Exception as exc:
        log.warning("Vector store creation exhausted retries for '%s': %s — skipping", name, exc)
        return None

    if resp.status_code < 400:
        vs = resp.json()
        vs_id = vs.get("id", "")
        log.info("Created vector store: %s -> %s", name, vs_id)

        # Wait for vector store to be ready (files need indexing). Poll
        # failures are non-fatal — return the vs_id after the retry budget
        # so the caller can still wire the tool up; Foundry will finish
        # indexing in the background and the agent will see the vectors
        # when it actually queries file_search.
        status_url = f"{project_endpoint}/vector_stores/{vs_id}?api-version={api_version}"
        for attempt in range(30):
            time.sleep(2)
            try:
                status_resp = _retry_request("GET", status_url, headers=_data_headers(data_token))
            except Exception as exc:
                log.warning("Vector store status poll exhausted retries for '%s': %s — returning ID anyway", name, exc)
                return vs_id
            if status_resp.status_code == 200:
                status = status_resp.json().get("status", "")
                if status == "completed":
                    log.info("Vector store ready: %s (%s)", name, vs_id)
                    return vs_id
                if status == "failed":
                    log.warning("Vector store indexing failed: %s", name)
                    return vs_id  # Return ID anyway for cleanup
                log.info("Vector store indexing: %s (attempt %d/30, status: %s)", name, attempt + 1, status)
        log.warning("Vector store indexing timed out: %s", name)
        return vs_id

    log.warning("Vector store creation failed for '%s' (HTTP %d): %s", name, resp.status_code, resp.text)
    return None


def delete_vector_store(
    project_endpoint: str, data_token: str, api_version: str, vs_id: str
) -> bool:
    """Delete a vector store by ID."""
    url = f"{project_endpoint}/vector_stores/{vs_id}?api-version={api_version}"
    resp = _retry_request("DELETE", url, headers=_data_headers(data_token))
    if resp.status_code < 400:
        log.info("Deleted vector store: %s", vs_id)
        return True
    log.warning("Vector store delete failed for '%s' (HTTP %d): %s", vs_id, resp.status_code, resp.text)
    return False


# ── Knowledge Base Upload ────────────────────────────────────────────────────


def upload_knowledge_base(config: dict) -> dict:
    """Upload demo docs per agent, create vector stores. Returns vector store IDs."""
    credential = DefaultAzureCredential()
    data_token = _get_token(credential, "https://ai.azure.com/.default")

    project_endpoint = config["projectEndpoint"]
    api_version = config.get("agentApiVersion", "2025-05-15-preview")
    knowledge_base = config.get("knowledgeBase", {})
    prefix = config.get("prefix", "AISec")

    # Resolve demo docs directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    docs_dir = os.path.join(script_dir, "demo_docs")

    vector_stores = {}

    for agent_name, doc_files in knowledge_base.items():
        log.info("Uploading knowledge base for agent: %s", agent_name)

        # Upload each document
        file_ids = []
        for doc_file in doc_files:
            doc_path = os.path.join(docs_dir, doc_file)
            if not os.path.exists(doc_path):
                log.warning("Demo doc not found: %s", doc_path)
                continue
            file_id = upload_file(project_endpoint, data_token, api_version, doc_path)
            if file_id:
                file_ids.append(file_id)

        if not file_ids:
            log.warning("No files uploaded for agent: %s", agent_name)
            continue

        # Create vector store
        vs_name = f"{prefix}-{agent_name}-knowledge"
        vs_id = create_vector_store(
            project_endpoint, data_token, api_version, vs_name, file_ids
        )
        if vs_id:
            vector_stores[agent_name] = vs_id

    return {"vectorStores": vector_stores}


def cleanup_knowledge_base(config: dict) -> dict:
    """Delete vector stores from manifest."""
    credential = DefaultAzureCredential()
    data_token = _get_token(credential, "https://ai.azure.com/.default")

    project_endpoint = config["projectEndpoint"]
    api_version = config.get("agentApiVersion", "2025-05-15-preview")
    vector_stores = config.get("vectorStores", {})

    deleted = []
    for agent_name, vs_id in vector_stores.items():
        if delete_vector_store(project_endpoint, data_token, api_version, vs_id):
            deleted.append(agent_name)

    return {"deletedVectorStores": deleted}


# ── CLI ──────────────────────────────────────────────────────────────────────


def main() -> None:
    parser = argparse.ArgumentParser(description="Foundry knowledge base operations")
    parser.add_argument(
        "--action",
        required=True,
        choices=["upload", "cleanup"],
        help="Action to perform",
    )
    parser.add_argument("--config", required=True, help="Path to JSON config file")
    args = parser.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)

    if args.action == "upload":
        result = upload_knowledge_base(config)
    else:
        result = cleanup_knowledge_base(config)

    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log.error("Fatal error: %s", exc)
        sys.exit(1)
