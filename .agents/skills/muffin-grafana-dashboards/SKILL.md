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
| `dashboards/pipeline.json` (`muffin-pipeline`) | edge-function backlogs, run outcomes, throttling, pg_cron, drain rate; **Dagster lanes**: runs by job, failed runs, queue wait, asset checks | `refresh_run`, `backlog_sample`, `backlog_drain`, `universe_sample`; `runs`, `run_tags`, `asset_check_executions` on `muffin-dagster` |
| `dashboards/coverage.json` (`muffin-coverage`) | facet completeness by country, sector, type, tier, cap, style… | `coverage_sample` |
| `dashboards/universe.json` (`muffin-universe`) | securities, identifiers, negative caches, rows and storage by table | `universe_sample`, `ticker_disagreement` |
| `dashboards/providers.json` (`muffin-providers`) | http-cache hits, latency, bytes; egress by host and container; the ingest worker's own requests by provider and outcome, and their p95 | Prometheus (`muffin_ingest_provider_*` from the code location's exporter, job `muffin-ingest`) |
| `dashboards/segments.json` (`muffin-segments`) | business-line parsing, curation queue, reconciliation | `security_segment_spine`, `security_filing`, `pending_*_segments` (live), `refresh_run` |
| `dashboards/node.json` (`muffin-node`) | memory, CPU and disk per service; Traefik requests | Prometheus |
| `provisioning/datasources/muffin.yml` | `muffin-prometheus`; `muffin-postgres` (db `postgres`) and `muffin-dagster` (db `dagster`), both as `metrics_ro` | |
| `provisioning/alerting/rules.yml` | 16 alert rules, two on `muffin-dagster`: a failed run in the last 6 hours, and an ERROR check that failed after passing within 14 days. The certificate rule reads each name's NEWEST certificate (`max by (cn)`): Traefik keeps a gauge for a replaced one | |

**The Dagster row reads Dagster's own run storage** (since 2026-10-18), so a new job or a new asset
check appears on it by itself. The check alert fires on a REGRESSION only: a check red since it was
written (the company rotation's staleness check, until 2026-10-24) is a known state, and alerting on
it would make the rule red for a week.

## Which alerts are firing

**Read this first in any check-in.** In October, three alerts fired for four days before anyone
looked. Grafana logs every firing rule on each evaluation, so no API password is needed:

```bash
ssh muffin 'docker service logs muffin_grafana --since 30m 2>&1 | grep "Sending alerts" \
  | sed -E "s/.*rule_uid=([a-z-]+).*/\1/" | sort | uniq -c'
```

Then replay that rule's own query (see *Verify a panel*) to see what it counts, and read the rows
it counts. Two other log lines are worth knowing:
- `Failed to evaluate rule … statement timeout` at 03:00 is the nightly `pg_dump` (03:00 to
  03:04). A retry absorbs it.
- `Notify for alerts failed … i/o timeout` means an email was lost. It happened once, on
  2026-10-19.

## Which dashboard a change touches

| Change | Update |
|---|---|
| A new ingestion lane, resource or backlog | `pipeline.json`, and a stalled/flat alert in `rules.yml` |
| A new facet or coverage dimension | `coverage.json` — every panel that enumerates facets ("Every facet…", "Country × facet", "Sector × facet") |
| A new `market` table | `universe.json` rows and storage (sampled by `sample_universe`) |
| A new provider or cache location | `providers.json`; label the location with an explicit `$provider`, never `$proxy_host` |
| A new collector metric | the panel that plots it; CI fails on a metric nothing plots |
| A new metric in muffin-ingest's exporter | `EXTERNAL` in `check_collector_metrics_are_plotted.py` (this repo's CI cannot read muffin-ingest), and the panel that plots it |

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
   (`postgres` cannot `set role`; `supabase_admin` can.) A `muffin-dagster` panel reads Dagster's
   database: `-d dagster`, and its `create_timestamp` is UTC without a zone, so compare it with
   `now() at time zone 'utc'`.
3. **Or through Grafana**, which expands macros itself: `POST https://muffin-grafana.rafiki.guru/api/ds/query`
   with the Access token headers and Grafana basic auth (`muffin-reach-deployed-services`), body
   `{"queries":[{"refId":"A","datasource":<panel's datasource>,"rawSql":<rawSql>,"format":<format>}],"from":"now-7d","to":"now"}`.
   On 2026-09-17, both routes returned the same 168 rows for *Total work outstanding*.
4. After the deploy, open the dashboard and read the panel. A number that exists is not a number
   that is right; compare it with the replay.
