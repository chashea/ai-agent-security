# KQL Cheat Sheet

Reference for common Kusto Query Language (KQL) operators and patterns used in Azure Log Analytics, Microsoft Sentinel, and Application Insights.

## Filtering

```kql
SecurityEvent
| where TimeGenerated > ago(1h)
| where EventID == 4625
| where AccountType == "User"
```

- `where` — predicate filter; chains top-to-bottom
- `ago(1h)`, `ago(7d)` — relative time
- `between (datetime(...) .. datetime(...))` — absolute range
- `in (...)` / `!in (...)` — set membership
- `has` / `contains` / `startswith` — string match (use `has` when possible — indexed)

## Projection

```kql
SigninLogs
| project TimeGenerated, UserPrincipalName, IPAddress, ResultType
| project-rename Signin=TimeGenerated
| extend Country = tostring(LocationDetails.countryOrRegion)
```

- `project` — select columns
- `project-away` — drop columns
- `project-rename` — rename columns
- `extend` — add a computed column

## Aggregation

```kql
SecurityEvent
| where EventID == 4625
| summarize Failed=count() by Account, bin(TimeGenerated, 1h)
| top 10 by Failed
```

- `summarize` — group + aggregate
- `count()`, `countif(predicate)`, `sum()`, `avg()`, `dcount()` (distinct)
- `bin(col, interval)` — time bucketing
- `top N by col` — ranked N

## Joining

```kql
SigninLogs
| where TimeGenerated > ago(1d)
| join kind=inner (
    AuditLogs
    | where TimeGenerated > ago(1d)
    | where OperationName == "Update user"
  ) on $left.UserPrincipalName == $right.TargetResources[0].userPrincipalName
```

- `join kind=inner|leftouter|rightouter|fullouter|leftanti|rightanti`
- Prefer pre-filtering each side before the join
- Use `$left.col == $right.col` for explicit column mapping

## Time-series

```kql
requests
| where timestamp > ago(24h)
| summarize Count=count() by bin(timestamp, 5m), name
| render timechart
```

- `render` — auto-visualize (timechart, piechart, columnchart)
- `make-series` — continuous time series with gap-filling
- `series_decompose_anomalies(series)` — anomaly detection

## Discovery

```kql
SigninLogs
| getschema
```

- `getschema` — list columns and types
- `search "value"` — full-text across tables (expensive, prefer `where`)
- `search in (Table1, Table2) "value"` — scoped search

## Style tips

1. Put the cheapest filter first (`where TimeGenerated > ago(...)` before text searches).
2. Use `has` instead of `contains` when matching whole tokens — it's indexed.
3. Save intermediate sets with `let`: `let topUsers = SigninLogs | summarize by User | take 10;`
4. `limit`/`take` after `order by` to get a top-N by ranking.
