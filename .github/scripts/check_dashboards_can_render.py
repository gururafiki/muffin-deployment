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

        # ── 3. every percentage column must be coloured ────────────────────────────────────────
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


if failures:
    for f in failures:
        print(f"::error::{f}")
    sys.exit(1)

n = sum(1 for path in DASH.glob('*.json') for _ in panels(json.loads(path.read_text())))
print(f"checked {n} panels across {len(list(DASH.glob('*.json')))} dashboards; "
      f"no duplicate aliases, no stale facet enumeration, no uncoloured percentage")
