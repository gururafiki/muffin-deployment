#!/usr/bin/env python3
"""Extract every view, matview and function as ONE definition each, in dependency order.

WHY THIS EXISTS. `create or replace view` can only APPEND columns — it cannot rename, reorder or
drop them — so the earliest file defining a view can never replace the latest one's shape, and the
migration set has grown to where **36 of 84 views are defined more than once**, up to TWELVE times
for `symbol_cache_classification`. Every deploy therefore re-runs all twelve, and each definer that
has to change a shape must `drop` first: a real window, on every deploy, in which a view and its
dependents do not exist. `permission denied for view pending_segments` has been observed in
`refresh_run` for exactly that reason.

The other half of the cost is silent. Migration 106 rebuilt `symbol_cache_classification` from
migration 050's nine entries and deleted the eight added since — and only a behaviour test naming
all seventeen caught it. When a view has one definition that cannot happen.

WHAT THIS IS NOT. It does not decide anything: it reads what the migrations actually produced and
writes it down. The database is the authority for its own definitions, which is what makes the
output checkable — CI applies the migrations, extracts, and fails if the committed bundle differs.
So the bundle cannot drift from the migrations while both exist.

Objects are emitted in DEPENDENCY ORDER, because a view built on another must be created after it.
The order comes from `pg_depend`, never from a hand-maintained list: migration 35 kept a list of
three dependents that was wrong within hours and broke two deploys, and was replaced by exactly
this query.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SCHEMAS = ("market", "api", "ingest")

#: One row per object: kind, schema, name, and the SQL that recreates it.
#:
#: `pg_get_viewdef(oid, true)` and `pg_get_functiondef(oid)` are the server's own rendering, so the
#: output is stable across extractions of the same schema and a diff means a real change.
OBJECTS_SQL = r"""
with recursive
-- Views and matviews, with the objects they read.
v as (
  select c.oid, n.nspname as schema, c.relname as name,
         case c.relkind when 'm' then 'matview' else 'view' end as kind
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = any(%(schemas)s) and c.relkind in ('v','m')
),
-- A view depends on another when its rewrite rule references it. `pg_depend` through `pg_rewrite`
-- is the only honest source: a matview HAS a rewrite entry too, which is why migration 13's
-- dependent-discovery loop had to learn about relkind at all.
edge as (
  select distinct r.ev_class as dependent, d.refobjid as depends_on
    from pg_depend d
    join pg_rewrite r on r.oid = d.objid
   where d.classid = 'pg_rewrite'::regclass
     and d.refclassid = 'pg_class'::regclass
     and r.ev_class <> d.refobjid
),
depth as (
  select v.oid, 0 as level from v
   where not exists (select 1 from edge e join v p on p.oid = e.depends_on where e.dependent = v.oid)
  union all
  select v.oid, d.level + 1
    from v join edge e on e.dependent = v.oid join depth d on d.oid = e.depends_on
   where d.level < 32
)
select v.kind, v.schema, v.name, coalesce(max(d.level), 0) as level, v.oid::text
  from v left join depth d on d.oid = v.oid
 group by v.kind, v.schema, v.name, v.oid
union all
-- FUNCTIONS FIRST, at level -1, and the ordering among them does not matter.
--
-- A VIEW may call a function, so functions must exist before views are created. A FUNCTION may
-- read a view, which would be the opposite constraint — except that `check_function_bodies = off`
-- (set by the applier, exactly as `pg_dump` does) means a body is parsed and not resolved. So one
-- direction is a real dependency and the other is not, and functions-first satisfies both.
--
-- The signature, not the name: `security_id uuid` and `security_id text` are different functions
-- and the oid is what tells them apart; the rendered name is for the FILENAME only.
-- THE OID, NOT THE SIGNATURE. Round-tripping `oid::regprocedure::text` back through
-- `'…'::regprocedure` fails on real signatures — `expected a right parenthesis` on
-- `market.aggregate_performance(...)` — because re-parsing a rendered signature is a quoting
-- problem with no upside. An oid is an integer and cannot be misread. The NAME is carried
-- separately, for the filename only.
select 'function', n.nspname,
       p.proname || '(' || coalesce(pg_get_function_identity_arguments(p.oid), '') || ')',
       -1, p.oid::text
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = any(%(schemas)s)
   and p.prokind = 'f'
 order by 4, 2, 3
"""


def psql(dsn: str, sql: str, *, params: dict[str, object] | None = None) -> str:
    """One query, tuples-only, through the client that is already on every runner and the node."""
    text = sql
    for key, value in (params or {}).items():
        if isinstance(value, tuple | list):
            literal = "array[" + ", ".join(f"'{v}'" for v in value) + "]"
        else:
            literal = f"'{value}'"
        text = text.replace(f"%({key})s", literal)
    out = subprocess.run(
        ["psql", dsn, "-tA", "-v", "ON_ERROR_STOP=1", "-c", text],
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        raise SystemExit(f"psql failed:\n{out.stderr.strip()}")
    return out.stdout


#: `pg_get_viewdef` IS NOT ROUND-TRIP STABLE, and exactly one construct in this schema shows it.
#:
#: A `union all` arm carrying an unaliased literal renders as `'sector'::text`. Recreating the view
#: from that text makes Postgres assign the DEFAULT alias — the type name — so it re-renders as
#: `'sector'::text AS text`, and the extraction is then different from the thing it extracted.
#: `coverage_current` does this eleven times.
#:
#: The difference is cosmetic by construction: a union's output column names come from its FIRST
#: arm, so an alias on a later arm names nothing. Stripping an alias that merely repeats its own
#: cast's type is therefore information-preserving, and it is what makes extract -> apply ->
#: extract a fixed point rather than an oscillation.
#:
#: Deliberately narrow. It does not touch `AS anything_else`, and an alias that genuinely reads
#: `AS text` was already the default it is being compared to.
_DEFAULT_ALIAS = re.compile(r"::(\w+) AS \1\b")


def _stable(sql: str) -> str:
    return _DEFAULT_ALIAS.sub(r"::\1", sql)


def definition(dsn: str, kind: str, schema: str, name: str, oid: str) -> str:
    ident = f"{schema}.{name}"
    if kind == "function":
        # `create or replace`, NOT drop-then-create. Dropping would fail for any function a view
        # depends on, and the bundle drops views AFTER this point. The ACL caveat this repo records
        # — `create or replace function` PRESERVES the existing ACL, so a grant can only ever ADD a
        # privilege — is handled by the explicit `revoke ... from public` the definitions carry,
        # not by dropping. A signature CHANGE still needs a versioned migration to drop first,
        # which is the same rule as today.
        body = psql(dsn, f"select pg_get_functiondef({oid}::oid)")
        return body.strip() + ";\n"

    body = _stable(psql(dsn, f"select pg_get_viewdef({oid}::oid, true)").strip())
    # `IF EXISTS` DOES NOT PROTECT AGAINST A RELKIND MISMATCH: `drop view if exists` on a
    # materialized view raises `"x" is not a view`, and the converse raises too — so NEITHER
    # ordering of the two is safe and the object survives both. A relkind-aware block is the only
    # form that works, and it is why two deploys died before this was understood.
    relname = name.split("(")[0]
    drop = (
        f"do $$\n"
        f"declare k char;\n"
        f"begin\n"
        f"  select c.relkind into k from pg_class c join pg_namespace n on n.oid = c.relnamespace\n"
        f"   where n.nspname = '{schema}' and c.relname = '{relname}';\n"
        f"  if k = 'm' then execute 'drop materialized view if exists {ident} cascade';\n"
        f"  elsif k = 'v' then execute 'drop view if exists {ident} cascade';\n"
        f"  end if;\n"
        f"end $$;\n"
    )
    verb = "create materialized view" if kind == "matview" else "create view"
    return f"{drop}{verb} {ident} as\n{body}\n"


#: DROPPING A MATVIEW LOSES ITS INDEXES, AND ONE OF THEM IS LOAD-BEARING.
#:
#: Caught on the run after grants: `security_facets has no UNIQUE index — refresh materialized view
#: concurrently is rejected without one, so every refresh takes ACCESS EXCLUSIVE and blocks all
#: readers`. The matview would have come back, correct and populated, with a refresh that locks the
#: thing every aggregate reads for the whole rebuild.
#:
#: Only matviews: a plain view has no indexes, and a TABLE's indexes are not this bundle's business
#: — they belong to the versioned migration that created the table.
INDEXES_SQL = r"""
select pg_get_indexdef(i.indexrelid) || ';'
  from pg_index i
  join pg_class c on c.oid = i.indrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = any(%(schemas)s) and c.relkind = 'm'
 order by 1
"""


#: DROPPING A VIEW LOSES ITS GRANTS, AND NOTHING ELSE IN THE BUNDLE WOULD PUT THEM BACK.
#:
#: Caught the first time this ran: `anon cannot read 40 serving view(s)` — the app's entire read
#: path, gone, because a recreated view carries only the owner's default ACL. `create or replace
#: function` is the opposite (it PRESERVES the ACL, which is why a grant in a re-run migration can
#: only ever ADD a privilege), so functions need nothing here and views need everything.
#:
#: Emitted from `relacl` rather than from a list of expected roles: `metrics_ro`, `service_role`,
#: `anon` and `authenticated` do not hold the same privileges on the same objects, and a list would
#: be a second copy of the truth that drifts. `aclexplode` says exactly what is there.
GRANTS_SQL = r"""
select 'grant ' || string_agg(distinct a.privilege_type, ', ' order by a.privilege_type)
       || ' on ' || n.nspname || '.' || c.relname
       || ' to ' || pg_get_userbyid(a.grantee) || ';'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  cross join lateral aclexplode(c.relacl) a
 where n.nspname = any(%(schemas)s)
   and c.relkind in ('v','m')
   and a.grantee <> c.relowner
 group by n.nspname, c.relname, a.grantee
 order by 1
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dsn", required=True)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    for stale in args.out.glob("*.sql"):
        stale.unlink()

    rows = [r for r in psql(args.dsn, OBJECTS_SQL, params={"schemas": SCHEMAS}).splitlines() if r]
    written = 0
    for position, row in enumerate(rows, start=1):
        kind, schema, name, _level, oid = row.split("|")
        # The FILENAME carries the order, so `psql -f` over a sorted glob is the whole applier and
        # there is no manifest to drift. Zero-padded to four digits because `| sort` is
        # LEXICOGRAPHIC: the moment a 100th object existed, unpadded names would sort it between
        # 02 and 29 and it would be created before what it reads. That exact defect broke a deploy.
        safe = re.sub(r"[^a-z0-9_.]+", "_", name.lower()).strip("_")
        path = args.out / f"{position:04d}-{safe}.sql"
        path.write_text(definition(args.dsn, kind, schema, name, oid))
        written += 1

    # After every matview and before the grants. `refresh … concurrently` needs the unique index,
    # and a `create index` on a relation that does not exist yet fails the whole transaction.
    indexes = [i for i in psql(args.dsn, INDEXES_SQL, params={"schemas": SCHEMAS}).splitlines() if i]
    (args.out / "9998-matview-indexes.sql").write_text(
        "-- Re-issued because DROPPING A MATVIEW LOSES ITS INDEXES. The unique one is not optional:\n"
        "-- without it `refresh materialized view concurrently` is REJECTED, and every refresh then\n"
        "-- takes ACCESS EXCLUSIVE on the relation every aggregate reads.\n"
        + "\n".join(indexes)
        + "\n"
    )

    # LAST, and by a filename that sorts after every object: a grant on a view that has not been
    # created yet fails the whole transaction. `9999-` beats any four-digit position.
    grants = [g for g in psql(args.dsn, GRANTS_SQL, params={"schemas": SCHEMAS}).splitlines() if g]
    (args.out / "9999-grants.sql").write_text(
        "-- Re-issued because DROPPING A VIEW LOSES ITS ACL. Extracted from `relacl`, so this is\n"
        "-- what the database actually grants rather than a list of what someone expected.\n"
        + "\n".join(grants)
        + "\n"
    )

    print(
        f"  ok  extracted {written} objects, {len(indexes)} matview indexes and "
        f"{len(grants)} grants into {args.out}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
