# KQL Hunting Patterns for Microsoft Sentinel

Query patterns for threat hunting in Microsoft Sentinel. Tables referenced here are the canonical Sentinel connectors — verify the exact column layout in your workspace with `getschema`.

## Common tables

| Table | Source | Typical fields |
|---|---|---|
| `SecurityEvent` | Windows Security log (MMA/AMA) | EventID, Account, Computer, LogonType |
| `SigninLogs` | Entra sign-in events | UserPrincipalName, IPAddress, ResultType, LocationDetails |
| `AuditLogs` | Entra directory audit | OperationName, InitiatedBy, TargetResources |
| `DeviceProcessEvents` | Defender for Endpoint | DeviceName, ProcessCommandLine, InitiatingProcessFileName |
| `DeviceNetworkEvents` | Defender for Endpoint | RemoteIP, RemoteUrl, RemotePort |
| `CloudAppEvents` | Defender for Cloud Apps | Application, ActionType, IPAddress |

## Pattern 1 — Impossible travel

```kql
let timeframe = 1d;
SigninLogs
| where TimeGenerated > ago(timeframe)
| where ResultType == 0
| project TimeGenerated, UserPrincipalName, IPAddress, Country=tostring(LocationDetails.countryOrRegion)
| sort by UserPrincipalName asc, TimeGenerated asc
| extend PrevTime = prev(TimeGenerated), PrevCountry = prev(Country), PrevUser = prev(UserPrincipalName)
| where UserPrincipalName == PrevUser and Country != PrevCountry
| extend MinutesBetween = datetime_diff('minute', TimeGenerated, PrevTime)
| where MinutesBetween < 60
```

## Pattern 2 — Password spray

```kql
SigninLogs
| where TimeGenerated > ago(1h)
| where ResultType in (50053, 50126, 50055)
| summarize DistinctUsers = dcount(UserPrincipalName), FailedAttempts = count() by IPAddress
| where DistinctUsers > 10 and FailedAttempts > 50
| sort by DistinctUsers desc
```

## Pattern 3 — Suspicious process chain

```kql
DeviceProcessEvents
| where TimeGenerated > ago(24h)
| where InitiatingProcessFileName has_any ("winword.exe", "excel.exe", "outlook.exe")
| where FileName has_any ("powershell.exe", "cmd.exe", "wscript.exe", "mshta.exe")
| project Timestamp, DeviceName, InitiatingProcessFileName, FileName, ProcessCommandLine
| sort by Timestamp desc
```

## Pattern 4 — Privileged role grant

```kql
AuditLogs
| where TimeGenerated > ago(7d)
| where OperationName has "Add member to role"
| where Result == "success"
| extend RoleName = tostring(TargetResources[0].modifiedProperties[1].newValue)
| extend Grantee = tostring(TargetResources[0].userPrincipalName)
| where RoleName has_any ("Global Administrator", "Privileged Role Administrator", "Application Administrator")
| project TimeGenerated, OperationName, Grantee, RoleName, InitiatedBy
```

## Pattern 5 — Sign-in from Tor exit node

```kql
let torList = externaldata(IPAddress:string) ["https://check.torproject.org/torbulkexitlist"] with (format="txt");
SigninLogs
| where TimeGenerated > ago(1d)
| where ResultType == 0
| join kind=inner (torList) on IPAddress
| project TimeGenerated, UserPrincipalName, IPAddress, AppDisplayName
```

## Pivoting across tables

When you spot a suspicious `DeviceProcessEvents` row, pivot:
1. By `DeviceName` → `DeviceNetworkEvents` for outbound connections
2. By `InitiatingProcessAccountUpn` → `SigninLogs` for that user's sign-in pattern
3. By `SHA256` → `DeviceFileEvents` for file drops with the same hash

## Bookmarks

Save interesting rows as bookmarks from the Sentinel Hunting blade so a responder can pick them up. Tag consistently — `campaign:log4shell`, `mitre:T1059.001`, `severity:high`.
