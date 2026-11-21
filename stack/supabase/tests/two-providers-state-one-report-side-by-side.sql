-- Nasdaq and Yahoo state the same report and the same quarter, and both rows are kept
-- (migration 20261122110000). Under the old keys the second writer overwrote the first, so the
-- serving views could never choose between them.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('nasdaq','Nasdaq',60) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;
insert into market.security (security_id, name, security_type_code)
values ('00000000-0000-0000-0000-00000000e6d1', 'E6D1', 'equity') on conflict (security_id) do nothing;

-- One report, one date, one symbol, two providers.
insert into market.earnings_calendar (source_code, symbol, report_date, security_id, eps_consensus)
values ('nasdaq',   'E6D1', '2026-11-24', '00000000-0000-0000-0000-00000000e6d1', 1.10),
       ('yfinance', 'E6D1', '2026-11-24', '00000000-0000-0000-0000-00000000e6d1', 1.12);

-- One quarter, two providers, two EPS bases.
insert into market.security_eps_history (security_id, period_ending, source_code, eps_actual)
values ('00000000-0000-0000-0000-00000000e6d1', '2026-09-30', 'nasdaq', 0.885),
       ('00000000-0000-0000-0000-00000000e6d1', '2026-09-30', 'yfinance', 8.85);

do $$
begin
  if (select count(*) from market.earnings_calendar where symbol = 'E6D1') <> 2 then
    raise exception 'both providers'' rows for one report must be kept';
  end if;
  if (select count(*) from market.security_eps_history
       where security_id = '00000000-0000-0000-0000-00000000e6d1') <> 2 then
    raise exception 'both providers'' rows for one quarter must be kept';
  end if;
  raise notice 'ok  two providers state one report and one quarter side by side';
end $$;

-- The same provider stating the same report twice is still one row.
do $$
begin
  begin
    insert into market.earnings_calendar (source_code, symbol, report_date)
    values ('nasdaq', 'E6D1', '2026-11-24');
    raise exception 'a provider''s second row for the same report must be refused';
  exception when unique_violation then
    raise notice 'ok  one provider, one report, one row';
  end;
end $$;

rollback;
