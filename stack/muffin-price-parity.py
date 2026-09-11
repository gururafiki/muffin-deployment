#!/usr/bin/env python3
"""Compare the new `market.price_bar` against the old `market.security_price`, and adjudicate.

RUN INSIDE THE muffin-ingest CONTAINER, which already has psycopg and the provider hub:

    ssh muffin 'docker exec -i $(docker ps -qf name=muffin_muffin-ingest) python -' \
        < stack/muffin-price-parity.py                      # compare
    ... python - adjudicate 12                              # and ask the provider about 12 of them
    ... python - baseline 200                               # how shifted is the OLD table itself

WHY A TOLERANCE RATHER THAN EQUALITY. Both tables hold what yfinance returned, and yfinance returns
FLOAT32. Stored through two different paths the same number reads as 1010.26000976562 and
1010.260009765625 — identical to the provider, different to `=`. Comparing exactly reported 36 of 48
rows as disagreeing when almost all of them agreed; 1e-6 relative is the honest line.

AND THE BASELINE IS ITSELF SUSPECT, WHICH IS WHY `adjudicate` EXISTS. Measured 2026-09-11 on three
symbols where the two tables disagreed, with the sessions long closed, the provider supported the
NEW value every time — and for QIBK.QA the old table held the NEXT DAY's close. So "matches the old
pipeline" was never the target: the gate is every disagreement EXPLAINED, and only the provider can
explain one.
"""

from __future__ import annotations

import os
import sys
from collections import Counter

#: Float32 carries ~7 significant digits, so two renderings of one provider value differ by ~1e-7.
#: A tenth of a percent of that is still far below any real price move.
TOLERANCE = 1e-6

COMPARE = """
with paired as (
  select pb.security_id, pb.trade_date, pb.close as new_close, sp.close as old_close,
         abs(pb.close - sp.close) / nullif(abs(sp.close), 0) as rel
    from market.price_bar pb
    join market.security_price sp
      on sp.security_id = pb.security_id and sp.date = pb.trade_date and sp.grain = 'daily'
)
select count(*) as compared,
       count(*) filter (where rel <= %s) as agree,
       count(*) filter (where rel > %s) as disagree,
       count(*) filter (where rel is null) as undefined
  from paired
"""

COVERAGE = """
select (select count(*) from market.price_bar) as new_rows,
       (select count(distinct security_id) from market.price_bar) as new_securities,
       (select count(distinct trade_date) from market.price_bar) as new_dates,
       (select count(*) from market.price_bar pb
         where not exists (select 1 from market.security_price sp
                            where sp.security_id = pb.security_id and sp.date = pb.trade_date
                              and sp.grain = 'daily')) as new_only
"""

WORST = """
with paired as (
  select pb.security_id, pb.trade_date, pb.close as new_close, sp.close as old_close,
         abs(pb.close - sp.close) / nullif(abs(sp.close), 0) as rel
    from market.price_bar pb
    join market.security_price sp
      on sp.security_id = pb.security_id and sp.date = pb.trade_date and sp.grain = 'daily'
)
select sym.symbol, p.trade_date, p.new_close, p.old_close, p.rel, s.country_iso2
  from paired p
  join market.security_symbol sym on sym.security_id = p.security_id
  join market.security s on s.security_id = p.security_id
 where p.rel > %s
 order by p.rel desc
 limit %s
"""

#: A weight-ordered sample of what the OLD table holds, to ask the provider about directly. Nothing
#: to do with the new pipeline — this measures whether `security_price` can serve as a baseline.
BASELINE_SAMPLE = """
select sym.symbol, sp.date, sp.close, s.country_iso2
  from market.security_price sp
  join market.security_symbol sym on sym.security_id = sp.security_id
  join market.security s on s.security_id = sp.security_id
  left join market.fund_holding_current h on h.security_id = sp.security_id
 where sp.grain = 'daily' and sp.date between %s and %s
 group by sym.symbol, sp.date, sp.close, s.country_iso2
 order by max(coalesce(h.weight, 0)) desc, sym.symbol
 limit %s
"""


def connect():  # type: ignore[no-untyped-def]
    import psycopg

    dsn = os.environ.get("INGEST_DATABASE_URL")
    if not dsn:
        sys.exit("INGEST_DATABASE_URL is unset")
    return psycopg.connect(dsn)


def compare() -> None:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(COVERAGE)
        rows, securities, dates, new_only = cur.fetchone()
        print(f"new table: {rows} rows · {securities} securities · {dates} dates")
        print(f"  rows the OLD table has no bar for at all: {new_only}")

        cur.execute(COMPARE, (TOLERANCE, TOLERANCE))
        compared, agree, disagree, undefined = cur.fetchone()
        if not compared:
            sys.exit("nothing overlaps yet — materialise some partitions first")
        print(f"\ncompared {compared} (security, date) pairs at rel <= {TOLERANCE:g}")
        print(f"  agree      {agree:6d}   {agree / compared:6.2%}")
        print(f"  disagree   {disagree:6d}   {disagree / compared:6.2%}")
        if undefined:
            print(f"  undefined  {undefined:6d}   (old close is zero — cannot form a ratio)")

        cur.execute(WORST, (TOLERANCE, 15))
        worst = cur.fetchall()
        if worst:
            print("\nworst disagreements:")
            by_country: Counter[str] = Counter()
            for symbol, day, new, old, rel, country in worst:
                by_country[country or "??"] += 1
                print(f"  {symbol:14} {day}  new={new!s:<14} old={old!s:<14} {rel:.4%}  {country}")
            print(f"\n  by country: {dict(by_country)}")


def adjudicate(limit: int) -> None:
    """Ask the provider who is right. THE ONLY THING THAT SETTLES A DISAGREEMENT."""
    from muffin_ingest.providers import openbb

    with connect() as conn, conn.cursor() as cur:
        cur.execute(WORST, (TOLERANCE, limit))
        rows = cur.fetchall()

    verdict: Counter[str] = Counter()
    for symbol, day, new, old, rel, country in rows:
        try:
            answer = openbb.price_history([symbol], start=day, end=day)
        except Exception as e:  # a provider that will not answer adjudicates nothing
            print(f"  {symbol:14} {day}  provider refused: {type(e).__name__}")
            verdict["unanswered"] += 1
            continue
        closes = {str(r.get("date"))[:10]: r.get("close") for r in answer.rows}
        said = closes.get(str(day))
        if said is None:
            print(f"  {symbol:14} {day}  provider has no bar for this date "
                  f"(it returned {sorted(closes)})")
            verdict["no bar"] += 1
            continue
        near = lambda a, b: abs(a - b) / abs(b) <= 1e-4 if b else False  # noqa: E731
        side = "NEW" if near(said, float(new)) else "OLD" if near(said, float(old)) else "NEITHER"
        verdict[side] += 1
        print(f"  {symbol:14} {day}  provider={said!s:<14} new={new!s:<14} old={old!s:<14} -> {side}")

    print(f"\nverdict: {dict(verdict)}")
    print("NEW winning is not a formality — it is the whole question. The old table is the baseline "
          "only for as long as the provider agrees with it.")


def baseline(limit: int) -> None:
    """How shifted is the OLD table, independently of anything new? Measured, NOT fixed."""
    from muffin_ingest.providers import openbb

    with connect() as conn, conn.cursor() as cur:
        cur.execute(BASELINE_SAMPLE, ("2026-09-01", "2026-09-10", limit))
        rows = cur.fetchall()

    verdict: Counter[str] = Counter()
    shifted_by_country: Counter[str] = Counter()
    for symbol, day, stored, country in rows:
        try:
            answer = openbb.price_history([symbol], start=day, end=day)
        except Exception:
            verdict["unanswered"] += 1
            continue
        closes = {str(r.get("date"))[:10]: r.get("close") for r in answer.rows}
        said = closes.get(str(day))
        if said is None:
            verdict["provider has no bar"] += 1
            continue
        if abs(said - float(stored)) / abs(said) <= 1e-4:
            verdict["agrees"] += 1
        # THE SPECIFIC DEFECT: is the stored value some OTHER day's close?
        elif any(abs(v - float(stored)) / abs(v) <= 1e-4 for v in closes.values() if v):
            verdict["holds another day's close"] += 1
            shifted_by_country[country or "??"] += 1
        else:
            verdict["disagrees, not a shift"] += 1
            shifted_by_country[country or "??"] += 0

    total = sum(verdict.values()) or 1
    print(f"sampled {total} stored (symbol, date) pairs from the OLD table")
    for k, v in verdict.most_common():
        print(f"  {k:28} {v:5d}  {v / total:6.2%}")
    if shifted_by_country:
        print(f"\n  shifted, by country: {dict(shifted_by_country)}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "compare"
    n = int(sys.argv[2]) if len(sys.argv) > 2 else 12
    {"compare": lambda: compare(), "adjudicate": lambda: adjudicate(n),
     "baseline": lambda: baseline(n)}[mode]()
