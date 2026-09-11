#!/usr/bin/env python3
"""Compare the new `market.price_bar` against the old `market.security_price`, and adjudicate.

RUN INSIDE THE muffin-ingest CONTAINER, which already has psycopg and the provider hub:

    ssh muffin 'docker exec -i $(docker ps -qf name=muffin_muffin-ingest) python -' \
        < stack/muffin-price-parity.py                      # compare
    ... python - adjudicate 12                              # and ask the provider about 12 of them
    ... python - baseline 200                               # how shifted is the OLD table itself
    ... python - returns 0.10                               # gate two: the computed return layer

TWO GATES, AND THEY DO NOT SHARE A UNIT. `compare` holds two renderings of ONE provider number
against each other, so a RELATIVE tolerance is right. `returns` holds two COMPUTATIONS against each
other, so the unit is the percentage POINT — a relative test there calls 340% vs 341% a closer
agreement than 0.01% vs 0.02%, which is backwards from what a reader sees.

WHY A TOLERANCE RATHER THAN EQUALITY. Both tables hold what yfinance returned, and yfinance returns
FLOAT32. Stored through two different paths the same number reads as 1010.26000976562 and
1010.260009765625 — identical to the provider, different to `=`. Comparing exactly reported 36 of 48
rows as disagreeing when almost all of them agreed; 1e-6 relative is the honest line.

ASKED WITH THE FETCH SYMBOL, NEVER THE DISPLAY ONE, AND THE FIRST VERSION GOT THAT WRONG. Running
the baseline over Gulf and Latin American holdings reported 48% of them "unanswered" — which read as
a striking fact about the data and was a fact about the probe. `ALMARAI.SR` is what the app SHOWS;
yfinance wants `2280.SR`, because Saudi tickers are numeric there. Every one of those securities had
bars dated the day before, written by the old pipeline asking correctly.

"A wrong name is not a missing security" is the most repeated correction in this codebase, and a
tool that asks with the wrong name manufactures exactly the absence it is looking for.

AND THE BASELINE IS ITSELF SUSPECT, WHICH IS WHY `adjudicate` EXISTS. Measured 2026-09-11 on three
symbols where the two tables disagreed, with the sessions long closed, the provider supported the
NEW value every time — and for QIBK.QA the old table held the NEXT DAY's close. So "matches the old
pipeline" was never the target: the gate is every disagreement EXPLAINED, and only the provider can
explain one.
"""

from __future__ import annotations

import os
import sys
from datetime import date
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
select coalesce(ps.symbol, sym.symbol), p.trade_date, p.new_close, p.old_close, p.rel,
       s.country_iso2
  from paired p
  join market.security_symbol sym on sym.security_id = p.security_id
  join market.security s on s.security_id = p.security_id
  left join market.security_provider_symbol ps
    on ps.security_id = p.security_id and ps.provider_code = 'yfinance'
 where p.rel > %s
 order by p.rel desc
 limit %s
"""

#: A weight-ordered sample of what the OLD table holds, to ask the provider about directly. Nothing
#: to do with the new pipeline — this measures whether `security_price` can serve as a baseline.
BASELINE_SAMPLE = """
select coalesce(ps.symbol, sym.symbol), sp.date, sp.close, s.country_iso2
  from market.security_price sp
  join market.security_symbol sym on sym.security_id = sp.security_id
  join market.security s on s.security_id = sp.security_id
  left join market.security_provider_symbol ps
    on ps.security_id = sp.security_id and ps.provider_code = 'yfinance'
  left join market.fund_holding_current h on h.security_id = sp.security_id
 where sp.grain = 'daily' and sp.date between %s and %s
 group by coalesce(ps.symbol, sym.symbol), sp.date, sp.close, s.country_iso2
 order by max(coalesce(h.weight, 0)) desc, 1
 limit %s
"""


#: THE SECOND GATE. Bars are the cheaper signal; returns are what the app actually renders, so the
#: cutover is gated on both. The join is on the DISPLAY symbol because that is what `performance`
#: is keyed on — `scope = 'instrument'`, `scope_id = 'PMZ-U.TO'` — a fact this schema has already
#: recorded as costing a reported "0 of 27,629" when someone joined it on `security_id`.
#:
#: AND THE COMPARISON IS IN PERCENTAGE POINTS, NOT A RELATIVE TOLERANCE, which is the opposite of
#: the bars. Two bar prices are two renderings of ONE provider number and a relative tolerance is
#: exactly right for that. Two returns are two COMPUTATIONS — different bar sets (the old resource
#: downloads a fresh history and discards it; the new one reads `price_bar` over a 1,900-day
#: lookback), different anchor rules, different dividend handling. A relative tolerance would call
#: 340% against 341% a 0.3% disagreement and 0.01% against 0.02% a 100% one, ranking them backwards.
#: What a reader sees is the percentage POINT, so that is the unit.
RETURNS_COMPARE = """
with paired as (
  select sr.security_id, sr.period_code, sym.symbol,
         sr.price_return_pct as new_price, pf.change_pct as old_price,
         sr.total_return_pct as new_total, pf.total_return_pct as old_total,
         sr.as_of as new_as_of, pf.as_of::date as old_as_of
    from market.security_return sr
    join market.security_symbol sym on sym.security_id = sr.security_id
    join market.performance pf
      on pf.scope = 'instrument' and pf.scope_id = sym.symbol and pf.period = sr.period_code
)
select count(*) as compared,
       count(*) filter (where new_as_of = old_as_of) as same_day,
       count(*) filter (where old_price is not null and new_price is not null
                          and abs(new_price - old_price) <= %s) as agree,
       count(*) filter (where old_price is not null and new_price is not null
                          and abs(new_price - old_price) > %s) as disagree,
       count(*) filter (where new_price is null) as new_withheld,
       count(*) filter (where old_price is null) as old_missing
  from paired
"""

#: A period the new pipeline WITHHOLDS is a result, not a gap — the rules refuse a window that never
#: moved, an anchor before a discontinuity, a series gone stale. Counting those as failures is how a
#: correct guard becomes one nobody reads, so they are reported as their own bucket.
RETURNS_WORST = """
with paired as (
  select sym.symbol, sr.period_code, s.country_iso2,
         sr.price_return_pct as new_price, pf.change_pct as old_price,
         abs(sr.price_return_pct - pf.change_pct) as gap,
         sr.as_of as new_as_of, pf.as_of::date as old_as_of
    from market.security_return sr
    join market.security_symbol sym on sym.security_id = sr.security_id
    join market.security s on s.security_id = sr.security_id
    join market.performance pf
      on pf.scope = 'instrument' and pf.scope_id = sym.symbol and pf.period = sr.period_code
   where sr.price_return_pct is not null and pf.change_pct is not null
)
select symbol, period_code, new_price, old_price, gap, country_iso2, new_as_of, old_as_of
  from paired where gap > %s order by gap desc limit %s
"""

#: Per period, because the periods do NOT fail alike and an aggregate hides that. A 1d return is a
#: ratio of two adjacent closes and agreement should be near-total; a 1y return depends on how each
#: side picks an anchor across a year of holidays, and drifting by a point there is arithmetic
#: rather than a defect.
RETURNS_BY_PERIOD = """
with paired as (
  select sr.period_code,
         sr.price_return_pct as new_price, pf.change_pct as old_price,
         sr.as_of as new_as_of, pf.as_of::date as old_as_of
    from market.security_return sr
    join market.security_symbol sym on sym.security_id = sr.security_id
    join market.performance pf
      on pf.scope = 'instrument' and pf.scope_id = sym.symbol and pf.period = sr.period_code
   where sr.price_return_pct is not null and pf.change_pct is not null
)
select period_code, count(*),
       count(*) filter (where abs(new_price - old_price) <= %s),
       round(percentile_cont(0.5) within group (order by abs(new_price - old_price))::numeric, 4),
       round(max(abs(new_price - old_price))::numeric, 4),
       count(*) filter (where new_as_of <> old_as_of)
  from paired group by 1 order by 1
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


#: The disagreeing pairs, with the symbol needed to pull our own bars back out.
RETURNS_DISAGREEMENTS = """
select sym.symbol, sr.security_id, sr.period_code, sr.price_return_pct, pf.change_pct,
       s.country_iso2, pf.as_of::date, ob.last_old
  from market.security_return sr
  join market.security_symbol sym on sym.security_id = sr.security_id
  join market.security s on s.security_id = sr.security_id
  join market.performance pf
    on pf.scope = 'instrument' and pf.scope_id = sym.symbol and pf.period = sr.period_code
  join (select security_id, max(date) as last_old from market.security_price
         where grain = 'daily' group by security_id) ob on ob.security_id = sr.security_id
 where sr.price_return_pct is not null and pf.change_pct is not null
   and abs(sr.price_return_pct - pf.change_pct) > %s
 order by abs(sr.price_return_pct - pf.change_pct) desc
 limit %s
"""


def returns_adjudicate(tolerance_pp: float, limit: int) -> None:
    """Does rolling OUR OWN series back a day or two reproduce the OLD number?

    THE ONLY WAY TO TELL AN OFFSET FROM A DISAGREEMENT, and the difference is the whole gate. Two
    implementations reading the same series to different endpoints produce different returns while
    both being exactly right — SCCO fell 7.2% on 2026-09-10 and the old resource refreshed at
    10:55 UTC that morning, so its newest US bar was 09-09 and ours was 09-10. Reported as a
    percentage-point gap that is a 7.5pp "disagreement" on data where nothing disagrees.

    So: truncate our series at each of the last few trading days, recompute with the SHIPPED rules,
    and see which endpoint reproduces the old figure. An endpoint that does explains the pair
    completely. One that does not is a real difference and is printed for a human.
    """
    from muffin_ingest.derive import returns as derive
    from muffin_ingest.facets import prices as facet

    with connect() as conn, conn.cursor() as cur:
        cur.execute(RETURNS_DISAGREEMENTS, (tolerance_pp, limit))
        rows = cur.fetchall()

        verdict: Counter[str] = Counter()
        for symbol, security_id, period, new_v, old_v, country, old_as_of, last_old in rows:
            series = facet.bars_for(conn, [str(security_id)], since=date(1990, 1, 1)).get(
                str(security_id), []
            )
            if not series:
                verdict["we hold no bars"] += 1
                continue

            # THE OLD SIDE CAN BE AHEAD OF US, AND THE FIRST VERSION OF THIS COULD NOT SEE THAT.
            # It searched backward from OUR last bar, which explains an old table that is behind and
            # reports one that is AHEAD as wholly unexplained — 92.5%, an artefact of the search
            # direction rather than a finding. The old resource refreshes eight times a day and
            # writes a bar dated TODAY from a session that has not closed (measured: 586 securities
            # carried a 2026-09-11 bar at 15:00 UTC); a Dagster partition cannot materialise until
            # its window closes, so our newest close is legitimately yesterday's.
            #
            # A return computed to a bar we refuse to write is not comparable to ours, and calling
            # that a disagreement would be marking our own correctness as a defect.
            if last_old is not None and last_old > series[-1].trade_date:
                verdict[f"old priced to {last_old}, a session we have not closed"] += 1
                continue

            explained = None
            # Back through the recent sessions, newest first — offset 0 is what we already stored,
            # so a match there would mean the disagreement is not about the endpoint at all.
            for back in range(0, 6):
                truncated = series[: len(series) - back] if back else series
                if len(truncated) < 2:
                    break
                end = truncated[-1].trade_date
                got = derive.price_returns(truncated, end).get(period)
                if got is not None and abs(got - float(old_v)) <= tolerance_pp:
                    explained = (back, end)
                    break
            if explained and explained[0] > 0:
                verdict[f"old is {explained[0]} session(s) behind"] += 1
            elif explained:
                verdict["reproduced at our own endpoint (investigate)"] += 1
            else:
                verdict["not an endpoint offset"] += 1
                print(f"  {symbol:14} {period:4} new={new_v!s:>10} old={old_v!s:>10}  {country}"
                      f"  — no endpoint in the last 6 sessions reproduces the old value")

    total = sum(verdict.values()) or 1
    print(f"\nadjudicated {total} disagreements by rolling our own series back:")
    for k, v in verdict.most_common():
        print(f"  {k:44} {v:5d}  {v / total:6.2%}")
    print("\nAN OFFSET IS NOT A TIE. Where the old value is reproduced by an EARLIER endpoint, both "
          "implementations agree and the old table is simply behind — the same direction the bars "
          "gate found, where it held the next day's close for QIBK.QA.")


#: Every period the old layer published for one security, beside our own — one row per security,
#: so the implied-price test below can ask whether ONE number explains all of them at once.
RETURNS_BY_SECURITY = """
select sym.symbol, sr.security_id, s.country_iso2,
       jsonb_object_agg(sr.period_code, sr.price_return_pct) filter
         (where sr.price_return_pct is not null) as ours,
       jsonb_object_agg(pf.period, pf.change_pct) filter (where pf.change_pct is not null) as theirs
  from market.security_return sr
  join market.security_symbol sym on sym.security_id = sr.security_id
  join market.security s on s.security_id = sr.security_id
  join market.performance pf
    on pf.scope = 'instrument' and pf.scope_id = sym.symbol and pf.period = sr.period_code
 group by 1, 2, 3
 having count(*) >= 4
 order by 1
 limit %s
"""


def returns_intraday(tolerance_pp: float, limit: int) -> None:
    """Is the whole residual just the old layer pricing to a session that has not closed?

    THE TEST IS OVER-DETERMINED, WHICH IS WHAT MAKES IT EVIDENCE. Solve the old layer's 1d figure
    for the latest price it must have used — `implied = our_last_close * (1 + old_1d/100)` — and
    then check whether that ONE number reproduces the old layer's 1w, 1m, 3m, 6m, 1y and ytd over
    OUR OWN anchors. Six independent equations, one unknown: a coincidence cannot satisfy them.

    Worked by hand on SCCO first, which is why this exists rather than a fourth category of
    "unexplained". Our 09-10 close is 194.14 and the old layer published 1d = +1.4732, implying a
    latest of 197.00; its 1w of -0.8855 over our 09-04 close of 198.76 implies 197.00 as well. The
    old resource re-fetches a history at refresh time and computes from that, so an 8x-daily cron
    running at 15:00 UTC prices US names mid-session.

    A "1-day return" measured to a mid-session quote is not a daily return. A Dagster partition
    cannot materialise until its window closes, so our refusing to publish that number is the
    correct behaviour and not the gap it reads as.
    """
    from muffin_ingest.facets import prices as facet

    lookback = {"1w": 7, "1m": 30, "3m": 91, "6m": 182, "1y": 365}
    verdict: Counter[str] = Counter()
    detail: list[str] = []

    with connect() as conn, conn.cursor() as cur:
        cur.execute(RETURNS_BY_SECURITY, (limit,))
        for symbol, security_id, country, ours, theirs in cur.fetchall():
            if not theirs or "1d" not in theirs:
                verdict["no 1d to solve from"] += 1
                continue
            series = facet.bars_for(conn, [str(security_id)], since=date(1990, 1, 1)).get(
                str(security_id), []
            )
            if len(series) < 3:
                verdict["too few bars"] += 1
                continue

            last = series[-1].close
            implied = last * (1 + float(theirs["1d"]) / 100)
            if abs(implied - last) / last <= tolerance_pp / 100:
                verdict["old priced to our own last close"] += 1
                continue

            basis = series[-1].trade_date
            checked = agreed = 0
            for period, days in lookback.items():
                if period not in theirs:
                    continue
                idx = derive_index(series, basis, days)
                if idx is None:
                    continue
                anchor = series[idx].close
                if anchor <= 0:
                    continue
                checked += 1
                predicted = (implied / anchor - 1) * 100
                agreed += abs(predicted - float(theirs[period])) <= tolerance_pp

            if checked < 2:
                verdict["not enough periods to over-determine"] += 1
            elif agreed == checked:
                verdict["explained: old priced to an unclosed session"] += 1
            elif agreed:
                verdict[f"partly explained ({agreed}/{checked} periods)"] += 1
                detail.append(f"  {symbol:14} {country}  implied {implied:.4f} vs our close "
                              f"{last:.4f} explains {agreed}/{checked} periods")
            else:
                verdict["not an intraday capture"] += 1
                detail.append(f"  {symbol:14} {country}  implied {implied:.4f} vs our close "
                              f"{last:.4f} explains none of {checked}")

    total = sum(verdict.values()) or 1
    print(f"tested {total} securities by solving the old 1d for the price it must have used\n")
    for k, v in verdict.most_common():
        print(f"  {k:48} {v:5d}  {v / total:6.2%}")
    if detail:
        print("\nnot fully explained:")
        for line in detail[:20]:
            print(line)


def derive_index(series: Any, basis: date, days: int) -> int | None:
    """`index_at_or_before` without importing the private module — the same rule, stated once."""
    from datetime import timedelta

    target = basis - timedelta(days=days)
    found = None
    for i, bar in enumerate(series):
        if bar.trade_date <= target:
            found = i
        else:
            break
    return found


def returns(tolerance_pp: float) -> None:
    """Gate two: does the computed return layer agree with what the app renders today?

    THE GATE IS NOT "IDENTICAL" HERE EITHER, and for a stronger reason than with the bars. The old
    resource recomputes a return from a history it downloads fresh each run; the new asset reads
    the bars we stored. Where those two disagree, one of three things is true and they are worth
    telling apart: the bar sets differ (which the bars gate already measured), the ANCHOR rules
    differ (a holiday, a half-session, a discontinuity one side refuses to price across), or one
    side is stale. `new_as_of <> old_as_of` separates the third from the first two for free.
    """
    with connect() as conn, conn.cursor() as cur:
        cur.execute(RETURNS_COMPARE, (tolerance_pp, tolerance_pp))
        compared, same_day, agree, disagree, withheld, missing = cur.fetchone()
        if not compared:
            sys.exit("nothing overlaps — materialise security_return first")
        both = agree + disagree or 1
        print(f"compared {compared} (security, period) pairs   "
              f"[{same_day} computed on the same day]")
        print(f"  agree within {tolerance_pp}pp   {agree:6d}   {agree / both:6.2%} of comparable")
        print(f"  disagree               {disagree:6d}   {disagree / both:6.2%} of comparable")
        print(f"  new withheld a number  {withheld:6d}   (a refusal is a result, not a gap)")
        print(f"  old had none           {missing:6d}")

        cur.execute(RETURNS_BY_PERIOD, (tolerance_pp,))
        print(f"\n  {'period':8} {'n':>7} {'agree':>8} {'median pp':>10} {'max pp':>10} {'stale':>7}")
        for period, n, ok, med, mx, stale in cur.fetchall():
            print(f"  {period:8} {n:7d} {ok / (n or 1):7.1%} {med!s:>10} {mx!s:>10} {stale:7d}")

        cur.execute(RETURNS_WORST, (tolerance_pp, 15))
        worst = cur.fetchall()
        if worst:
            print("\nworst disagreements:")
            by_country: Counter[str] = Counter()
            for sym, period, new, old, gap, country, n_as, o_as in worst:
                by_country[country or "??"] += 1
                stale = "" if n_as == o_as else f"  (old as_of {o_as})"
                print(f"  {sym:14} {period:4} new={new!s:>10} old={old!s:>10} "
                      f"{gap:8.2f}pp  {country}{stale}")
            print(f"\n  by country: {dict(by_country)}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "compare"
    # PARSED LAZILY. Read eagerly, `int(sys.argv[2])` runs for EVERY mode — so `returns 0.10`
    # died on the argument of a mode it was not invoking.
    arg = sys.argv[2] if len(sys.argv) > 2 else None
    #: The modes whose argument is a percentage POINT rather than a row count.
    PP_MODES = {"returns", "returns-adjudicate", "returns-intraday"}
    n = int(arg) if arg is not None and mode not in PP_MODES else 12
    {"compare": lambda: compare(), "adjudicate": lambda: adjudicate(n),
     "baseline": lambda: baseline(n),
     # A percentage POINT, not a count — the second argument means something different here, which
     # is why the mode takes it as a float.
     "returns": lambda: returns(float(arg) if arg is not None else 0.10),
     "returns-adjudicate": lambda: returns_adjudicate(
         float(arg) if arg is not None else 0.10, 200),
     "returns-intraday": lambda: returns_intraday(
         float(arg) if arg is not None else 0.10, 200)}[mode]()
