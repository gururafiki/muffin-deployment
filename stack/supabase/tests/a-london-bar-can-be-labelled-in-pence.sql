-- A LONDON BAR CAN BE LABELLED IN PENCE.
--
-- The price lane labels each bar with the quote currency Yahoo states, and London's is `GBp`, which
-- it maps to `GBX` (muffin-ingest `facets.price_chart`). `price_bar.currency_code` references
-- `market.currency`, so without the row seeded by 20261010160000 every London bar would either
-- fail the whole write on the foreign key or, as the lane now chooses, carry no label at all.
--
-- Mutation: delete that migration and the insert below fails on `price_bar_currency_code_fkey`.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance', 'yfinance', 100)
  on conflict (code) do nothing;
insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-000000161001', 'T161 Vodafone-like', 'equity')
on conflict (security_id) do nothing;

insert into market.price_bar (security_id, trade_date, close, volume, currency_code, source_code)
values ('00000000-0000-0000-0000-000000161001', '2026-10-09', 124.4, 1, 'GBX', 'yfinance');

do $$
begin
  if not exists (select 1 from market.price_bar
                  where security_id = '00000000-0000-0000-0000-000000161001'
                    and currency_code = 'GBX') then
    raise exception 'a bar labelled in pence was not stored';
  end if;
end $$;

rollback;
