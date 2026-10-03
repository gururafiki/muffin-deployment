#!/usr/bin/env python3
"""EVERY RELATION A GRAFANA PANEL OR ALERT READS MUST BE READABLE BY THE ROLE GRAFANA USES.

Grafana queries Postgres as `metrics_ro`, a read-only role granted table by table. Measured on
2026-10-03, fifteen relations that provisioned panels and the stalled-resource alert read had never
been granted to it:

  * `market.resource_health`. The alert "A refresh resource has stopped succeeding" reads it, so
    its query failed with `permission denied` on every evaluation. With `execErrState: Alerting` that
    looks exactly like an alert firing, whether or not anything had stopped. Meanwhile
    `derive-classifications` failed every day for a week.
  * The whole Business lines dashboard (`security`, `security_segment*`, `security_filing`,
    `security_metric`, `security_industries`, the four `pending_*segments` and
    `pending_segment_alias`). Every panel errored as provisioned.
  * `ticker_disagreement`, on the Universe dashboard.

Nothing in CI could see it: the dashboards parse, the SQL is valid, and the migration tests run as a
superuser. So this runs against the database the `migrations` job has just built, and asks the
privilege question for every schema-qualified relation and function the provisioning files name.

Queries on another datasource (the Dagster one reads Dagster's own database) are skipped.
"""
from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys

import yaml

ROLE = "metrics_ro"
POSTGRES_UID = "muffin-postgres"
DASHBOARDS = "stack/observability/grafana/dashboards/*.json"
RULES = "stack/observability/grafana/provisioning/alerting/rules.yml"

RELATION = re.compile(r"\b(?:from|join)\s+((?:market|ingest)\.[a-z_0-9]+)\b(?!\s*\()", re.I)
FUNCTION = re.compile(r"\b((?:market|ingest)\.[a-z_0-9]+)\s*\(", re.I)
#: A query's comments name relations it does not read (an alert rule explains itself in prose).
COMMENT = re.compile(r"--[^\n]*|/\*.*?\*/", re.S)


def _datasource_uid(value: object) -> str | None:
    if isinstance(value, dict):
        uid = value.get("uid")
        return uid if isinstance(uid, str) else None
    return value if isinstance(value, str) else None


def queries() -> list[tuple[str, str]]:
    """(where, sql) for every Postgres query on the main datasource."""
    found: list[tuple[str, str]] = []
    for path in sorted(glob.glob(DASHBOARDS)):
        dashboard = json.load(open(path))
        title = dashboard.get("title", path)

        def walk(node: object, panel: str, inherited: str | None) -> None:
            if isinstance(node, dict):
                here = node.get("title", panel) if "targets" in node else panel
                uid = _datasource_uid(node.get("datasource")) or inherited
                sql = node.get("rawSql")
                if isinstance(sql, str) and (uid in (None, POSTGRES_UID)):
                    found.append((f"{title} / {panel}", sql))
                for value in node.values():
                    walk(value, here, uid)
            elif isinstance(node, list):
                for value in node:
                    walk(value, panel, inherited)

        walk(dashboard, "(dashboard)", None)
    rules = yaml.safe_load(open(RULES))
    for group in rules.get("groups", []):
        for rule in group.get("rules", []):
            for query in rule.get("data", []):
                sql = (query.get("model") or {}).get("rawSql")
                if isinstance(sql, str) and query.get("datasourceUid") in (None, POSTGRES_UID):
                    found.append((f"alert / {rule.get('title')}", sql))
    return found


def psql(sql: str) -> list[list[str]]:
    out = subprocess.run(
        ["psql", "-h", os.environ.get("PGHOST", "localhost"), "-U", "postgres", "-tA", "-F", "|", "-c", sql],
        check=True, capture_output=True, text=True,
    ).stdout
    return [line.split("|") for line in out.splitlines() if line]


def main() -> int:
    found = queries()
    if not found:
        print("::error::found no Grafana Postgres queries — the parser is reading nothing")
        return 1
    relations: dict[str, set[str]] = {}
    functions: dict[str, set[str]] = {}
    for where, sql in found:
        sql = COMMENT.sub(" ", sql)
        for name in RELATION.findall(sql):
            relations.setdefault(name.lower(), set()).add(where)
        for name in FUNCTION.findall(sql):
            functions.setdefault(name.lower(), set()).add(where)

    problems: list[str] = []
    for name, users in sorted(relations.items()):
        exists, granted = psql(
            f"select to_regclass('{name}') is not null, "
            f"coalesce(has_table_privilege('{ROLE}', to_regclass('{name}'), 'select'), false)"
        )[0]
        if exists != "t":
            problems.append(f"{name} does not exist, read by {', '.join(sorted(users))}")
        elif granted != "t":
            problems.append(f"{ROLE} cannot read {name}, read by {', '.join(sorted(users))}")
    for name, users in sorted(functions.items()):
        schema, proc = name.split(".", 1)
        rows = psql(
            "select coalesce(bool_or(has_function_privilege('" + ROLE + "', p.oid, 'execute')), false), count(*) "
            f"from pg_proc p join pg_namespace n on n.oid = p.pronamespace "
            f"where n.nspname = '{schema}' and p.proname = '{proc}'"
        )
        granted, count = rows[0]
        if count == "0":
            problems.append(f"{name}() does not exist, called by {', '.join(sorted(users))}")
        elif granted != "t":
            problems.append(f"{ROLE} cannot execute {name}(), called by {', '.join(sorted(users))}")

    for problem in problems:
        print(f"::error::{problem}")
    print(f"{len(found)} queries, {len(relations)} relations, {len(functions)} functions checked; "
          f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
