# AI Search index deploy lifecycle (post-2026-04-14)

## What was added

`scripts/foundry_search_index.py` (new) creates and populates
`aisec-compliance-index` on the lab's `aisec-search-eastus` service.
Wired into `modules/Foundry.psm1` as Step 3b between vector store
creation (Step 3) and tool definition build (Step 4). Cleanup hook
added to `Remove-Foundry`. RBAC grants for the deploying user added
to `Deploy-FoundryBicep` in `modules/FoundryInfra.psm1`.

## Index schema

- Hybrid: keyword + HNSW vector (1536-dim, `text-embedding-3-small`)
- Semantic config name: `aisec-semantic`
- Filterable field: `agent_scope` (string) — values match the agent
  shortName: HR-Helpdesk, Finance-Analyst, IT-Support, Sales-Research.
- Idempotent upload: `mergeOrUpload` on stable doc IDs derived from
  source filename + chunk index.

## Required RBAC on the search service

- `Search Service Contributor` — create / update the index
- `Search Index Data Contributor` — upload documents

Both roles are granted to the signed-in deployer
(`az ad signed-in-user show`) in `Deploy-FoundryBicep` immediately
after the eval-infra Bicep deploys. Failure to grant is a warning,
not fatal — but the populator will then fail with 403.

## Bicep changes (foundry-eval-infra.bicep)

- `authOptions: { aadOrApiKey: { aadAuthFailureMode: 'http401WithBearerChallenge' } }`
- `semanticSearch: 'standard'`

## Common failure modes (mapped to troubleshooting.md)

- Empty agent results → index doesn't exist or empty (Step 3b skipped or failed)
- 403 on /indexes → RBAC missing (re-run deploy or grant manually)
- 401 on first request → search service still in key-only auth mode (re-apply Bicep)
- Long stalls with 429s → embedding TPM quota too low (raise in Foundry portal)

## Verification commands

See `docs/post-deploy-steps.md#verification` for the facet curl and
sample semantic-ranked query. Expect 12 docs total (3 per agent_scope
× 4 agent_scopes: HR-Helpdesk, Finance-Analyst, IT-Support,
Sales-Research).

## Tests

`scripts/tests/test_foundry_search_index.py` — 16 unit tests covering
the index schema, document chunking, embedding retry on 429/5xx,
mergeOrUpload behavior, and `agent_scope` filter wiring. Mock all
HTTP. Do not let these escape to the network in CI.
