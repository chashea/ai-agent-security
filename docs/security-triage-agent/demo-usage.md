# Security-Triage demo — Defender alerts → Foundry agent

End-to-end demo that fetches recent Defender XDR alerts via Microsoft Graph
and pipes each one to the deployed Security-Triage Foundry agent, capturing
the agent's triage response per alert.

## Prerequisites

- A completed `Deploy.ps1 -ConfigPath config.json` run — produces a
  `manifests/AISec_<timestamp>.json` that lists the Security-Triage agent
  and the project endpoint.
- `az login` pointed at the tenant / subscription that owns the agent.
  The demo uses `DefaultAzureCredential`, which follows the az CLI
  context.
- Python 3.12 + `scripts/requirements.txt` installed.
- Graph read access for the signed-in identity:
  - `SecurityAlert.Read.All`
  - `SecurityIncident.Read.All`

## Usage

```bash
# Default: last 60 minutes, triage the top 3 alerts by severity
python3.12 scripts/demo_security_triage.py

# Wider window, more alerts
python3.12 scripts/demo_security_triage.py --since-minutes 240 --top 5

# Pin to a specific manifest (useful for reproducing a past run)
python3.12 scripts/demo_security_triage.py \
  --manifest manifests/AISec_20260417-125451768.json
```

## What it does

1. Locates the latest `manifests/*.json` (or the one passed via `--manifest`).
2. Extracts the `projectEndpoint` and the agent whose name contains
   `Security-Triage`.
3. Calls `fetch_defender_alerts.fetch_alerts()` against Microsoft Graph.
4. Ranks alerts by severity (high first, then newest-within-severity) and
   keeps the top-N.
5. For each alert, creates a transient Foundry thread, posts a structured
   prompt, polls the run until terminal status, retrieves the assistant
   response, and deletes the thread.
6. Writes a combined report to `logs/security-triage-demo-<UTC>.json`
   containing `{alert, run_status, duration_ms, assistant_response}` per
   alert, plus a compact summary to stdout.

## Output shape

```json
{
  "generatedAt": "2026-04-17T12:34:56Z",
  "manifest": "manifests/AISec_20260417-125451768.json",
  "agent": {"id": "AISec-Security-Triage", "name": "AISec-Security-Triage"},
  "window": {"sinceMinutes": 60, "selected": 3, "fetched": 12},
  "results": [
    {
      "alert": { /* full Graph alert object */ },
      "run_status": "completed",
      "duration_ms": 4210,
      "assistant_response": "…",
      "error": null
    }
  ]
}
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `HTTP 401 wrong issuer` from Foundry | `az account set --subscription <id>` — `DefaultAzureCredential` follows az CLI. |
| `HTTP 403` from Graph | The signed-in identity lacks `SecurityAlert.Read.All` + `SecurityIncident.Read.All`. Grant in Entra or sign in as a Security Reader. |
| `No agent matching 'Security-Triage'` | The Security-Triage agent is not in the manifest — re-run `Deploy.ps1` or check `config.json` has it enabled. |
| `run_status: failed` in report | The agent's OpenAPI tool call probably rejected; check the agent's managed identity has Graph Security read permissions (see `docs/security-triage-agent/security-triage-agent-prompt.md`). |

## See also

- [`security-triage-agent-prompt.md`](security-triage-agent-prompt.md) — production system prompt
- [`security-triage-mvp-prompt.md`](security-triage-mvp-prompt.md) — MVP prompt with test cases
- [`graph-security-mvp.yaml`](graph-security-mvp.yaml) — OpenAPI schema the agent uses
- [`../post-deploy-steps.md`](../post-deploy-steps.md) — deployment checklist
