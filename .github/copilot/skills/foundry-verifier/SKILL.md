---
name: foundry-verifier
description: Verify Foundry agent tool definitions match config.json after a deploy. Queries the data plane for each agent, dumps its tool list, and diffs against the intended config. Read-only by default — reports mismatches, does not fix them. WHEN: "check the agents", "are the agents configured right", "verify tools", "did the deploy work", agent tool drift is suspected, or after any deploy that touches scripts/foundry_tools.py, scripts/foundry_agents.py, modules/Foundry.psm1, or config.json agents[].tools.
---

# Foundry Agent Tool Verifier

You verify that Foundry agents in the `aisec-project` Foundry project have the
tools their `config.json` says they should have. You are read-only by default —
report mismatches, do not fix them. Fixes belong to a separate deploy.

## When to run

- After any deploy that touches `scripts/foundry_tools.py`, `scripts/foundry_agents.py`, `modules/Foundry.psm1`, or `config.json` → `workloads.foundry.agents[].tools`.
- When the user says "check the agents" / "are the agents configured right" / "verify tools" / "did the deploy work".
- When a user reports an agent behaving unexpectedly — drift is a common root cause.

## What to check

For each agent in `config.json` → `workloads.foundry.agents[]`:

1. **Existence** — the agent must resolve at `https://<account>.services.ai.azure.com/api/projects/<project>/agents/<prefix-name>?api-version=2025-05-15-preview`. 404 is a hard failure.
2. **Tool count** — `versions.latest.definition.tools.length` should match the config's `tools[]` length, minus any intentional skips:
   - `sharepoint_grounding` skipped when `connections.sharePoint.siteUrl` is empty
   - `bing_grounding` skipped when `connections.bingSearch` has no connection
   - `a2a` skipped — currently disabled in `foundry_tools.py` pending schema fix
3. **Per-tool integrity** (most common failure modes):
   - `file_search` — `vector_store_ids` must be non-empty
   - `azure_ai_search` — `azure_ai_search.indexes[0].project_connection_id` must be non-empty (empty string = misconfigured)
   - `function` — flat shape: `{type, name, description, parameters}` with `name` set
   - `azure_function` — `azure_function.function.name` set, input/output bindings populated
   - `openapi` — `openapi.spec.paths` must be a nested object tree, NOT a string containing `@{...}` (that's the PowerShell hashtable `.ToString()` leak from insufficient `ConvertTo-Json -Depth`)
   - `mcp` — `server_label` and `server_url` set
   - `a2a_preview` — if present, flag it (the tool should be absent until the schema fix lands)

## How to run

Load the Foundry context from the config:

- Config: `config.json` → `workloads.foundry.subscriptionId`, `resourceGroup`, `accountName`, `projectName`, `prefix`

Then run this verification script (or an equivalent Python block) with the data plane token:

```bash
export TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
python3.12 - <<'PY'
import json, os, time, urllib.request

base = 'https://aisec-foundry.services.ai.azure.com/api/projects/aisec-project/agents'
token = os.environ['TOKEN']

def get(url):
    for i in range(6):
        try:
            req = urllib.request.Request(url, headers={'Authorization': f'Bearer {token}'})
            return json.loads(urllib.request.urlopen(req, timeout=30).read())
        except Exception:
            if i == 5: raise
            time.sleep(2**i)

with open('config.json') as f:
    cfg = json.load(f)
prefix = cfg['prefix']
expected = {f"{prefix}-{a['name']}": a for a in cfg['workloads']['foundry']['agents']}

for full_name, agent_cfg in expected.items():
    try:
        d = get(f"{base}/{full_name}?api-version=2025-05-15-preview")
    except Exception:
        print(f"MISSING: {full_name}")
        continue
    tools = d['versions']['latest']['definition'].get('tools', [])
    print(f"\n{full_name}: {len(tools)} tools deployed, {len(agent_cfg['tools'])} in config")
    for t in tools:
        tt = t.get('type')
        issue = None
        if tt == 'azure_ai_search':
            conn = t.get('azure_ai_search',{}).get('indexes',[{}])[0].get('project_connection_id')
            if not conn: issue = 'empty project_connection_id'
        elif tt == 'openapi':
            spec = t.get('openapi',{}).get('spec',{})
            if isinstance(spec, str) and '@{' in spec:
                issue = 'stringified spec (ConvertTo-Json depth leak)'
        elif tt == 'a2a_preview':
            issue = 'a2a_preview present but should be skipped'
        mark = f"  !! {issue}" if issue else ""
        print(f"  - {tt}{mark}")
PY
```

## Output format

Return a short report, not a wall of JSON:

```
verify-summary:
  agents_expected: 4
  agents_found: 4
  drift_detected: yes | no
  issues:
    - AISec-IT-Support azure_ai_search: empty project_connection_id
    - AISec-Finance-Analyst: missing `azure_function` tool
```

If drift is detected, point at the likely culprit in the repo:
- Empty connection IDs → `scripts/foundry_tools.py build_tool_definitions` connection_ids plumbing
- Stringified OpenAPI → `modules/Foundry.psm1` `Invoke-FoundryPython` JsonDepth
- Missing tools on rerun → `scripts/foundry_agents.py create_agent` delete-then-create path
- a2a_preview present → check `foundry_tools.py a2a` branch wasn't re-enabled

## Non-goals

- Do not fix drift. Report it. The user runs `Deploy.ps1` to apply corrections.
- Do not touch any other project. This skill is specific to ai-agent-security.
- Do not attempt to connect Graph or enumerate bot apps — that's out of scope.
