# KQL Patterns for Application Insights

Query patterns for Azure Application Insights telemetry. Use from the Logs blade on any App Insights or Log Analytics workspace connected to an instrumented app.

## Core tables

| Table | Purpose |
|---|---|
| `requests` | Incoming HTTP/gRPC requests |
| `dependencies` | Outbound calls (HTTP, SQL, blob, service bus) |
| `exceptions` | Unhandled errors with stack traces |
| `traces` | Log messages (`logger.info`, `console.log`) |
| `customEvents` | `TrackEvent` instrumentation |
| `customMetrics` | `TrackMetric` instrumentation |
| `pageViews` | Client-side page loads (JS SDK) |
| `availabilityResults` | Availability tests (ping, standard) |

## Pattern 1 — Error rate by endpoint

```kql
requests
| where timestamp > ago(1h)
| summarize
    Total = count(),
    Failed = countif(success == false),
    P95 = percentile(duration, 95)
  by name
| extend ErrorRate = round(100.0 * Failed / Total, 2)
| where Total > 10
| sort by ErrorRate desc
```

## Pattern 2 — Dependency latency by target

```kql
dependencies
| where timestamp > ago(24h)
| where type in ("Http", "Azure blob", "SQL")
| summarize
    Count = count(),
    P50 = percentile(duration, 50),
    P95 = percentile(duration, 95),
    P99 = percentile(duration, 99)
  by target, type
| sort by P95 desc
```

## Pattern 3 — Exception clustering

```kql
exceptions
| where timestamp > ago(1d)
| summarize Count = count() by problemId, type, outerMessage
| sort by Count desc
| take 20
```

`problemId` is a stable hash of the stack trace, so grouping by it collapses instances of the same bug.

## Pattern 4 — User funnel

```kql
let start = customEvents | where timestamp > ago(7d) and name == "cart:add" | project user=tostring(customDimensions.userId), t1=timestamp;
let mid   = customEvents | where timestamp > ago(7d) and name == "cart:checkout" | project user=tostring(customDimensions.userId), t2=timestamp;
let end   = customEvents | where timestamp > ago(7d) and name == "order:placed" | project user=tostring(customDimensions.userId), t3=timestamp;
start
| join kind=leftouter mid on user
| join kind=leftouter end on user
| summarize
    AddedToCart = dcount(user),
    CheckedOut = dcountif(user, isnotempty(t2)),
    Purchased = dcountif(user, isnotempty(t3))
```

## Pattern 5 — Request trace correlation

```kql
let failedRequests = requests
  | where timestamp > ago(1h)
  | where success == false
  | project operation_Id, name, resultCode;
failedRequests
| join kind=inner (traces | where timestamp > ago(1h)) on operation_Id
| project timestamp, name, resultCode, severityLevel, message
| sort by timestamp desc
```

## Live metrics vs Logs

- **Live Metrics** — real-time, ~1s latency, limited history; use for active incident watch
- **Logs** — ingestion delay ~30–60s, full history, supports joins; use for hunting + post-mortem

## Sampling

Telemetry is sampled by default (1–100%). Use `sum()` on `itemCount` instead of `count()` when you need absolute numbers:

```kql
requests
| summarize Count = sum(itemCount) by name
```
