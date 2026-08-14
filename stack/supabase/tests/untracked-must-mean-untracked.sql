-- A listing the universe already tracks must NOT appear in `untracked_listing`.
--
-- WHY THIS EXISTS AS A TEST. The view was wrong for months and nothing noticed, because nothing
-- read it: it excluded a listing only when a `security_identifier` of kind `figi` matched, and only
-- **547 of 27,628** securities have one. It therefore answered "listings whose composite FIGI we
-- have not happened to store", which reads exactly like "listings we do not track" and is a
-- different question — 9,976 tracked companies sat in it, Samsung Electronics among them.
--
-- On an empty database the view returns nothing and every join is unexercised, so applying the
-- migration proves none of this. The four rows below are the four ways a security is identified in
-- this schema, and the last one is the reason the shortcut was refused:
--
--   1. tracked by composite FIGI       the original rule, still exact where it applies
--   2. tracked by provider symbol      how we address the price provider — 6,315 of the matches
--   3. tracked by resolved ticker      OpenFIGI's US line, e.g. SSNLF — 5,498 of them
--   4. a LOCAL ticker that collides    `005930` on Seoul vs an unrelated US `005930`. Matching on
--      with an unrelated US ticker     the bare ticker would hide it; matching whole symbol to
--                                      whole symbol cannot, so this row must still be listed.

\set ON_ERROR_STOP on

begin;

insert into market.security (security_id, name, security_type_code) values
  ('00000000-0000-0000-0000-0000000062a1', 'T62 By figi',     'equity'),
  ('00000000-0000-0000-0000-0000000062a2', 'T62 By provider', 'equity'),
  ('00000000-0000-0000-0000-0000000062a3', 'T62 By ticker',   'equity'),
  ('00000000-0000-0000-0000-0000000062a4', 'T62 Bare ticker', 'equity')
on conflict (security_id) do nothing;

insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-0000000062a1', 'figi',   'BBG00T62FIGI'),
  ('00000000-0000-0000-0000-0000000062a3', 'ticker', 'T62TICK'),
  -- The collision case: this security's ticker is the BARE local ticker of a foreign listing.
  ('00000000-0000-0000-0000-0000000062a4', 'ticker', '005930')
on conflict (kind_code, value) do nothing;

insert into market.security_provider_symbol (security_id, provider_code, symbol) values
  ('00000000-0000-0000-0000-0000000062a2', 'yfinance', 'T62PROV.KS')
on conflict (security_id, provider_code) do nothing;

insert into market.exchange_listing
  (figi, composite_figi, exch_code, ticker, name, country_iso2, provider_symbol) values
  ('BBG00T62L001', 'BBG00T62FIGI', 'KS', 'T62F',   'T62 By figi listing',     'KR', 'T62F.KS'),
  ('BBG00T62L002', 'BBG00T62X002', 'KS', 'T62P',   'T62 By provider listing', 'KR', 'T62PROV.KS'),
  ('BBG00T62L003', 'BBG00T62X003', 'US', 'T62TICK','T62 By ticker listing',   'US', 'T62TICK'),
  -- Seoul's 005930: its provider_symbol is `005930.KS`, which matches NOTHING tracked. It must be
  -- listed as untracked even though its bare ticker equals a tracked US ticker.
  ('BBG00T62L004', 'BBG00T62X004', 'KS', '005930', 'T62 Bare ticker listing', 'KR', '005930.KS')
on conflict (figi) do nothing;

do $$
declare
  bad text;
begin
  select string_agg(format('%s: %s, expected %s', e.name,
                           case when u.figi is null then 'excluded' else 'listed' end, e.want), '; ')
    into bad
  from (values
    ('BBG00T62L001', 'T62 By figi listing',     'excluded'),
    ('BBG00T62L002', 'T62 By provider listing', 'excluded'),
    ('BBG00T62L003', 'T62 By ticker listing',   'excluded'),
    ('BBG00T62L004', 'T62 Bare ticker listing', 'listed')
  ) e(figi, name, want)
  left join market.untracked_listing u on u.figi = e.figi
  where (case when u.figi is null then 'excluded' else 'listed' end) is distinct from e.want;

  if bad is not null then
    raise exception 'untracked_listing does not mean untracked: %', bad;
  end if;
  raise notice 'ok  a tracked listing is excluded by figi, provider symbol OR ticker — and a bare-ticker collision is not';
end $$;

rollback;
