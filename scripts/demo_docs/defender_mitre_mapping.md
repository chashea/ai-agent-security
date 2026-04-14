# Defender to MITRE ATT&CK Mapping

Guide for mapping Defender XDR detections and hunting queries to the MITRE ATT&CK for Enterprise framework.

## MITRE ATT&CK tactics (in attack order)

1. **Reconnaissance (TA0043)** — Gathering info before the attack
2. **Resource Development (TA0042)** — Building infrastructure
3. **Initial Access (TA0001)** — Getting a foothold
4. **Execution (TA0002)** — Running malicious code
5. **Persistence (TA0003)** — Surviving reboot / logout
6. **Privilege Escalation (TA0004)** — Getting higher permissions
7. **Defense Evasion (TA0005)** — Avoiding detection
8. **Credential Access (TA0006)** — Stealing creds
9. **Discovery (TA0007)** — Learning the environment
10. **Lateral Movement (TA0008)** — Moving to other hosts
11. **Collection (TA0009)** — Gathering data
12. **Command and Control (TA0011)** — Talking to a C2 server
13. **Exfiltration (TA0010)** — Stealing data out
14. **Impact (TA0040)** — Destroying, disrupting, encrypting

## Common techniques in Defender coverage

| Technique | ID | Defender coverage |
|---|---|---|
| Phishing: Spearphishing Link | T1566.002 | Defender for Office 365 — SafeLinks, SafeAttachments |
| Valid Accounts: Cloud Accounts | T1078.004 | Defender for Identity, Entra risk detection |
| PowerShell | T1059.001 | Defender for Endpoint — AMSI + script block logging |
| Command-Line Interface | T1059.003 | Defender for Endpoint — process telemetry |
| Credential Dumping: LSASS Memory | T1003.001 | Defender for Endpoint — ASR rule + detection |
| OS Credential Dumping: NTDS | T1003.003 | Defender for Identity |
| Scheduled Task/Job | T1053.005 | Defender for Endpoint |
| Account Manipulation | T1098 | Defender for Identity — anomalous role grant |
| Impair Defenses: Disable Antivirus | T1562.001 | Defender for Endpoint — tamper protection |
| Remote Services: RDP | T1021.001 | Defender for Identity, MDE network detection |
| Exfiltration Over Web Service | T1567 | Defender for Cloud Apps, MDE network events |

## Tagging detections

When Defender fires an alert, the `MitreTechniques` field on `AlertInfo` / `SecurityAlert` contains the attack technique IDs. In KQL:

```kql
AlertInfo
| where TimeGenerated > ago(7d)
| mv-expand Techniques = split(tostring(AlertInfo.Techniques), ",")
| summarize Count = count() by Technique = tostring(Techniques)
| sort by Count desc
```

This gives you a per-technique frequency so you can see what the adversary is focused on.

## Coverage heat map

Build a heat map of which techniques you have detections for using the MITRE ATT&CK Navigator:

1. Export Defender + Sentinel detection rules to JSON
2. Extract the `tactics` + `techniques` fields
3. Load into Navigator as a layer
4. Red = no detections, green = > 2 detections, yellow = exactly 1

Re-run quarterly. Pick the top 3 red cells and write detections for them.

## Pivoting from technique to detection

When you observe a suspicious event, ask: **"What ATT&CK technique does this fit?"** Then check:

1. Do we have a detection for that technique? (search `DetectionRules` by tactic tag)
2. If yes, why didn't it fire on this event? (tune vs alert fatigue)
3. If no, can we write one based on this example?

## Red team + blue team alignment

Align purple-team exercises to ATT&CK techniques, not to specific tools or CVEs. The goal is behavioral coverage: can we detect the *technique* regardless of which tool an attacker uses?
