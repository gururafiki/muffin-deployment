#!/usr/bin/env python3
"""Do two databases hold the same rows? Table by table, across `market`, `api` and `ingest`.

Used twice by `quality.yml`'s migrations job:

  --values  The legacy reference against a database built from the baseline alone. The baseline
            carries the rows the 204 retired migrations seeded, and this asserts it carries them
            EXACTLY: every value of every seeded row, except the few a migration took from the clock
            or from a random id (`VOLATILE`).

  --counts  The reference against a database rebuilt from the repo — a new cluster, the roles from
            `app-roles.sql`, then `supabase db push`. Both have since run the same migrations, which
            write their own clock values, so this compares how many rows each table holds rather
            than what they say; `--values` has already proven the rows the baseline starts from.

  --roles   Also compare the named roles' login, BYPASSRLS, settings and memberships. Roles are
            cluster-wide, so no schema dump can see them.

Exits non-zero on any difference, naming the table, and the columns where the counts agree.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from collections import Counter

SCHEMAS = ("market", "api", "ingest")

#: VALUES THAT DIFFER BETWEEN TWO BUILDS OF THE SAME MIGRATIONS, because a migration wrote the clock
#: (`now()`, `current_date`) or a random id (`gen_random_uuid()`). Measured 2026-10-06 by comparing
#: the full dumps of two CI builds eight days apart (2026-09-26 and 2026-10-04): of the 2,557 seeded
#: rows in 86 tables, every other value was identical. The legacy set is frozen, so this list cannot
#: grow; any other difference is reported by name.
#:
#: Excluding `taxonomy_node.node_id` and `segment_concept.node_id` together does leave one thing
#: unchecked: WHICH node a concept points at. Both ids are random per build, so no value comparison
#: could check it.
VOLATILE: dict[str, set[str]] = {
    "market.cron_cursor": {"advanced_at"},
    "market.dart_discovery_cursor": {"updated_at"},
    "market.earnings_history_cursor": {"updated_at", "walked_to"},
    "market.one_shot": {"applied_at"},
    "market.segment_concept": {"node_id"},
    "market.segment_member": {"as_of"},
    "market.segment_member_class": {"as_of"},
    "market.taxonomy_node": {"node_id"},
    "market.tracked_fund": {"added_at", "retired_at"},
}

#: How many differing rows to print per table. Enough to see the shape of a difference without
#: burying the next table's.
SHOW = 3


def psql(dsn: str, sql: str) -> str:
    out = subprocess.run(
        ["psql", dsn, "-X", "-q", "-tA", "-v", "ON_ERROR_STOP=1", "-c", sql],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        raise SystemExit(f"psql failed against {dsn}:\n{out.stderr.strip()}")
    return out.stdout


def tables(dsn: str) -> list[str]:
    """Top-level tables only: a partitioned parent already returns its partitions' rows."""
    schemas = ", ".join(f"'{s}'" for s in SCHEMAS)
    rows = psql(
        dsn,
        "select n.nspname || '.' || c.relname from pg_class c "
        "join pg_namespace n on n.oid = c.relnamespace "
        f"where c.relkind in ('r', 'p') and not c.relispartition and n.nspname in ({schemas}) "
        "order by 1",
    )
    return [r for r in rows.splitlines() if r]


def columns(dsn: str, table: str) -> list[str]:
    rows = psql(
        dsn,
        "select attname from pg_attribute "
        f"where attrelid = '{table}'::regclass and attnum > 0 and not attisdropped "
        "order by attnum",
    )
    return [r for r in rows.splitlines() if r]


def rows_of(dsn: str, table: str, cols: list[str]) -> list[str]:
    """Every row as text, in a total order, so two builds compare line for line.

    CAST TO TEXT IN THE SELECT, so every type orders (json does not) and both sides render values
    the same way whatever the client.
    """
    select = ", ".join(f'"{c}"::text' for c in cols)
    order = ", ".join(str(i) for i in range(1, len(cols) + 1))
    out = psql(dsn, f"copy (select {select} from {table} order by {order}) to stdout")
    return out.splitlines()


def count(dsn: str, table: str) -> int:
    return int(psql(dsn, f"select count(*) from {table}").strip())


def role_facts(dsn: str, role: str) -> str:
    out = psql(
        dsn,
        "select r.rolcanlogin, r.rolbypassrls, r.rolinherit, "
        "coalesce((select string_agg(s, ',' order by s) from pg_db_role_setting d, "
        "unnest(d.setconfig) s where d.setrole = r.oid and d.setdatabase = 0), ''), "
        "coalesce((select string_agg(m.rolname, ',' order by m.rolname) from pg_auth_members am "
        "join pg_roles m on m.oid = am.roleid where am.member = r.oid), '') "
        f"from pg_roles r where r.rolname = '{role}'",
    ).strip()
    return out or "<missing>"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--a", required=True, help="the reference, as a libpq DSN")
    parser.add_argument("--b", required=True, help="the database compared with it")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--values", action="store_true")
    mode.add_argument("--counts", action="store_true")
    parser.add_argument("--roles", default="", help="comma-separated roles to compare")
    args = parser.parse_args()

    problems: list[str] = []
    in_a, in_b = tables(args.a), tables(args.b)
    for t in sorted(set(in_a) ^ set(in_b)):
        problems.append(f"{t} exists only in {'the reference' if t in in_a else 'the other'}")
    shared = [t for t in in_a if t in set(in_b)]

    rows_compared = 0
    for t in shared:
        if args.counts:
            na, nb = count(args.a, t), count(args.b, t)
            rows_compared += na
            if na != nb:
                problems.append(f"{t}: {na} rows in the reference, {nb} in the other")
            continue
        cols = [c for c in columns(args.a, t) if c not in VOLATILE.get(t, set())]
        if cols != [c for c in columns(args.b, t) if c not in VOLATILE.get(t, set())]:
            problems.append(f"{t}: the columns differ")
            continue
        ra, rb = rows_of(args.a, t, cols), rows_of(args.b, t, cols)
        rows_compared += len(ra)
        if ra == rb:
            continue
        only_a, only_b = Counter(ra) - Counter(rb), Counter(rb) - Counter(ra)
        lines = [f"{t}: {len(ra)} rows in the reference, {len(rb)} in the other"]
        lines += [f"    only in the reference: {r[:200]}" for r in list(only_a)[:SHOW]]
        lines += [f"    only in the other:     {r[:200]}" for r in list(only_b)[:SHOW]]
        if len(ra) == len(rb):
            differing = {
                cols[i]
                for x, y in zip(ra, rb, strict=True)
                for i, (u, v) in enumerate(zip(x.split("\t"), y.split("\t"), strict=False))
                if u != v
            }
            lines.append(f"    differing columns: {', '.join(sorted(differing))}")
        problems.append("\n".join(lines))

    for role in [r for r in args.roles.split(",") if r]:
        fa, fb = role_facts(args.a, role), role_facts(args.b, role)
        if fa != fb:
            problems.append(f"role {role}: {fa} in the reference, {fb} in the other")

    what = "row counts" if args.counts else "values"
    if problems:
        for p in problems:
            print(f"::error::{p.splitlines()[0]}")
            print(p)
        return 1
    print(f"  ok  {len(shared)} tables agree on {what} ({rows_compared} rows in the reference)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
