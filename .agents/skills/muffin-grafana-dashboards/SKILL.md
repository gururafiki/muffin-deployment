---
name: muffin-grafana-dashboards
description:
  Use when adding or changing a muffin Grafana dashboard, panel or alert rule, deciding which
  dashboard a new table, lane, provider or metric belongs on, or when a panel shows "No Data", a
  number that looks wrong, or a datasource form asks to configure its database.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Grafana dashboards

Everything is provisioned from `stack/observability/grafana/` and ships by `deploy.yml`. An edit made
in the UI is lost on the next restart, and every deploy restarts Grafana. **Extend a dashboard before
adding one.**

## What lives where

| File (uid) | Shows | Reads |
|---|---|---|
| `dashboards/pipeline.json` (`muffin-pipeline`) | edge-function backlogs, run outcomes, throttling, pg_cron, drain rate | `refresh_run`, `backlog_sample`, `backlog_drain`, `universe_sample` |
| `dashboards/coverage.json` (`muffin-coverage`) | facet completeness by country, sector, type, tier, cap, style… | `coverage_sample` |
| `dashboards/universe.json` (`muffin-universe`) | securities, identifiers, negative caches, rows and storage by table | `universe_sample`, `ticker_disagreement` |
| `dashboards/providers.json` (`muffin-providers`) | http-cache hits, latency, bytes; egress by host and container | Prometheus |
| `dashboards/segments.json` (`muffin-segments`) | business-line parsing, curation queue, reconciliation | `security_segment_spine`, `security_filing`, `pending_*_segments` (live), `refresh_run` |
| `dashboards/node.json` (`muffin-node`) | memory, CPU and disk per service; Traefik requests | Prometheus |
| `provisioning/datasources/muffin.yml` | `muffin-prometheus`; `muffin-postgres` (db `postgres`) and `muffin-dagster` (db `dagster`), both as `metrics_ro` | |
| `provisioning/alerting/rules.yml` | 12 alert rules | |

**No panel reads Dagster yet.** Runs, queue waits and asset counters for the ingestion lanes have no
dashboard. The `muffin-dagster` datasource exists for them, and they extend `pipeline.json`.

## Which dashboard a change touches

| Change | Update |
|---|---|
| A new ingestion lane, resource or backlog | `pipeline.json`, and a stalled/flat alert in `rules.yml` |
| A new facet or coverage dimension | `coverage.json` — every panel that enumerates facets ("Every facet…", "Country × facet", "Sector × facet") |
| A new `market` table | `universe.json` rows and storage (sampled by `sample_universe`) |
| A new provider or cache location | `providers.json`; label the location with an explicit `$provider`, never `$proxy_host` |
| A new collector metric | the panel that plots it; CI fails on a metric nothing plots |

## Rules that each cost an incident

- **Read samples, not live `pending_*` views.** Counting all backlogs takes ~8 s against the database
  the app reads, repeated on every 5-minute refresh. `segments.json` still reads four
  `pending_*_segments` views live; time one as `metrics_ro` before copying that pattern.
- **A series sampled a few times a day** needs `"showPoints": "always"` and a current-value panel beside
  it. A line of one point is invisible.
- **Never filter away the state a panel exists to reveal.** No `limit N` on a bounded set, and no
  `> 0` on a count, which hides a resource that stopped. If a floor is wanted, make it a variable
  (`$minsize`).
- **One alias per output column in each `UNION` arm.** A duplicate renders "No Data" and nothing reports
  it.
- **A datasource's database name goes in `jsonData.database`.** The top-level key still connects, but
  the form renders empty, and saving it breaks every panel.
- **An alert query with `relativeTimeRange {from: 0, to: 0}` stops Grafana from starting.**
- **`universe_sample` writes one sweep under two timestamps.** Never pin to `max(sampled_at)` over the
  whole table.
- **"No Data" right after a deploy** is the restart: check the task's `StartedAt`, then hard-refresh.

## Verify a panel

1. **CI** (`quality.yml`): `check_dashboards_can_render.py`, `check_collector_metrics_are_plotted.py`,
   and the `jsonData` guard.
2. **Replay its query on the node as the datasource role.** Substitute the macros first:
   `$__timeFilter(col)` → `col > now() - interval '7 days'`, plus `$country`/`$sector` → a value.
   ```bash
   ssh muffin 'docker exec -i $(docker ps -qf name=muffin_supabase-db) psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1' <<'SQL'
   set statement_timeout = 20000;
   set role metrics_ro;
   <panel SQL>;
   SQL
   ```
   (`postgres` cannot `set role`; `supabase_admin` can.)
3. **Or through Grafana**, which expands macros itself: `POST https://muffin-grafana.rafiki.guru/api/ds/query`
   with the Access token headers and Grafana basic auth (`muffin-reach-deployed-services`), body
   `{"queries":[{"refId":"A","datasource":<panel's datasource>,"rawSql":<rawSql>,"format":<format>}],"from":"now-7d","to":"now"}`.
   On 2026-09-17, both routes returned the same 168 rows for *Total work outstanding*.
4. After the deploy, open the dashboard and read the panel. A number that exists is not a number
   that is right; compare it with the replay.
