-- `security_next_earnings` picks one row per company: an UPCOMING date over a past one, the most
-- recently fetched among upcoming ones, else the nearest past date (migration 20261122100000).
--
-- The fixture makes the candidate rules disagree:
--   e6c1  nasdaq upcoming (fetched today) and Yahoo's stale "next" date, already past: nasdaq;
--   e6c2  nasdaq past and Yahoo upcoming: Yahoo, so the choice is not by source;
--   e6c3  two upcoming dates, Yahoo's NEARER but fetched yesterday, nasdaq's later but fetched
--         today: nasdaq, so freshness decides among upcoming rows, not nearness;
--   e6c4  only past rows: the nearest past date.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('nasdaq','Nasdaq',60) on conflict (code) do nothing;
insert into market.data_source (code, name, priority) values ('yfinance','yfinance',100) on conflict (code) do nothing;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-00000000e6c1', 'E6C1', 'equity'),
  ('00000000-0000-0000-0000-00000000e6c2', 'E6C2', 'equity'),
  ('00000000-0000-0000-0000-00000000e6c3', 'E6C3', 'equity'),
  ('00000000-0000-0000-0000-00000000e6c4', 'E6C4', 'equity')
on conflict (security_id) do nothing;

-- Both providers name the company by the same symbol, which the provider key allows
-- (20261122110000).
insert into market.earnings_calendar (symbol, report_date, security_id, source_code, as_of)
values
  ('E6C1', current_date + 10, '00000000-0000-0000-0000-00000000e6c1', 'nasdaq',   now()),
  ('E6C1', current_date - 30, '00000000-0000-0000-0000-00000000e6c1', 'yfinance', now()),
  ('E6C2', current_date - 20, '00000000-0000-0000-0000-00000000e6c2', 'nasdaq',   now()),
  ('E6C2', current_date + 40, '00000000-0000-0000-0000-00000000e6c2', 'yfinance', now() - interval '3 days'),
  ('E6C3', current_date + 12, '00000000-0000-0000-0000-00000000e6c3', 'nasdaq',   now()),
  ('E6C3', current_date + 5,  '00000000-0000-0000-0000-00000000e6c3', 'yfinance', now() - interval '1 day'),
  ('E6C4', current_date - 60, '00000000-0000-0000-0000-00000000e6c4', 'nasdaq',   now()),
  ('E6C4', current_date - 15, '00000000-0000-0000-0000-00000000e6c4', 'yfinance', now());

do $$
declare got text;
begin
  select string_agg(concat(right(security_id::text, 4), ' ', source_code, ' ', report_date - current_date, ' ', upcoming::text),
                    ' | ' order by security_id)
    into got
    from market.security_next_earnings
   where security_id::text like '00000000-0000-0000-0000-00000000e6c_';
  if got is distinct from 'e6c1 nasdaq 10 true | e6c2 yfinance 40 true | e6c3 nasdaq 12 true | e6c4 yfinance -15 false' then
    raise exception 'the next earnings date must prefer an upcoming, freshly fetched row; got: %', got;
  end if;
  raise notice 'ok  upcoming over past, fresh over near, else the nearest past date';
end $$;

rollback;
