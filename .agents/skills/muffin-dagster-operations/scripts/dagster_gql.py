"""Dagster GraphQL from inside the webserver container: no Cloudflare Access hop and no token.

    ssh muffin 'docker exec -i $(docker ps -qf name=muffin_dagster-webserver) python - <command> …' \
      < dagster_gql.py

Commands (arguments are plain tokens, so they survive the ssh single quotes):
    repos
    backfill        --assets a,b --partitions 2026-09-11,2026-09-12 --reason <tag>
                    [--exclude first..last]
                    [--op-config op.key=value,…] [--dry-run]
                    `--partitions grid:security` names every key of that dynamic grid (one
                    argument cannot carry twelve thousand ids)
                    every run of the backfill gets the op config: a stage-2 replay over files on disk
                    is `--op-config sec_filer_facts.reparse=true`, without which a filer whose raw
                    was fetched by another run is skipped as unchanged
    materialize     --assets a --reason <tag> [--checks a:check,…] [--dry-run]
                    unpartitioned assets, one run. An asset's checks run ONLY when named in
                    --checks: the launch sends an explicit check selection, and an empty one means
                    none (a run on 2026-10-03 materialized `security_listing` without its check).
    job             --name <job> --partitions <key>,<key> --reason <tag> [--max-runtime S]
                    [--op-config op.key=value,…] [--dry-run]
                    the real job, one partition a run. A GraphQL launch does NOT receive the job's
                    `run_tags` (only scheduler-created runs do), so pass --max-runtime.
    backfill-status --id <backfillId>
    schedule-dry-run --schedule <name> --at 2026-09-26T00:00:00      read-only: what a tick would ask
    sensor-dry-run   --sensor <name> [--cursor <value>]               read-only: what a tick would ask
                    with no --cursor it evaluates a FIRST tick, which is what starting a
                    stopped sensor does; pass the stored cursor to see its next tick
"""

from __future__ import annotations

import argparse
import collections
import json
import urllib.error
import urllib.request
from datetime import UTC, datetime

URL = "http://127.0.0.1:3000/graphql"
LOCATION = "muffin_ingest"
REPOSITORY = "__repository__"


def gql(query: str, variables: dict | None = None) -> dict:
    request = urllib.request.Request(
        URL,
        data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # The body names the cause (a field the schema lacks, a bad variable); the status does not.
        return {"http_status": error.code, "body": error.read().decode(errors="replace")[:2000]}


def tags(
    reason: str, max_runtime: int | None = None, priority: int | None = None
) -> list[dict[str, str]]:
    # A tag on every hand-launched run, so the run list says why it exists. Without
    # `dagster/max_runtime` the run monitor allows the instance default, six hours.
    # `dagster/priority`: the queue dequeues highest first, and scheduled runs carry 0 (prices,
    # automation), 1 (companies) or 2 (FX, indices). A long backfill at -1 never delays any of them.
    out = [{"key": "muffin/reason", "value": reason}]
    if max_runtime:
        out.append({"key": "dagster/max_runtime", "value": str(max_runtime)})
    if priority is not None:
        out.append({"key": "dagster/priority", "value": str(priority)})
    return out


def partition_names(text: str, exclude: str = "") -> list[str]:
    """The keys to backfill: a comma-separated list, or `grid:<name>` for every key of a dynamic
    partition grid. Twelve thousand security ids are ~450 KB, and Linux refuses a single argument
    over 128 KB (MAX_ARG_STRLEN), so the whole grid is read from the instance here.

    `exclude` is `<first>..<last>`: the keys from first to last, in the grid's own order, are left
    out. A chunk whose run fails every time (2026-11-14: one filer's raw file OOM-killed stage 2)
    can then be held back while the rest drains. Keep the exclusion aligned to the run width, or
    every chunk after it shifts."""
    if text.startswith("grid:"):
        from dagster import DagsterInstance

        keys = list(DagsterInstance.get().get_dynamic_partitions(text.removeprefix("grid:")))
    else:
        keys = [p for p in text.split(",") if p]
    if exclude:
        first, last = exclude.split("..", 1)
        start, end = keys.index(first), keys.index(last)
        keys = keys[:start] + keys[end + 1 :]
    return keys


def op_config(text: str) -> dict:
    """`op.key=value`, comma-separated, as run config. Plain tokens, so they survive ssh quoting."""
    run_config: dict = {}
    # Split on TOP-LEVEL commas only, so a JSON value may carry its own:
    # `raw_dart_filings.reread={"00164742":["20240313001451","20260318001394"]}`.
    items, depth, start = [], 0, 0
    for n, ch in enumerate(text):
        depth += ch in "[{"
        depth -= ch in "]}"
        if ch == "," and depth == 0:
            items.append(text[start:n])
            start = n + 1
    items.append(text[start:])
    for item in [i for i in items if i]:
        path, value = item.split("=", 1)
        op, field = path.split(".", 1)
        try:
            parsed = json.loads(value)
        except json.JSONDecodeError:
            parsed = value
        run_config.setdefault("ops", {}).setdefault(op, {}).setdefault("config", {})[field] = parsed
    return run_config


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("repos")
    for name in ("backfill", "materialize"):
        p = sub.add_parser(name)
        p.add_argument("--assets", required=True)
        p.add_argument("--reason", required=True)
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--max-runtime", type=int, help="seconds; the run monitor ends the run past it")
        p.add_argument("--priority", type=int, help="dagster/priority; -1 yields to every scheduled run")
        if name == "backfill":
            p.add_argument("--partitions", required=True)
            p.add_argument("--exclude", default="", help="first..last: grid keys to leave out")
            p.add_argument("--op-config", default="", help="op.key=value,…, given to every run")
        else:
            p.add_argument("--checks", default="", help="asset:check,… to run in the same run")
    job = sub.add_parser("job")
    job.add_argument("--name", required=True, help="a job of the location, e.g. nightly_prices")
    job.add_argument("--partitions", required=True, help="comma-separated; one run each")
    job.add_argument("--reason", required=True)
    job.add_argument("--dry-run", action="store_true")
    job.add_argument("--max-runtime", type=int, help="seconds; the job's own run_tags are NOT applied")
    job.add_argument(
        "--op-config",
        default="",
        help="op.key=value,… — e.g. raw_yahoo_company.force=true; values are JSON scalars or strings",
    )
    status = sub.add_parser("backfill-status")
    status.add_argument("--id", required=True)
    dry = sub.add_parser("schedule-dry-run")
    dry.add_argument("--schedule", required=True)
    dry.add_argument("--at", required=True, help="the tick time, ISO, read as UTC")
    sensor = sub.add_parser("sensor-dry-run")
    sensor.add_argument("--sensor", required=True)
    sensor.add_argument("--cursor", help="omit to evaluate a first tick (no stored cursor)")
    args = parser.parse_args()

    if args.command == "schedule-dry-run":
        schedule_dry_run(args.schedule, args.at)
        return

    if args.command == "sensor-dry-run":
        sensor_dry_run(args.sensor, args.cursor)
        return

    if args.command == "repos":
        query = "{ repositoriesOrError { __typename ... on RepositoryConnection { nodes { name location { name } } } ... on Error { message } } }"
        print(json.dumps(gql(query), indent=1))
        return

    if args.command == "job":
        # THE REAL JOB, ONE PARTITION A RUN. Unlike `materialize` (the ad-hoc asset job, no
        # partition) and `backfill` (no checks), this runs exactly what a schedule runs: the job's
        # own assets, their checks and its `run_tags`. That is what a live tiny subset should drive.
        # A backfill would group contiguous keys into one run; a partition per run keeps each
        # subject's counters apart.
        mutation = """mutation($p: ExecutionParams!) { launchRun(executionParams: $p) {
            __typename ... on LaunchRunSuccess { run { runId status } }
            ... on RunConfigValidationInvalid { errors { message } } ... on Error { message } } }"""
        run_config = op_config(args.op_config)
        for key in [k for k in args.partitions.split(",") if k]:
            params = {
                "selector": {
                    "repositoryLocationName": LOCATION,
                    "repositoryName": REPOSITORY,
                    "jobName": args.name,
                },
                "mode": "default",
                "runConfigData": run_config,
                "executionMetadata": {
                    # The job's `run_tags` are merged only into runs a schedule or sensor creates:
                    # a launch from here without --max-runtime gets the monitor's six hours.
                    "tags": [{"key": "dagster/partition", "value": key},
                             *tags(args.reason, args.max_runtime, getattr(args, 'priority', None))]
                },
            }
            if args.dry_run:
                print(json.dumps(params, indent=1))
                continue
            print(key, json.dumps(gql(mutation, {"p": params})))
        return

    if args.command == "backfill-status":
        query = """query($id: String!) { partitionBackfillOrError(backfillId: $id) {
            __typename ... on PartitionBackfill { id status numPartitions timestamp endTimestamp }
            ... on Error { message } } }"""
        print(json.dumps(gql(query, {"id": args.id}), indent=1))
        return

    assets = [{"path": [a]} for a in args.assets.split(",") if a]
    if args.command == "backfill":
        variables = {
            "params": {
                "assetSelection": assets,
                "partitionNames": partition_names(args.partitions, args.exclude),
                "fromFailure": False,
                "title": args.reason,
                "tags": tags(args.reason, args.max_runtime, getattr(args, 'priority', None)),
                "runConfigData": op_config(args.op_config),
            }
        }
        mutation = """mutation($params: LaunchBackfillParams!) { launchPartitionBackfill(backfillParams: $params) {
            __typename ... on LaunchBackfillSuccess { backfillId } ... on Error { message } } }"""
    else:
        variables = {
            "executionParams": {
                "selector": {
                    "repositoryLocationName": LOCATION,
                    "repositoryName": REPOSITORY,
                    "jobName": "__ASSET_JOB",
                    "assetSelection": assets,
                    "assetCheckSelection": [
                        {"assetKey": {"path": [asset]}, "name": check}
                        for asset, check in (c.split(":", 1) for c in args.checks.split(",") if c)
                    ],
                },
                "mode": "default",
                "runConfigData": {},
                "executionMetadata": {"tags": tags(args.reason, args.max_runtime, getattr(args, 'priority', None))},
            }
        }
        mutation = """mutation($executionParams: ExecutionParams!) { launchRun(executionParams: $executionParams) {
            __typename ... on LaunchRunSuccess { run { runId status } }
            ... on RunConfigValidationInvalid { errors { message } } ... on Error { message } } }"""

    if args.dry_run:
        print(json.dumps(variables, indent=1))
        return
    print(json.dumps(gql(mutation, variables), indent=1))


def schedule_dry_run(schedule: str, at: str) -> None:
    """Evaluate one tick of a schedule with the DEPLOYED code, against production's run storage.

    Launches nothing. It shows what the tick will request before it fires, which is the only way to
    check a schedule that reads state (the price sweep resumes from its own previous runs) before
    the night it matters. It returns the RunRequests' own tags only: tags a job carries in its
    `run_tags` (e.g. `dagster/priority`) are merged in when the run is created and do not appear.
    """
    when = datetime.fromisoformat(at).replace(tzinfo=UTC).timestamp()
    query = """mutation($s: ScheduleSelector!, $t: Float) { scheduleDryRun(selectorData: $s, timestamp: $t) {
        __typename
        ... on DryRunInstigationTick { evaluationResult { skipReason error { message }
              runRequests { runKey jobName tags { key value } } } }
        ... on PythonError { message } ... on ScheduleNotFoundError { message } } }"""
    selector = {
        "repositoryLocationName": LOCATION,
        "repositoryName": REPOSITORY,
        "scheduleName": schedule,
    }
    result = gql(query, {"s": selector, "t": when})
    tick = (result.get("data") or {}).get("scheduleDryRun") or {}
    if tick.get("__typename") != "DryRunInstigationTick":
        print(json.dumps(result, indent=1)[:3000])
        return
    evaluation = tick["evaluationResult"]
    if evaluation.get("error") or evaluation.get("skipReason"):
        print(json.dumps(evaluation, indent=1)[:3000])
        return
    requests = evaluation["runRequests"]
    print(f"{schedule} at {at} UTC: {len(requests)} run request(s)")
    if not requests:
        return
    print(f"  run keys: {requests[0]['runKey']} .. {requests[-1]['runKey']}")
    values: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for request in requests:
        for tag in request["tags"]:
            values[tag["key"]][tag["value"]] += 1
    for key, counter in sorted(values.items()):
        shown = ", ".join(f"{v} x{n}" for v, n in counter.most_common(3))
        more = f" (+{len(counter) - 3} more)" if len(counter) > 3 else ""
        print(f"  {key}: {len(counter)} distinct — {shown}{more}")



def sensor_dry_run(sensor: str, cursor: str | None) -> None:
    """Evaluate one tick of a sensor with the DEPLOYED code, against production's instance.

    Launches nothing and stores no cursor. With no cursor it is the tick a sensor takes when it is
    started for the first time, which is the one to count before starting a stopped sensor: a
    sensor that treats "never collected" as due can request a whole grid on that tick, at whatever
    time the start happens (measured 2026-10-30 for `sec_filers_due`: 3,722 keys). Like the
    schedule dry run it shows the RunRequests' own tags, not the job's `run_tags`.
    """
    query = """mutation($s: SensorSelector!, $c: String) { sensorDryRun(selectorData: $s, cursor: $c) {
        __typename
        ... on DryRunInstigationTick { evaluationResult { skipReason cursor error { message }
              dynamicPartitionsRequests { partitionsDefName partitionKeys type }
              runRequests { runKey jobName runConfigYaml tags { key value } } } }
        ... on PythonError { message } ... on SensorNotFoundError { message }
        ... on UnauthorizedError { message } } }"""
    selector = {
        "repositoryLocationName": LOCATION,
        "repositoryName": REPOSITORY,
        "sensorName": sensor,
    }
    result = gql(query, {"s": selector, "c": cursor})
    tick = (result.get("data") or {}).get("sensorDryRun") or {}
    if tick.get("__typename") != "DryRunInstigationTick":
        print(json.dumps(result, indent=1)[:3000])
        return
    evaluation = tick["evaluationResult"]
    if evaluation.get("error"):
        print(json.dumps(evaluation["error"], indent=1)[:3000])
        return
    requests = evaluation.get("runRequests") or []
    print(f"{sensor} from cursor {cursor!r}: {len(requests)} run request(s); "
          f"next cursor {evaluation.get('cursor')!r}")
    if evaluation.get("skipReason"):
        print(f"  skip: {evaluation['skipReason']}")
    for change in evaluation.get("dynamicPartitionsRequests") or []:
        keys = change.get("partitionKeys") or []
        print(f"  {change['type']} {len(keys)} key(s) in {change['partitionsDefName']}")
    if not requests:
        return
    print(f"  run keys: {requests[0]['runKey']} .. {requests[-1]['runKey']}")
    values: dict[str, collections.Counter[str]] = collections.defaultdict(collections.Counter)
    for request in requests:
        for tag in request["tags"]:
            values[tag["key"]][tag["value"]] += 1
    for key, counter in sorted(values.items()):
        shown = ", ".join(f"{v} x{n}" for v, n in counter.most_common(3))
        more = f" (+{len(counter) - 3} more)" if len(counter) > 3 else ""
        print(f"  {key}: {len(counter)} distinct — {shown}{more}")
    # A run's config is YAML. Count its leaf entries per mapping path across the runs (for
    # `sec_filers_due`, the filers each run names as filed), without a YAML parser: the script runs
    # on whatever interpreter the container has.
    leaves: collections.Counter[str] = collections.Counter()
    for request in requests:
        stack: list[tuple[int, str]] = []
        for line in request["runConfigYaml"].splitlines():
            text = line.strip()
            if not text or text.startswith("-"):
                continue
            indent = len(line) - len(line.lstrip())
            key, _, value = text.partition(":")
            while stack and stack[-1][0] >= indent:
                stack.pop()
            if value.strip() and value.strip() != "{}":
                leaves[".".join(k for _, k in stack)] += 1
            stack.append((indent, key.strip("'\"")))
    for path, n in sorted(leaves.items()):
        print(f"  config {path}: {n} entr{'y' if n == 1 else 'ies'}")


if __name__ == "__main__":
    main()
