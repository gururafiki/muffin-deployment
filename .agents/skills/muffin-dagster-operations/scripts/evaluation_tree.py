"""Print why an automation condition did or did not fire, from one stored evaluation.

    ssh muffin 'docker exec $(docker ps -qf name=muffin_supabase-db) psql -U postgres -d dagster -At \
      -c "select asset_evaluation_body from asset_daemon_asset_evaluations
          where asset_key = '"'"'[\"<asset>\"]'"'"' order by id desc limit 1" </dev/null' \
      | python3 evaluation_tree.py

Each line is one sub-condition: its label and whether it held. For a partitioned subset it prints
the time windows or how many key ranges it covers instead of the raw subset.
"""

import datetime as dt
import json
import sys


def describe(value: object) -> str:
    if isinstance(value, bool):
        return str(value).lower()
    if not isinstance(value, dict):
        return json.dumps(value)[:80]
    if "included_time_windows" in value:
        windows = []
        for w in value["included_time_windows"]:
            start = dt.datetime.fromtimestamp(w["start"]["timestamp"], dt.timezone.utc).date()
            end = dt.datetime.fromtimestamp(w["end"]["timestamp"], dt.timezone.utc).date()
            windows.append(f"{start}..{end}")
        return f"time windows [{', '.join(windows)}]" if windows else "no time windows"
    if "key_ranges" in value:
        return f"{len(value['key_ranges'])} key range(s)" if value["key_ranges"] else "no keys"
    return json.dumps({k: v for k, v in value.items() if k != "__class__"})[:80]


def walk(node: object, depth: int = 0) -> None:
    if isinstance(node, dict):
        snapshot = node.get("condition_snapshot")
        if snapshot is not None:
            label = snapshot.get("label") or snapshot.get("class_name")
            held = describe((node.get("true_subset") or {}).get("value"))
            print(f"{'  ' * depth}- {label}: {held}")
            for child in node.get("child_evaluations", []):
                walk(child, depth + 1)
            return
        for value in node.values():
            walk(value, depth)
    elif isinstance(node, list):
        for value in node:
            walk(value, depth)


walk(json.loads(sys.stdin.read()))
