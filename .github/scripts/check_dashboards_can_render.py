#!/usr/bin/env python3
"""A PANEL THAT CANNOT RENDER IS INVISIBLE, AND NOTHING REPORTS IT.

Three defects of one family, all found by a person looking at a dashboard and asking why something
was missing -- never by CI, a deploy, or a query returning an error.

  * `Sector x facet` selected `bucket as "sector"` AND `with_sector ... as "sector"`. Postgres
    permits duplicate output names; Grafana's dataframe conversion does not, and the panel rendered
    **"No Data"**. It had never worked since PR #261 created it.

  * `Every facet for this scope -- have, missing, percent` enumerated 19 of 23 facets after
    migration 160 added four. A panel that says EVERY and shows nineteen is read as complete, which
    is worse than not adding the facets at all.

  * Those same four rendered as plain numbers in both `x facet` tables, because the gauge colouring
    is a `byRegexp` override that listed facet names and did not know about them.

  * `Segment facts written per run` hardcodes the resources it plots. When Korea/DART was added,
    the panel would have kept drawing a healthy SEC line while the two new resources did nothing --
    a throughput chart that silently omits a regulator is worse than one that is missing, because
    the line that IS drawn reads as the whole story.

Each is the same shape: a piece of config that ENUMERATES something, silently going stale when the
thing it enumerates grows. The fix in the dashboard is to stop enumerating; the fix here is to fail
when an enumeration falls behind.
"""
import json
import pathlib
import re
import sys

DASH = pathlib.Path('stack/observability/grafana/dashboards')
# The panels whose titles CLAIM to be exhaustive. Keyed on the dashboard so a panel renamed on one
# does not silently exempt another.
EXHAUSTIVE = {
    ('Muffin — Data coverage', 'Every facet for this scope — have, missing, percent'),
    ('Muffin — Data coverage', 'Country × facet — where is each country incomplete?'),
    ('Muffin — Data coverage', 'Sector × facet — where is each sector incomplete?'),
}
# Columns that are labels or denominators rather than facets, so they need no gauge.
NOT_A_FACET = {'country', 'sector name', 'securities', 'segment capable', 'facet', 'have',
               'missing', 'sector', 'industry name', 'bucket'}

# Panels that plot a HARDCODED list of resources, and the tables whose writers they must cover.
# Keyed on the dashboard, like EXHAUSTIVE, so renaming a panel elsewhere cannot exempt this one.
THROUGHPUT = {
    ('Muffin — Business lines', 'Segment facts written per run'):
        ('security_segment', 'security_filing'),
}
INDEX_TS = pathlib.Path('stack/supabase/functions/market-refresh/index.ts')
MIGRATIONS = pathlib.Path('stack/supabase/migrations')


def facet_columns() -> list[str]:
    """The facets `coverage_current` actually exposes, READ FROM THE MIGRATION rather than listed
    here. A hardcoded list in this file would be the very thing it is guarding against: an
    enumeration that goes stale when the thing it enumerates grows."""
    latest = sorted(pathlib.Path('stack/supabase/migrations').glob('*.sql'),
                    key=lambda f: f.name)
    defn = ''
    for f in latest:                      # the LAST definer wins, exactly as the deploy applies them
        text = f.read_text()
        if 'view market.coverage_current as' in text:
            defn = text
    if not defn:
        print('::error::no migration defines market.coverage_current — this guard cannot run')
        sys.exit(1)
    cols = sorted(set(re.findall(r'as\s+(with_[a-z_]+)', defn)))
    if len(cols) < 10:
        print(f'::error::only {len(cols)} facet columns parsed from coverage_current; the guard '
              f'would pass vacuously')
        sys.exit(1)
    return cols


def segment_backlog_views() -> list[str]:
    """Every per-regulator segment backlog, READ FROM the migrations rather than listed here.

    A hardcoded list would be the defect this file exists to catch. When India landed,
    `pending_in_segments` was missing from two panels that enumerate regulators — the depth chart
    and the queue count — and each would have kept drawing SEC and Korea while silently omitting a
    third. That is the same family as the `limit 60` that hid the United States: a panel claiming to
    summarise a bounded set must contain all of it."""
    found = set()
    for sql in MIGRATIONS.glob('*.sql'):
        for m in re.finditer(r'create view market\.(pending_[a-z_]*segments)\b', sql.read_text()):
            found.add(m.group(1))
    return sorted(found)


def segment_writing_resources(tables: tuple[str, ...]) -> dict[str, str]:
    """Resources whose handler writes one of `tables`, READ FROM index.ts rather than listed here.

    A hardcoded list in this file would be the very thing it guards against. The handlers are
    delimited exactly as `logic-check.ts` delimits them -- `resource === X_RESOURCE` -- and the
    constant is resolved to its string literal, because the panel plots the name and the code
    carries the identifier."""
    src = INDEX_TS.read_text()
    names = dict(re.findall(r"const\s+([A-Z_]+_RESOURCE)\s*=\s*'([a-z][a-z0-9-]*)'", src))
    marks = [(m.start(), m.group(1)) for m in re.finditer(r'resource === ([A-Z_]+_RESOURCE)', src)]
    found: dict[str, str] = {}
    for i, (pos, const) in enumerate(marks):
        end = marks[i + 1][0] if i + 1 < len(marks) else len(src)
        body = src[pos:end]
        for table in tables:
            if f".from('{table}')" in body and '.upsert(' in body:
                if const in names:
                    found[names[const]] = const
                break
    return found


def safe_match(rx: str, value: str) -> bool:
    try:
        return re.search(rx, value) is not None
    except re.error:
        return False


FACET_COLUMNS = facet_columns()
failures: list[str] = []


def arms(sql: str) -> list[str]:
    """A UNION ALL repeats every alias once per arm and still yields ONE set of columns, so an
    alias check has to run per arm. A whole-query count cries wolf on every union panel -- measured,
    it flagged `Every facet for this scope` on its four legitimate columns."""
    return re.split(r'\bunion\s+all\b', sql, flags=re.I)


def panels(dash: dict):
    for p in dash.get('panels', []):
        yield p
        for sub in p.get('panels', []):   # collapsed rows nest their children
            yield sub


checked_throughput: set[tuple[str, str]] = set()

for path in sorted(DASH.glob('*.json')):
    dash = json.loads(path.read_text())
    title = dash.get('title', path.stem)

    for p in panels(dash):
        name = p.get('title', '(untitled)')
        sqls = [t['rawSql'] for t in p.get('targets', []) if t.get('rawSql')]

        # ── 1. duplicate output names ──────────────────────────────────────────────────────────
        for sql in sqls:
            for arm in arms(sql):
                seen: dict[str, int] = {}
                for alias in re.findall(r'as "([^"]+)"', arm):
                    seen[alias] = seen.get(alias, 0) + 1
                dupes = sorted(a for a, n in seen.items() if n > 1)
                if dupes:
                    failures.append(
                        f"{path.name}: panel {name!r} selects {', '.join(repr(d) for d in dupes)} "
                        f"more than once in one arm. Postgres allows it and Grafana renders the "
                        f"whole panel as 'No Data'.")

        # ── 2. a panel claiming to be exhaustive must carry every facet ────────────────────────
        if (title, name) in EXHAUSTIVE:
            blob = ' '.join(sqls)
            missing = [c for c in FACET_COLUMNS if c not in blob]
            if missing:
                failures.append(
                    f"{path.name}: panel {name!r} claims to show every facet and omits "
                    f"{', '.join(missing)}. A panel titled 'every facet' showing a subset is read "
                    f"as complete.")

        # ── 3. a hardcoded throughput list must cover every resource that does the work ────────
        #
        # `written > 0` filters were removed from these panels because a run that wrote nothing is
        # the only way a stalled resource shows up. A resource MISSING from the list is the same
        # defect one level out: the panel keeps drawing a healthy line for the resources it does
        # know about, so the gap reads as "everything is fine" rather than as no data.
        if (title, name) in THROUGHPUT:
            checked_throughput.add((title, name))
            blob = ' '.join(sqls)
            expected = segment_writing_resources(THROUGHPUT[(title, name)])
            absent = sorted(r for r in expected if f"'{r}'" not in blob)
            if absent:
                failures.append(
                    f"{path.name}: panel {name!r} plots a hardcoded resource list that omits "
                    f"{', '.join(absent)}. Those handlers write "
                    f"{'/'.join(THROUGHPUT[(title, name)])}, so their throughput would be invisible "
                    f"while the panel kept drawing a healthy line for the others.")

        # ── 4. every percentage column must be coloured ────────────────────────────────────────
        if p.get('type') != 'table':
            continue
        matchers = [o.get('matcher', {}) for o in p.get('fieldConfig', {}).get('overrides', [])]
        regexes = [m.get('options') for m in matchers
                   if m.get('id') == 'byRegexp' and isinstance(m.get('options'), str)]
        names = [m.get('options') for m in matchers
                 if m.get('id') == 'byName' and isinstance(m.get('options'), str)]
        if not regexes and not names:
            continue
        for sql in sqls:
            for arm in arms(sql):
                for alias in re.findall(r'as "([^"]+)"', arm):
                    if alias in NOT_A_FACET or '%' not in alias:
                        continue
                    covered = alias in names or any(safe_match(rx, alias) for rx in regexes)
                    if not covered:
                        failures.append(
                            f"{path.name}: panel {name!r} column {alias!r} has no colouring "
                            f"override, so it renders as a plain number in a heatmap. The matcher "
                            f"enumerates names and has gone stale.")


# A KEY THAT MATCHES NO PANEL IS A CHECK THAT CAN NEVER FIRE, and it reads exactly like a passing
# one. The first version of this named the dashboard 'Muffin — Segments'; it is 'Muffin — Business
# lines', so every assertion above would have been skipped silently.
for key in THROUGHPUT:
    if key not in checked_throughput:
        failures.append(
            f"THROUGHPUT names {key!r}, which matches no panel — the check would never run. "
            f"Fix the dashboard title or the panel name.")

# EVERY PER-REGULATOR BACKLOG MUST APPEAR IN EVERY PANEL THAT ENUMERATES REGULATORS. When India
# landed, `pending_in_segments` was missing from the queue count AND the depth chart, each of which
# would have kept drawing SEC and Korea while silently omitting a third regulator. Same family as
# the `limit 60` that hid the United States: a panel summarising a bounded set must contain all of
# it.
#
# PER PANEL, NOT ACROSS ALL OF THEM. The first version concatenated every enumerating panel and
# asked whether the name appeared anywhere — so removing a regulator from ONE panel passed clean
# while the other still mentioned it, which is precisely the defect. Proven by that mutation.
_backlogs = segment_backlog_views()
for _path in DASH.glob('*.json'):
    for _p in panels(json.loads(_path.read_text())):
        _sql = json.dumps(_p.get("targets", ""))
        if "pending_segments" not in _sql:
            continue
        for _b in _backlogs:
            if _b not in _sql:
                failures.append(
                    f"{_path.name}: panel {_p.get('title')!r} enumerates regulators but omits "
                    f"{_b} — it would keep drawing the others while a whole regulator went unshown")

if failures:

    for f in failures:
        print(f"::error::{f}")
    sys.exit(1)

n = sum(1 for path in DASH.glob('*.json') for _ in panels(json.loads(path.read_text())))
segment_resources = segment_writing_resources(('security_segment', 'security_filing'))
print(f"checked {n} panels across {len(list(DASH.glob('*.json')))} dashboards; "
      f"no duplicate aliases, no stale facet enumeration, no uncoloured percentage, "
      f"throughput covers {len(segment_resources)} segment/filing resources")

