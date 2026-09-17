"""Dagster GraphQL from inside the webserver container: no Cloudflare Access hop and no token.

    ssh muffin 'docker exec -i $(docker ps -qf name=muffin_dagster-webserver) python - <command> …' \
      < dagster_gql.py

Commands (arguments are plain tokens, so they survive the ssh single quotes):
    repos
    backfill        --assets a,b --partitions 2026-09-11,2026-09-12 --reason <tag> [--dry-run]
    materialize     --assets a --reason <tag> [--dry-run]      unpartitioned assets, one run
    backfill-status --id <backfillId>
"""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request

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
    args = parser.parse_args()

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


if __name__ == "__main__":
    main()
