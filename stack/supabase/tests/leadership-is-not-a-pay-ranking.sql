-- THE CHIEF EXECUTIVE IS NOT WHOEVER WAS PAID MOST.
--
-- A leadership list ordered by pay alone puts whoever was granted the most equity that year at the
-- top. That is a real and common outcome — an incoming CFO's sign-on award, a founder taking $1 —
-- and it is not who runs the company. So `security_leadership` flags the CEO explicitly, and this
-- test makes the two orderings DISAGREE: the CEO here is paid LESS than a colleague, so a view that
-- merely sorted by pay would put the wrong person first and a fixture where the CEO is also the
-- best paid could not tell them apart.
--
-- The second thing pinned is the population bound. This resource costs one yfinance call per
-- security on a budget four other backlogs are already queued behind, so it is deliberately limited
-- to securities that are a meaningful fund holding. A security nobody holds must not be queued.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.data_source (code, name, priority) values ('yfinance-profile','yfinance company profile',95)
  on conflict (code) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZW','Boardland','ZW',false)
  on conflict (iso2) do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-000000011801','T118 Held','equity','ZW'),
  ('00000000-0000-0000-0000-000000011802','T118 Tiny','equity','ZW'),
  ('00000000-0000-0000-0000-000000011803','T118 Unheld','equity','ZW')
on conflict (security_id) do nothing;
insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker','T118A','00000000-0000-0000-0000-000000011801','yfinance-profile'),
  ('ticker','T118B','00000000-0000-0000-0000-000000011802','yfinance-profile'),
  ('ticker','T118C','00000000-0000-0000-0000-000000011803','yfinance-profile')
on conflict (kind_code, value) do nothing;

-- The fund itself is a security (`fund_holding.fund_id` references `security`), so the fixture
-- needs one to hold the others.
insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-0000000118ff','T118 Fund','equity','ZW')
on conflict (security_id) do nothing;
insert into market.data_source (code, name, priority) values ('sec-nport','SEC N-PORT filing',300)
  on conflict (code) do nothing;
insert into market.fund_holding (fund_id, security_id, as_of, weight, source_code) values
  -- A meaningful position, a trivial one, and nothing at all for the third security.
  ('00000000-0000-0000-0000-0000000118ff','00000000-0000-0000-0000-000000011801', current_date, 3.0,  'sec-nport'),
  ('00000000-0000-0000-0000-0000000118ff','00000000-0000-0000-0000-000000011802', current_date, 0.05, 'sec-nport')
on conflict do nothing;

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

  -- 3. A MEANINGFUL HOLDING IS QUEUED.
  select count(*) into n from market.pending_management where symbol = 'T118A';
  if n <> 1 then raise exception 'a security held at 3%% of a fund is not queued (% rows)', n; end if;

  -- 4. A TRIVIAL ONE IS NOT. This resource spends a yfinance call per security on a budget four
  --    other backlogs share; a 0.05%% position does not earn one.
  select count(*) into n from market.pending_management where symbol = 'T118B';
  if n <> 0 then raise exception 'a 0.05%% holding is queued — the population bound is not holding'; end if;

  -- 5. NOR ONE NO TRACKED FUND HOLDS AT ALL.
  select count(*) into n from market.pending_management where symbol = 'T118C';
  if n <> 0 then raise exception 'a security no fund holds is queued'; end if;

  -- 6. THE CURSOR IS NOT A NEGATIVE CACHE — six months, then ask again. Boards change.
  update market.security set management_fetched_at = now()
   where security_id = '00000000-0000-0000-0000-000000011801';
  select count(*) into n from market.pending_management where symbol = 'T118A';
  if n <> 0 then raise exception 'a security read just now is queued again immediately'; end if;

  update market.security set management_fetched_at = now() - interval '200 days'
   where security_id = '00000000-0000-0000-0000-000000011801';
  select count(*) into n from market.pending_management where symbol = 'T118A';
  if n <> 1 then raise exception 'a security read 200 days ago is NOT queued — the cursor has become permanent'; end if;
end $$;

rollback;

\echo 'ok: leadership is not a pay ranking'
