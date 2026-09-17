---
name: muffin-dagster-operations
description:
  Use when operating the deployed Dagster ingestion — checking last night's runs, finding why a run
  failed or an automation condition never fired, reading what a partition actually wrote, launching
  a backfill or a one-off materialisation, or recovering after an outage or a roll.
license: GPL-3.0
metadata:
  author: muffin
  version: '1.0.0'
---

# Operate the deployed Dagster

All reads go through the node (`muffin-reach-deployed-services`): the `dagster` database on
`supabase-db`, and GraphQL from inside `muffin_dagster-webserver`. The scripts sit beside this file.
**A run that SUCCEEDED proves nothing about its data. Read the counters and the tables.**

| Thing | Where |
|---|---|
| Services | `muffin_dagster-webserver`, `muffin_dagster-daemon`, `muffin_muffin-ingest` (code location; runs are its child processes) |
| Run storage | database `dagster`: `runs`, `run_tags`, `event_logs`, `asset_daemon_asset_evaluations`, `job_ticks`, `instigators` |
| Raw Parquet | `/var/lib/muffin-ingest/raw/<asset>/<partition>.parquet` in the `muffin_muffin-ingest` container |
| Instance config | `muffin-deployment/stack/dagster/dagster.yaml`: `max_concurrent_runs: 3`, pools `default_limit: 1`, `granularity: run` |
| Nightly schedules (UTC) | `daily_fx`, `daily_indices`, `daily_prices` at 00:00 (serialised by the `sql` pool); `ledger_heartbeat` at :07 hourly; pruning at 03:40 |

## Last night, in order

1. **Runs and waits.** `wait_s` far above a few seconds means queued behind a pool.
   ```sql
   select left(run_id, 8) run, pipeline_name job, status, backfill_id,
          to_char(create_timestamp, 'MM-DD HH24:MI:SS') created,
          round((start_time - extract(epoch from create_timestamp))::numeric) wait_s,
          round((end_time - start_time)::numeric) run_s
   from runs where create_timestamp > now() - interval '1 day' order by create_timestamp;
   ```
   `start_time`/`end_time` are epoch floats. `create_timestamp` is UTC without a zone.
2. **What each run wrote:** `scripts/run_events.py` (its docstring has the query). **Sum the outcome
   counters against `subjects`.** A gap is a branch that failed to count: on 2026-09-17 the 09-16
   price partition read `answered=5974 empty=586 unasked=0` of 12,017.
3. **Count the tables per date.** In a `single_run` range, every partition carries the RUN's
   metadata, so a day with no rows reads the same as its neighbours.
   ```sql
   select trade_date, count(*) from market.price_bar where trade_date >= current_date - 7 group by 1 order by 1;
   select as_of, count(*) from market.fx_rate where as_of >= current_date - 7 group by 1 order by 1;
   select as_of, count(*) from market.index_return group by 1 order by 1;
   select as_of, count(*) from market.security_return group by 1 order by 1;
   ```
   Expect ~11.6k price bars on a weekday, ~41 FX rates, 549 index rows plus 77 sector rows, and
   `security_return` at the newest trading day. (Until
   `docs/deferred/2026-09-17-security-return-never-auto-materialises.md` closes, that last one needs a
   hand-run.)

## Why a run failed

`scripts/run_events.py` over the run's `STEP_FAILURE` and `ENGINE_EVENT` rows. The exception is in
`event_specific_data.error`. A run that died before any step (for example, importing definitions)
has it on an `ENGINE_EVENT`. `user_message` and the `PIPELINE_FAILURE` event carry no reason.

## Why an automation condition did not fire

The daemon stores an evaluation whenever the result changes:
- `asset_daemon_asset_evaluations`, keyed `asset_key = '["<asset>"]'`, with `num_requested`.
- Print the tree with `scripts/evaluation_tree.py`; the false branch is the reason. For
  `security_return` it was `any_deps_missing: true` (one `price_bar` day and unfilled history keys).
- Sensor ticks: `job_ticks` joined to `instigators` where `instigator_body like '%<sensor>%'`.
  `SKIPPED` every 30 s is a healthy sensor with nothing to do.

## Launch

`scripts/dagster_gql.py`, run inside the webserver container. `--dry-run` prints the variables.

```bash
G='docker exec -i $(docker ps -qf name=muffin_dagster-webserver) python -'
ssh muffin "$G backfill --assets raw_price_bars,price_bar --partitions 2026-09-11,2026-09-12 --reason recovery-<date>" < scripts/dagster_gql.py
ssh muffin "$G materialize --assets security_return --reason <why>" < scripts/dagster_gql.py
ssh muffin "$G backfill-status --id <backfillId>" < scripts/dagster_gql.py
```

- **Name every missing partition.** One day left outside a backfill range kept an `eager()` asset
  blocked.
- **Prefer one multi-day price run over several one-day runs.** Its calls are slower, and yfinance
  limits per minute. One observation each: a four-day backfill at ~14 calls/min passed, and a one-day
  night run at ~42 calls/min was refused.
- **Order by run length.** Every stage-2 asset and the heartbeat hold the `sql` pool for the whole
  run, so launch the short lanes (FX ~25 s, indices ~20 s) before prices (~43 min for four days). The
  hourly heartbeat queues behind a long run; that is expected, not a dead daemon.
- **Do not roll while a long run is in flight.** The roll kills it (`muffin-deploy`).
- **A lane fetched through http-cache** (FX spot) can receive the previous day's body. Check
  `docker service logs muffin_http-cache --since 1h` for `STALE`, and check the table, not the run.

## Replay stage 2 on the stored files

No provider call. It reproduces exactly what a partition's rule saw:

```bash
ssh muffin 'docker exec -i $(docker ps -qf name=muffin_muffin-ingest) python -' <<'PY'
import pyarrow.parquet as pq
rows = pq.read_table("/var/lib/muffin-ingest/raw/raw_index_bars/2026-09-16.parquet").to_pylist()
# …then call the library rule (muffin_ingest.derive.returns, muffin_ingest.facets.prices) on them
PY
```

This is how the NaN close on 2026-09-16 was found: 60 of 61 series ended on a bar whose
`close` was `nan`.
