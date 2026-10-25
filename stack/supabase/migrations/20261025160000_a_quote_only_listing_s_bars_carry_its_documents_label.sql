-- A LISTING YAHOO ANSWERS ONLY WITH A QUOTE KEEPS ITS DOCUMENT'S LABEL ON ITS STORED BARS.
-- Decided by the user 2026-10-25 (umbrella docs/deferred/2026-10-25-a-listing-yahoo-answers-with-
-- one-point-keeps-its-openbb-label.md): such a listing is marked dead (muffin-ingest, `quote_only`),
-- and its stored bars are relabelled with the currency its own chart document states.
--
-- WHY. The chart lane labels a bar with the document's `meta.currency`, and stage 2 never publishes
-- a live quote. A listing Yahoo answers with nothing BUT its live quote therefore publishes no bar,
-- so nothing ever relabels the openbb bars it held before the chart lane, which carry that lane's
-- guessed label.
--
-- MEASURED 2026-10-25, over all 12,328 raw chart files (276 placeholders): 31 securities' newest
-- document holds only a live quote, and every one has had no bar for at least ten days (EA since
-- 08-10, AvalonBay 08-24, Warner Bros Discovery 10-02). 26 of them already carry their document's
-- label. These five do not:
--
--   PCTN.L    Picton Property Income   stored GBP   document GBp (pence: GBX)  close 70
--   SKBHF     Kelun-Biotech (OTC)      stored CNY   document USD
--   JTCPF     JTC PLC (OTC)            stored GBP   document USD
--   OLA.TO    Orla Mining              stored USD   document CAD
--   TTB-R.BK  TMBThanachart NVDR       stored none  document THB
--
-- A ONE-TIME REPAIR, not a rule: every bar published since the chart lane (2026-10-10) carries the
-- document's label, so only bars older than a security's first chart visit can be wrong this way.
-- Post-baseline migrations apply once, by version. On a database without these securities the
-- statement changes nothing.

update market.price_bar b
   set currency_code = v.currency_code
  from (values
          ('ba198ff3-57ec-4b85-b1de-70b4579ef4f7'::uuid, 'GBX'),
          ('b3103e79-1e98-46e2-bd28-16cab6fb633c'::uuid, 'USD'),
          ('4732a290-c05b-440f-bc05-0a12aea40a5d'::uuid, 'USD'),
          ('b1fc82f2-eca1-4490-a815-dc7fb32895e8'::uuid, 'CAD'),
          ('8be9d1c9-d35a-4cc4-8a9e-010e133664e9'::uuid, 'THB')
       ) as v (security_id, currency_code)
 where b.security_id = v.security_id
   and b.currency_code is distinct from v.currency_code
   and exists (select 1 from market.currency c where c.code = v.currency_code);
