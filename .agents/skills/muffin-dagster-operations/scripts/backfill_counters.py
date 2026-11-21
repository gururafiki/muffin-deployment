"""Sum one backfill's run statuses and every numeric materialization counter, per asset.

Run inside the webserver container: `ssh muffin "docker exec -i $(docker ps -qf name=muffin_dagster-webserver) python - <backfillId>" < backfill_counters.py`.
Each run's counters are counted once per asset (a range run reports one materialization per
partition, carrying the run's sums), so the totals are the backfill's, not partition x run.
"""
import sys
from collections import Counter
from dagster import DagsterInstance, DagsterEventType
from dagster._core.storage.dagster_run import RunsFilter
bf = sys.argv[1]
inst = DagsterInstance.get()
runs = inst.get_runs(RunsFilter(tags={"dagster/backfill": bf}))
status = Counter(r.status.value for r in runs)
sums = {}
for r in runs:
    seen = set()
    for rec in inst.all_logs(r.run_id, of_type=DagsterEventType.ASSET_MATERIALIZATION):
        m = rec.dagster_event.event_specific_data.materialization
        if m.asset_key in seen:
            continue
        seen.add(m.asset_key)
        c = sums.setdefault(m.asset_key.to_user_string(), Counter())
        for k, v in m.metadata.items():
            if isinstance(v.value, (int, float)) and not isinstance(v.value, bool):
                c[k] += v.value
print(dict(status))
for a, c in sums.items():
    print(a, dict(sorted(c.items())))
