-- THE CHIEF EXECUTIVE IS NOT WHOEVER WAS PAID MOST.
--
-- A leadership list ordered by pay alone puts whoever was granted the most equity that year at the
-- top. That is a real and common outcome — an incoming CFO's sign-on award, a founder taking $1 —
-- and it is not who runs the company. So `security_leadership` flags the CEO explicitly, and this
-- test makes the two orderings DISAGREE: the CEO here is paid LESS than a colleague, so a view that
-- merely sorted by pay would put the wrong person first and a fixture where the CEO is also the
-- best paid could not tell them apart.
--
-- Its second half, the population bound of `pending_management`, left with the edge handler on
-- 2026-10-24.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance-profile','yfinance company profile',95)
  on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Boardland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000011801','T118 Held','equity','ZW')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T118A','00000000-0000-0000-0000-000000011801','yfinance-profile')
on conflict (kind_code, value) do nothing;

-- THE CEO IS PAID LESS THAN THE CFO. Deliberate: a pay ranking gets this wrong.
insert into market.security_officer (security_id, name, title, pay, source_code) values
  ('00000000-0000-0000-0000-000000011801','Ada Lovelace','Chief Executive Officer', 1000000,'yfinance-profile'),
  ('00000000-0000-0000-0000-000000011801','Grace Hopper','Chief Financial Officer', 9000000,'yfinance-profile'),
  ('00000000-0000-0000-0000-000000011801','Alan Turing','Chief Technology Officer', 4000000,'yfinance-profile')
on conflict do nothing;

do $$
declare n integer; who text;
begin
  -- 1. THE CEO IS FLAGGED, and it is the person with the title rather than the pay.
  select name into who from market.security_leadership
   where security_id = '00000000-0000-0000-0000-000000011801' and is_ceo;
  if who is distinct from 'Ada Lovelace' then
    raise exception 'the flagged chief executive is %, expected Ada Lovelace — the best-paid officer here is the CFO, and a pay ranking would name her', coalesce(who,'<none>');
  end if;

  -- 2. AND ONLY ONE PERSON IS FLAGGED. A title match too loose ("officer") would flag all three.
  select count(*) into n from market.security_leadership
   where security_id = '00000000-0000-0000-0000-000000011801' and is_ceo;
  if n <> 1 then raise exception '% officers are flagged as chief executive, expected 1', n; end if;

end $$;

rollback;

\echo 'ok: leadership is not a pay ranking'
