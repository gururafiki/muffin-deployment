-- AN ANALYST ACTION NAMES ITS PROVIDER AND ITS MOMENT.
--
-- finviz's analyst actions retired on 2026-11-06 (migration 20261107100000), when finviz moved its
-- quote page. Their replacement, approved by the user on 2026-11-08 as designed in the umbrella's
-- docs/specs/2026-11-07-analyst-actions-from-yahoo.md (choices 1a, 2a, 3a), reads
-- `upgradeDowngradeHistory` from the Yahoo quoteSummary documents the company lane already stores.
-- No provider request.
--
-- WHY THE KEY CHANGES. `security_price_target` was keyed (security_id, published_date,
-- analyst_company), with no provider in it. Two things break that key:
--   * the rule that every ingested row names its provider, with the provider in the key where two
--     providers state one fact. finviz's frozen rows (49,025 over 2,843 securities, 2007-01-12 to
--     2026-10-28, measured 2026-11-08) and Yahoo's describe the same actions;
--   * Yahoo states one firm acting on one security twice in a day: 2 of AAPL's 971 actions, at
--     different seconds. The same firm at the same second never happens (0 of 971).
-- So the key becomes (security_id, source_code, published_at, analyst_company), on the action's
-- timestamp. finviz states a date only, so its rows take midnight UTC.
--
-- A TARGET IS IN THE QUOTE CURRENCY, so each row says which. finviz served US listings only, so its
-- rows are USD. Yahoo states analyst history mostly for US listings too (one action across 18
-- non-US fixtures), but where it states one the target is in the quote's own unit: pence for a
-- London line. The lane labels it as `security_estimate` does and withholds a code
-- `market.currency` does not hold.
--
-- THE APP READS A VIEW THAT PICKS. `security_analyst_action` serves each action once. A row is
-- hidden when a higher-priority source states an action by the same firm, on the same security, on
-- the same day, firm names compared without case. Yahoo (100) outranks finviz (90), so finviz's
-- rows stay as a backup (choice 3a) and show only where Yahoo has nothing for that day. They go at
-- a contract date like the other retired families.

alter table market.security_price_target
  add column if not exists published_at timestamptz,
  add column if not exists currency_code text references market.currency (code);

update market.security_price_target
   set published_at = published_date::timestamp at time zone 'UTC',
       currency_code = coalesce(currency_code, 'USD')
 where published_at is null;

alter table market.security_price_target alter column published_at set not null;

-- THE KEY SWAP. Building the unique index first and then swapping the constraint onto it holds an
-- ACCESS EXCLUSIVE lock only for the catalogue change.
create unique index if not exists security_price_target_action_key
  on market.security_price_target (security_id, source_code, published_at, analyst_company);

alter table market.security_price_target
  drop constraint if exists security_price_target_pkey,
  add constraint security_price_target_pkey primary key using index security_price_target_action_key;

-- The app asks for one security's newest actions.
drop index if exists market.security_price_target_recent_idx;
create index if not exists security_price_target_recent_idx
  on market.security_price_target (security_id, published_at desc);

create or replace view market.security_analyst_action as
select t.security_id,
       t.published_at,
       t.published_date,
       t.analyst_company,
       t.target_from,
       t.target_to,
       t.currency_code,
       t.status,
       t.rating_change,
       t.source_code
  from market.security_price_target t
 where not exists (
         select 1
           from market.security_price_target o
          where o.security_id = t.security_id
            and o.published_date = t.published_date
            and lower(o.analyst_company) = lower(t.analyst_company)
            and market.source_priority(o.source_code) > market.source_priority(t.source_code));

grant select on market.security_analyst_action to anon, authenticated, service_role;
