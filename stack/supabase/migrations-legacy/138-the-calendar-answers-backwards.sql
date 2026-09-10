-- THE ENDPOINT WE ALREADY CALL ANSWERS THE QUESTION WE WERE PAYING ANOTHER PROVIDER FOR.
--
-- `security-eps-history` buys actual-vs-estimate from alpha_vantage at **25 calls a DAY**, one
-- symbol per call, US-only. After weeks it holds 7,815 rows across **79 securities**, and all 79
-- already had derived EPS — so it contributed nothing to the actuals and only the surprise.
--
-- `equity/calendar/earnings?provider=nasdaq` is the endpoint this schema ALREADY calls for the
-- forward calendar, and nobody had asked it for a PAST date range. Measured 2026-08-28:
--
--     start=2026-07-29 end=2026-07-31   ->  643 rows
--     fields: eps_actual, eps_consensus, surprise_percent, num_estimates, period_ending,
--             report_date, reporting_time, market_cap, name, symbol
--     2024-02-06 -> 128 rows, all with an actual
--     2021-02-03 -> 100 rows, all with an actual
--     2018-02-06 -> 104 rows, all with an actual
--
-- 643 companies in ONE call against alpha_vantage's 25 companies a DAY, with the surprise already
-- computed and history reaching at least 2018. Five years is ~200 calls walking back in 3-day
-- windows; alpha_vantage would need ~500 days for the same names.
--
-- REACH, STATED RATHER THAN ASSUMED: predominantly US. Of 643 symbols only 3 carried an exchange
-- suffix, though ADRs are present (SONY, SMFG, ENB, NWG, AU). So this widens surprise coverage from
-- 79 securities to most of the US-listed universe plus ADRs — a large gain, not the global reach
-- that price and statement data now have. Recorded so nobody re-derives it as "global".
--
-- WHY 3 DAYS AND NOT 5: a five-day window times out on this endpoint (already recorded when the
-- forward calendar was built). The chunk size is part of the contract, not a tuning knob.

-- ── THE CURSOR ────────────────────────────────────────────────────────────────────────────────
--
-- A BACKWARD WALK NEEDS A POSITION, AND IT IS NOT A NEGATIVE CACHE. Nothing here is "the provider
-- has nothing for this entity" — the resource is sweeping a calendar, so what it must remember is
-- HOW FAR BACK IT HAS GOT. One row, enforced the same way `cron_cursor` is: two rows would advance
-- twice per run and silently skip half the history.
create table if not exists market.earnings_history_cursor (
  only_row     boolean primary key default true check (only_row),
  walked_to    date not null default current_date,
  -- The floor. Not `null` and not "for ever": the endpoint thins out going back, and a walk with no
  -- end would spend a slot a day for ever re-asking 1995 for rows that do not exist.
  stop_at      date not null default date '2015-01-01',
  updated_at   timestamptz not null default now()
);
insert into market.earnings_history_cursor (only_row) values (true) on conflict do nothing;

comment on table market.earnings_history_cursor is
  'How far back the earnings-history sweep has walked. A POSITION, not a negative cache: the resource sweeps a calendar rather than asking about entities.';

grant select on market.earnings_history_cursor to service_role, metrics_ro;
grant insert, update on market.earnings_history_cursor to service_role;

alter table market.earnings_history_cursor enable row level security;
do $$ begin
  drop policy if exists earnings_cursor_read on market.earnings_history_cursor;
  create policy earnings_cursor_read on market.earnings_history_cursor
    for select to metrics_ro using (true);
end $$;

-- ── THE ALPHA_VANTAGE RESOURCE IS RETIRED ─────────────────────────────────────────────────────
--
-- Removed from the rotation entirely rather than disabled: `enabled = false` means "runs on its own
-- schedule" here (migration 137) and logic-check now enforces that a disabled resource HAS one.
-- This resource has no schedule because it should not run at all.
--
-- ITS DATA STAYS. The 7,815 rows reach back to 1996 — deeper than nasdaq's ~2018 — so they are the
-- better record for those 79 securities and are left exactly where they are. `source_code` is what
-- keeps the two distinguishable, which is why it was there from the start.
delete from market.cron_resource where resource = 'security-eps-history';

insert into market.cron_resource (position, resource) values
  (345, 'earnings-history')
on conflict (position) do update set resource = excluded.resource;

-- ── AND THE STATEMENTS BACKLOG, WHICH HAS BEEN STALLED ────────────────────────────────────────
--
-- `security-statements` returned BYTE-IDENTICAL results on five consecutive runs — `written: 240,
-- remaining: 8668` — which is this file's own headline signature: a `written` that looks like
-- throughput and never moves. The head of the backlog (D05.SI, 005930.KS, 1299.HK, FPH.NZ, O39.SI)
-- already held 15-27 statements each.
--
-- WHY. Migration 088 added a second population — securities that HAVE statements but no reporting
-- currency — so SEC could supply one, with `statement_currency_missing_at` as the exit. That column
-- is set on **0 of 12,350 equities**. The write exists and is guarded, but it is gated on `secOk`,
-- meaning "SEC answered for SOMEONE in this run", and the weight-ordered head is entirely foreign
-- securities SEC cannot serve. So the gate never opens, nothing is marked, and the page repeats.
-- Same shape as the `security-profile-detail` stall: a run-level tally in front of per-item
-- evidence guarantees a stall once the answerable head is gone.
--
-- THE FIX IS STRUCTURAL, NOT A BETTER MARKING RULE. SEC statements are addressable only by CIK,
-- and measured: **0 securities without a CIK have EVER received a `sec`-sourced statement**. Of the
-- 5,744 stuck in this population, 2,416 have no CIK and can never be satisfied — they are starving
-- the 3,328 that SEC could actually serve. `security-filings` is already scoped this way for the
-- same reason (`CIK not found` for a non-filer like SAP.DE).
--
-- A US TICKER IS NOT A CIK, and that is the trap: OpenFIGI's US lookup returns a thin OTC
-- foreign-ordinary line for most foreign companies, so `t.value is not null` looked like "this is a
-- US registrant" and is not.
drop view if exists market.pending_statements;
create view market.pending_statements as
select
  s.security_id,
  coalesce(ps.symbol, t.value) as symbol,
  t.value                      as us_ticker,
  case when st.security_id is null then 'missing' else 'no_currency' end as want,
  coalesce(max(h.weight), 0)   as best_weight
from market.security s
left join market.security_provider_symbol ps
  on ps.security_id = s.security_id and ps.provider_code = 'yfinance'
left join market.security_identifier t
  on t.security_id = s.security_id and t.kind_code = 'ticker'
left join lateral (
  select x.security_id, count(*) filter (where x.currency is not null) as with_currency
    from market.security_statement x
   where x.security_id = s.security_id
   group by x.security_id
) st on true
left join market.fund_holding_current h on h.security_id = s.security_id
where s.security_type_code = 'equity'
  and coalesce(ps.symbol, t.value) is not null
  and (s.statements_missing_at is null or s.statements_missing_at < now() - interval '30 days')
  and (
    st.security_id is null
    or (
      st.with_currency = 0
      -- BOTH, AND THAT IS THE CORRECTION. The US ticker is how the RESOURCE addresses SEC (it
      -- passes `us_ticker`, and skips SEC entirely when it is null); the CIK is whether SEC knows
      -- this filer AT ALL. Requiring only the ticker admitted 2,416 securities SEC can never
      -- answer for — but replacing it with the CIK was also wrong, and the behaviour test caught
      -- it immediately: a security with a CIK and no US line would be queued for a fetch the
      -- resource cannot even make.
      and t.value is not null
      and s.cik is not null
      and (s.statement_currency_missing_at is null
           or s.statement_currency_missing_at < now() - interval '30 days')
    )
  )
group by s.security_id, coalesce(ps.symbol, t.value), t.value, st.security_id, st.with_currency
order by best_weight desc, s.security_id;

comment on view market.pending_statements is
  'Equities needing statements. The `no_currency` half requires a CIK: SEC is addressable only by one, and 0 securities without a CIK have ever received a sec-sourced statement. Without that gate 2,416 unsatisfiable securities starved the 3,328 SEC can serve, and the resource returned byte-identical results for days.';

grant select on market.pending_statements to service_role;

notify pgrst, 'reload schema';
