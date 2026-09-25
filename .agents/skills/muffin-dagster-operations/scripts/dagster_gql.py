"""Dagster GraphQL from inside the webserver container: no Cloudflare Access hop and no token.

    ssh muffin 'docker exec -i $(docker ps -qf name=muffin_dagster-webserver) python - <command> …' \
      < dagster_gql.py

Commands (arguments are plain tokens, so they survive the ssh single quotes):
    repos
    backfill        --assets a,b --partitions 2026-09-11,2026-09-12 --reason <tag> [--dry-run]
    materialize     --assets a --reason <tag> [--dry-run]      unpartitioned assets, one run
    backfill-status --id <backfillId>
    schedule-dry-run --schedule <name> --at 2026-09-26T00:00:00      read-only: what a tick would ask
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


def tags(reason: str) -> list[dict[str, str]]:
    # A tag on every hand-launched run, so the run list says why it exists.
    return [{"key": "muffin/reason", "value": reason}]


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("repos")
    for name in ("backfill", "materialize"):
        p = sub.add_parser(name)
        p.add_argument("--assets", required=True)
        p.add_argument("--reason", required=True)
        p.add_argument("--dry-run", action="store_true")
        if name == "backfill":
            p.add_argument("--partitions", required=True)
    status = sub.add_parser("backfill-status")
    status.add_argument("--id", required=True)
    dry = sub.add_parser("schedule-dry-run")
    dry.add_argument("--schedule", required=True)
    dry.add_argument("--at", required=True, help="the tick time, ISO, read as UTC")
    args = parser.parse_args()

    if args.command == "schedule-dry-run":
        schedule_dry_run(args.schedule, args.at)
        return

    if args.command == "repos":
        query = "{ repositoriesOrError { __typename ... on RepositoryConnection { nodes { name location { name } } } ... on Error { message } } }"
        print(json.dumps(gql(query), indent=1))
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
                "partitionNames": [p for p in args.partitions.split(",") if p],
                "fromFailure": False,
                "title": args.reason,
                "tags": tags(args.reason),
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
                    "assetCheckSelection": [],
                },
                "mode": "default",
                "runConfigData": {},
                "executionMetadata": {"tags": tags(args.reason)},
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


if __name__ == "__main__":
    main()
