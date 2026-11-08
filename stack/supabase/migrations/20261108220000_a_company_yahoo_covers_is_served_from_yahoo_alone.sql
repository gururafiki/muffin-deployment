-- A COMPANY YAHOO COVERS IS SERVED FROM YAHOO ALONE.
--
-- `security_analyst_action` (migration 20261108210000) hid a finviz row only where Yahoo stated
-- the same firm, on the same security, on the same day. The first live run, over AAPL, MSFT, NVDA
-- and TSM, showed that the two providers do not name a firm the same way. Measured 2026-11-08: of
-- the 42 finviz rows that still showed, 29 had a Yahoo action within three days at the same target
-- under another spelling:
--   BofA Securities / B of A Securities        KeyBanc Capital Markets / Keybanc
--   Evercore ISI / Evercore ISI Group          Rothschild & Co Redburn / Rothschild & Co
--   Robert W. Baird / Baird                    The Benchmark Company / Benchmark
--   RBC Capital Mkts / RBC Capital             HSBC Securities / HSBC
-- and some a day apart (Stifel on MSFT: finviz 04-30, Yahoo 05-01). So the same action showed twice,
-- and no matching rule short of an authored alias table could prevent it.
--
-- The approved rule is "Yahoo first, finviz behind it" (choice 3a). Applied per COMPANY: a source's
-- rows show for a company only when no higher-priority source holds any row for it. Yahoo's
-- history runs back to 2012 (AAPL 979 actions against finviz's 23), so a covered company loses
-- only the few actions finviz alone recorded, frozen since 2026-10-28 and kept in the table until
-- the contract date. finviz's rows still serve every company Yahoo states nothing for.

-- A WINDOW OVER THE COMPANY, NOT AN ANTI-JOIN. "No higher-priority row for this company" as a
-- NOT EXISTS checks every pair of the company's rows, calling `source_priority()` for each: about a
-- million calls for AAPL's ~1,000 actions, 147-168 ms as anon, and growing with the square of the
-- history. The company's best priority computed once, partitioned by the column the app filters
-- on, keeps the read linear, and the filter still reaches below the window (migration
-- 20261017140000's rule: the key a view is read by must be in the window's PARTITION BY).
create or replace view market.security_analyst_action as
select security_id,
       published_at,
       published_date,
       analyst_company,
       target_from,
       target_to,
       currency_code,
       status,
       rating_change,
       source_code
  from (select t.*,
               ds.priority,
               max(ds.priority) over (partition by t.security_id) as best
          from market.security_price_target t
          join market.data_source ds on ds.code = t.source_code) ranked
 where priority = best;
