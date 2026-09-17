"""Print what runs wrote or why they failed, from Dagster's event log.

    ssh muffin 'docker exec $(docker ps -qf name=muffin_supabase-db) psql -U postgres -d dagster -At -F "|" \
      -c "select left(run_id, 8), dagster_event_type, asset_key, partition, event from event_logs
          where left(run_id, 8) in ('"'"'<run8>'"'"')
            and dagster_event_type in ('"'"'ASSET_MATERIALIZATION'"'"', '"'"'ASSET_CHECK_EVALUATION'"'"',
                                       '"'"'STEP_FAILURE'"'"', '"'"'ENGINE_EVENT'"'"')
          order by id" </dev/null' | python3 run_events.py

Materialization metadata is stored as `metadata_entries` of `{label, entry_data}`. An exception is
under `event_specific_data.error`, never in `user_message`. It sits on the STEP_FAILURE when a step
raised, or on an ENGINE_EVENT when the run died before any step (a definitions import error, for
example). The PIPELINE_FAILURE event itself carries no reason.
"""

import json
import sys

for line in sys.stdin:
    line = line.rstrip("\n")
    if line.count("|") < 4:
        continue
    run, kind, key, partition, raw = line.split("|", 4)
    event = json.loads(raw)
    data = (event.get("dagster_event") or {}).get("event_specific_data") or {}
    asset = key.strip('[]"') or "-"
    where = f"{run} {kind} {asset} {partition or '-'}"

    error = data.get("error")
    if error:
        message = (error.get("message") or "").strip()
        name = error.get("cls_name") or ""
        print(where, (message if message.startswith(name) else f"{name}: {message}")[:500])
        continue

    payload = data.get("materialization") or data.get("evaluation") or data
    values = []
    if "passed" in payload:
        values.append(f"passed={payload['passed']}")
    for entry in payload.get("metadata_entries") or []:
        d = entry.get("entry_data") or {}
        value = d.get("value", d.get("path", d.get("text")))
        values.append(f"{entry.get('label')}={value}")
    if values:  # engine events with neither an error nor metadata are noise here
        print(where, " ".join(values))
