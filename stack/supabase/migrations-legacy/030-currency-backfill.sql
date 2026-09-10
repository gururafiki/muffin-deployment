-- Give every security we can a CURRENCY — IDEMPOTENT.
--
-- The statements card prefixes every figure with `$`, and the currency header is blank, because
-- `security_statement.currency` is null for every row: income/balance/cash carry no currency field
-- at all. Samsung's 2025 income statement is 97,146,675,000,000 KRW and reads "$97.15T".
--
-- `security.currency_code` was the obvious fallback and is populated for only 803 of 10,060 — it
-- comes from N-PORT's `curCd`, so only securities held by a tracked fund that reported one have it.
--
-- The metrics response DOES carry a currency (measured: USD for ZBH, GBP for SVT.L) and is already
-- stored in `security_fundamentals.raw`, covering 2,137 rows. Backfilling from it costs no request.
--
-- Deliberately does NOT overwrite an existing value: N-PORT's currency comes from a filing, the
-- provider's from an API, and a filing wins — the same rule `data_source.priority` applies
-- everywhere else here.

update market.security s
   set currency_code = f.raw->>'currency'
  from market.security_fundamentals f
 where f.security_id = s.security_id
   and s.currency_code is null
   and f.raw->>'currency' is not null
   and length(f.raw->>'currency') = 3
   -- The FK is to market.currency, so an unseen code would fail the whole statement rather than
   -- the one row. Learned the same way asset categories were: reject what the lookup cannot hold.
   and exists (select 1 from market.currency c where c.code = f.raw->>'currency');

-- Any currency the provider named that the lookup does not know yet, added so the next backfill
-- can use it rather than silently skipping those securities forever.
insert into market.currency (code)
select distinct f.raw->>'currency'
from market.security_fundamentals f
where f.raw->>'currency' is not null
  and length(f.raw->>'currency') = 3
on conflict (code) do nothing;

-- Second pass, now that the lookup knows them.
update market.security s
   set currency_code = f.raw->>'currency'
  from market.security_fundamentals f
 where f.security_id = s.security_id
   and s.currency_code is null
   and f.raw->>'currency' is not null
   and length(f.raw->>'currency') = 3;

notify pgrst, 'reload schema';
