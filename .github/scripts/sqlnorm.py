#!/usr/bin/env python3
"""The two ways Postgres renders the SAME schema differently, in ONE place.

Both are round-trip artifacts, not differences in meaning, and both were found by a check going red
on a schema that was correct:

1. `\\restrict` / `\\unrestrict` carry a RANDOM TOKEN per dump session, so two dumps of one database
   never match. They are also psql meta-commands rather than SQL.

2. `pg_get_viewdef` IS NOT ROUND-TRIP STABLE. A `union all` arm carrying an unaliased literal
   renders as `'sector'::text`; recreate the view from that text and Postgres assigns the DEFAULT
   alias — the type name — so it re-renders as `'sector'::text AS text`. `coverage_current` does it
   eleven times. The difference is cosmetic by construction: a union's output column names come from
   its FIRST arm, so an alias on a later arm names nothing.

Shared because it is needed in two places that would otherwise drift — the extractor (Python) and
the baseline equivalence check (shell) — and a normalisation applied in one but not the other makes
a real difference look like an artifact, or the reverse.
"""

import re
import sys

#: Deliberately narrow: only an alias that repeats its own cast's type. `AS symbol` is untouched,
#: and an alias that genuinely reads `AS text` was already the default it is compared against.
_DEFAULT_ALIAS = re.compile(r"::(\w+) AS \1\b")
_META = re.compile(r"^\\(un)?restrict .*$", re.M)


def normalise(sql: str) -> str:
    return _DEFAULT_ALIAS.sub(r"::\1", _META.sub("", sql))


if __name__ == "__main__":
    sys.stdout.write(normalise(sys.stdin.read()))
