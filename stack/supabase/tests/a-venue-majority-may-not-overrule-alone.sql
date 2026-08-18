-- A venue's majority currency may NOT relabel a security on its own.
--
-- WHY THIS IS A TEST. The first version of migration 74 did exactly that, and measuring it before
-- it landed showed it would rewrite **233 securities of which only ~20 were wrong**. The deploy
-- carrying it was cancelled mid-run and the nightly backup confirmed 0 of 27,629 currencies had
-- changed. Nothing protects against it coming back except this.
--
-- Two whole classes of legitimate data fail a majority vote, and both are represented below:
--
--   * MULTI-CURRENCY VENUES. Hong Kong genuinely has HKD, CNY and USD counters; Toronto and SIX
--     list USD-denominated securities. The minority is real, not a defect.
--   * SUBUNIT VENUES. Johannesburg quotes in CENTS (ZAC) and Kuwait in FILS (KWF). Relabelling to
--     the parent is a 100x or 1000x error — the same class of mistake as reading Tel Aviv agorot
--     as shekels.
--
-- The rule that IS supported: a USD claim on a non-US venue with a market cap above $2tn. The
-- largest real company is ~$5.5tn and US-listed, and NVDA is REAL while sitting BETWEEN two fakes
-- — so magnitude alone cannot be the test either. Only both signals together.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity', 'Equity') on conflict do nothing;
insert into market.currency (code) values ('USD'), ('HKD'), ('CNY'), ('IDR')
  on conflict do nothing;
insert into market.data_source (code, name) values ('yfinance', 'yfinance') on conflict do nothing;
insert into market.identifier_kind (code, name) values ('ticker', 'Ticker') on conflict do nothing;

-- A Hong Kong venue with a decisive CNY majority (5 CNY, 1 HKD) — enough to satisfy
-- `venue_currency`'s 5-row / 60% threshold, so the dangerous rule WOULD have fired here.
insert into market.security (security_id, name, security_type_code, currency_code, market_cap) values
  ('00000000-0000-0000-0000-0000000074a1', 'T74 HK cny 1', 'equity', 'CNY', 1e9),
  ('00000000-0000-0000-0000-0000000074a2', 'T74 HK cny 2', 'equity', 'CNY', 1e9),
  ('00000000-0000-0000-0000-0000000074a3', 'T74 HK cny 3', 'equity', 'CNY', 1e9),
  ('00000000-0000-0000-0000-0000000074a4', 'T74 HK cny 4', 'equity', 'CNY', 1e9),
  ('00000000-0000-0000-0000-0000000074a5', 'T74 HK cny 5', 'equity', 'CNY', 1e9),
  -- The legitimate minority: a genuine HKD counter with an ordinary market cap.
  ('00000000-0000-0000-0000-0000000074b1', 'T74 HK hkd legit', 'equity', 'HKD', 2.4e9),
  -- The real defect: USD claimed with a cap four times world GDP.
  ('00000000-0000-0000-0000-0000000074c1', 'T74 HK impossible', 'equity', 'USD', 4.4e14)
on conflict (security_id) do nothing;

insert into market.security_identifier (kind_code, value, security_id, source_code) values
  ('ticker', 'T74A1.XX', '00000000-0000-0000-0000-0000000074a1', 'yfinance'),
  ('ticker', 'T74A2.XX', '00000000-0000-0000-0000-0000000074a2', 'yfinance'),
  ('ticker', 'T74A3.XX', '00000000-0000-0000-0000-0000000074a3', 'yfinance'),
  ('ticker', 'T74A4.XX', '00000000-0000-0000-0000-0000000074a4', 'yfinance'),
  ('ticker', 'T74A5.XX', '00000000-0000-0000-0000-0000000074a5', 'yfinance'),
  ('ticker', 'T74B1.XX', '00000000-0000-0000-0000-0000000074b1', 'yfinance'),
  ('ticker', 'T74C1.XX', '00000000-0000-0000-0000-0000000074c1', 'yfinance')
on conflict (kind_code, value) do nothing;

-- 1. The venue's majority is CNY — the view describes it correctly.
do $$
declare q text;
begin
  select quote_currency into q from market.venue_currency where suffix = '.XX';
  if q is distinct from 'CNY' then
    raise exception 'venue_currency should report CNY for .XX, got %', coalesce(q, '<none>');
  end if;
end $$;

-- The migration's own one-shot ran long before these fixtures existed, so it cannot have acted on
-- them. The repair logic is therefore re-executed here against the seeded shape — the same reason
-- `securities-are-typed-from-the-filing.sql` re-runs its migration rather than trusting that
-- applying to an empty database proved anything about a backfill.
with impossible as (
  select s.security_id, s.currency_code as previous_code, vc.quote_currency as new_code
    from market.security s
    join market.security_symbol sym on sym.security_id = s.security_id
    join market.venue_currency vc
      on vc.suffix = substring(sym.symbol from position('.' in sym.symbol))
   where s.currency_code = 'USD'
     and vc.quote_currency <> 'USD'
     and s.market_cap > 2e12
     and position('.' in sym.symbol) > 0
),
logged as (
  insert into market.currency_repair (security_id, previous_code, new_code, reason)
  select security_id, previous_code, new_code, 'test re-run of the migration 74 repair'
    from impossible
  returning security_id, new_code
)
update market.security s
   set currency_code = l.new_code
  from logged l
 where s.security_id = l.security_id;

-- 2. THE LEGITIMATE MINORITY SURVIVES. This is the assertion that the dangerous version failed:
--    a genuine HKD counter on a CNY-majority venue, with an ordinary market cap, must keep HKD.
do $$
declare c text;
begin
  select currency_code into c from market.security
   where security_id = '00000000-0000-0000-0000-0000000074b1';
  if c is distinct from 'HKD' then
    raise exception
      'a legitimate minority currency was relabelled to % — a venue majority describes what is COMMON, not what is POSSIBLE, and Hong Kong really does have HKD, CNY and USD counters', c;
  end if;
end $$;

-- 3. Nothing with an ordinary market cap was touched at all.
do $$
declare n integer;
begin
  select count(*) into n from market.currency_repair
   where security_id in ('00000000-0000-0000-0000-0000000074a1',
                         '00000000-0000-0000-0000-0000000074b1');
  if n <> 0 then
    raise exception 'a security with an ordinary market cap was repaired (% rows) — only an impossible cap justifies overruling the provider', n;
  end if;
end $$;

-- 4. AND THE REAL DEFECT IS STILL CAUGHT, or the narrowing went too far.
--    (Applied by the re-run above, against the fixtures the one-shot never saw.)
do $$
declare c text; logged integer;
begin
  select currency_code into c from market.security
   where security_id = '00000000-0000-0000-0000-0000000074c1';
  select count(*) into logged from market.currency_repair
   where security_id = '00000000-0000-0000-0000-0000000074c1';

  if c = 'USD' then
    raise exception
      'the impossible USD cap (4.4e14, four times world GDP) was NOT relabelled — the narrowing removed the fix along with the danger';
  end if;

  -- A CHANGE WITHOUT A RECORD IS THE ORIGINAL SIN. The first version overwrote 233 rows with no
  -- trace of the prior value and was recoverable only because an unrelated table happened to keep
  -- the provider's claim. Asserted unconditionally: the currency changed, so it MUST be logged.
  -- (Checking this only `if logged > 0` was the first version of this assertion, and it passed a
  -- mutation that deleted the logging entirely — the condition assumed what it was meant to test.)
  if logged = 0 then
    raise exception
      'the currency was changed to % with NO row in currency_repair — a repair that cannot be undone from the database itself is not a repair', c;
  end if;
  if not exists (
    select 1 from market.currency_repair
     where security_id = '00000000-0000-0000-0000-0000000074c1'
       and previous_code = 'USD'
  ) then
    raise exception 'the repair recorded no previous_code, so the change cannot be reversed';
  end if;
end $$;

rollback;
