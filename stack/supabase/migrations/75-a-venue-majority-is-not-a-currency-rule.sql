-- MIGRATION 74 WAS WRONG, AND THIS UNDOES MOST OF IT.
--
-- 74 relabelled a security's currency whenever it disagreed with its venue's MAJORITY currency,
-- derived from our own data. The .JK evidence that motivated it was real — 72 IDR against 24 USD,
-- and the 24 were genuinely wrong. **The generalisation was not.** Measured before it landed, the
-- rule would have relabelled **233 securities, of which only 20 were actually wrong**:
--
--   732.HK    HKD -> CNY   Hong Kong genuinely has HKD, CNY and USD counters. HKD was CORRECT.
--   SSW.JO    ZAC -> ZAR   Johannesburg quotes in CENTS. Relabelling makes the cap 100x wrong.
--   ZAIN.KW   KWF -> KWD   Kuwait quotes in FILS. Same 1000x error.
--   BBD/B.TO  USD -> CAD   Toronto genuinely lists USD-denominated securities.
--   1CG.SW    USD -> CHF   SIX genuinely lists USD and EUR lines.
--
-- Two whole classes of legitimate data fail a majority vote: exchanges with real multi-currency
-- listings, and exchanges quoted in a SUBUNIT where both the subunit and its parent appear. A
-- majority is a statement about what is COMMON on a venue, and this needed a statement about what
-- is POSSIBLE — which is not the same question.
--
-- I verified the Jakarta case and generalised without verifying the generalisation. The measurement
-- that would have caught it took one query and was run only after the code was written.
--
-- THE NARROW RULE, which is all the evidence ever supported: a market cap that would make a
-- company larger than any that has ever existed is not a market cap in the currency claimed. The
-- largest real company is ~$5.5tn (NVDA, and it is REAL — it sits between two fakes, which is why
-- magnitude alone cannot be the test either). $2tn is used as the floor only in combination with a
-- venue suffix, because nothing outside the US that is genuinely quoted in USD comes close.
--
-- `venue_currency` is KEPT. It is a correct and useful description of what a venue commonly trades
-- in; it is simply not licensed to overrule a provider on its own.

-- ── restore what 74 changed ───────────────────────────────────────────────────────────────────
--
-- From `security_fundamentals.raw.currency`, which is the provider's ORIGINAL claim and was never
-- touched. That is the only faithful record of what the currency was before 74 rewrote it — and it
-- is why a destructive repair should carry its own undo, which 74 did not.
do $$
declare
  restored bigint;
begin
  if exists (select 1 from market.one_shot where key = '75-restore-provider-currency') then
    return;
  end if;

  update market.security s
     set currency_code = upper(f.raw ->> 'currency')
    from market.security_fundamentals f
   where f.security_id = s.security_id
     and f.raw ? 'currency'
     and upper(f.raw ->> 'currency') ~ '^[A-Z]{3}$'
     and s.currency_code is distinct from upper(f.raw ->> 'currency')
     -- Only where the provider's code is one we know, or the foreign key rejects the statement and
     -- takes the whole migration with it.
     and exists (select 1 from market.currency c where c.code = upper(f.raw ->> 'currency'));

  get diagnostics restored = row_count;

  insert into market.one_shot (key, reason) values
    ('75-restore-provider-currency',
     format('Restored %s securities to the provider''s own currency after migration 74 relabelled '
            || '233 by venue majority, of which only ~20 were wrong. HKD on Hong Kong, ZAC on '
            || 'Johannesburg and KWF on Kuwait are all CORRECT and were being overwritten.', restored));
end $$;

-- ── then the narrow, evidence-supported correction ────────────────────────────────────────────
--
-- A non-US venue claiming USD with a cap above $2tn. Every observed case is 10x-200x over that,
-- and nothing genuinely quoted in USD outside the US approaches it. Deliberately conservative:
-- this leaves subtler mislabels in place rather than risking a repeat of 74.
do $$
declare
  fixed bigint;
begin
  if exists (select 1 from market.one_shot where key = '75-relabel-impossible-usd-caps') then
    return;
  end if;

  with impossible as (
    select s.security_id, vc.quote_currency
      from market.security s
      join market.security_symbol sym on sym.security_id = s.security_id
      join market.venue_currency vc
        on vc.suffix = substring(sym.symbol from position('.' in sym.symbol))
     where s.currency_code = 'USD'
       and vc.quote_currency <> 'USD'
       and s.market_cap > 2e12
       and position('.' in sym.symbol) > 0
  )
  update market.security s
     set currency_code = i.quote_currency
    from impossible i
   where s.security_id = i.security_id;

  get diagnostics fixed = row_count;

  insert into market.one_shot (key, reason) values
    ('75-relabel-impossible-usd-caps',
     format('Relabelled %s securities claiming USD on a non-US venue with a market cap above $2tn. '
            || 'The largest real company is ~$5.5tn and it is US-listed, so a suffixed symbol at '
            || 'this scale is a unit error, not a company. PT Barito read $442tn — 4x world GDP.', fixed));
end $$;

notify pgrst, 'reload schema';
