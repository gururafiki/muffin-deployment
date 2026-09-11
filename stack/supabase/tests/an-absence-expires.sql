-- AN ABSENCE EXPIRES, AND THE QUERY THAT READS IT MUST SAY SO.
--
-- `ingest.mark_absent` sets `next_due_at = now() + facet.absent_ttl` precisely so a 30-day mark is
-- thirty days and not for ever: a security can gain a listing, and a symbol repair must be allowed
-- to prove the provider wrong. This schema has already paid for the other behaviour — 1,369
-- ordinary tickers were negative-cached in one afternoon of throttling, and ~8,300 securities
-- across six resources on another.
--
-- The reader is `muffin_ingest.facets.prices.ASKABLE_SUBJECTS`, which excludes a security whose
-- `prices` task is absent. Its first version joined on `status = 'absent'` ALONE, which makes the
-- exclusion permanent and turns every mark into a life sentence — with nothing anywhere able to
-- report it, because the mark is honest and only its expiry is missing.
--
-- THE FIXTURE MAKES THE TWO RULES DISAGREE. One security is marked absent with an UNEXPIRED
-- `next_due_at` and one with an EXPIRED one; a join that ignores the date returns neither, and the
-- correct one returns exactly the expired one. A third security is never marked at all, so
-- "excludes everything" cannot pass either.

\set ON_ERROR_STOP on

begin;

insert into market.security_type (code, name) values ('equity','Equity') on conflict do nothing;
insert into market.countries (iso2, name, flag, drillable) values ('ZX','Expiryland','ZX',false)
  on conflict (iso2) do nothing;
insert into market.identifier_kind (code, name) values ('ticker','Ticker') on conflict do nothing;

insert into market.security (security_id, name, security_type_code, country_iso2) values
  ('00000000-0000-0000-0000-00000000e001','X1 Unexpired','equity','ZX'),
  ('00000000-0000-0000-0000-00000000e002','X2 Expired','equity','ZX'),
  ('00000000-0000-0000-0000-00000000e003','X3 Never marked','equity','ZX')
  on conflict (security_id) do nothing;

-- `security_symbol` is a view over identifiers and listings, so the symbol has to come from one.
insert into market.security_identifier (security_id, kind_code, value) values
  ('00000000-0000-0000-0000-00000000e001','ticker','XONE'),
  ('00000000-0000-0000-0000-00000000e002','ticker','XTWO'),
  ('00000000-0000-0000-0000-00000000e003','ticker','XTHR')
  on conflict do nothing;

insert into ingest.provider_budget (provider_code, rate_per_sec, control_subject)
  values ('zx-provider', 1.0, 'XONE') on conflict (provider_code) do nothing;

insert into ingest.facet
  (facet, family, asset, provider_code, key_kind, grain, ttl, absent_ttl,
   population_sql, retract_sql, enabled)
values
  ('zx-prices','test','zx_asset','zx-provider','symbol','security',
   interval '1 day', interval '30 days',
   -- NAMED COLUMNS: `sync_population` selects `p.subject` from this, so positional aliases fail
   -- with "column subject does not exist", which names the symptom rather than the contract.
   'select security_id::text as subject, security_id, 0::numeric as priority,'
   ' 1::numeric as entity_rank from market.security where country_iso2 = ''ZX''',
   'select 1', true)
  on conflict (facet) do nothing;

select ingest.sync_population('zx-prices');

-- One mark still inside its TTL, one that has run out. Written directly because `mark_absent`
-- deliberately refuses without a justifying attempt — what is under test here is the READER.
update ingest.task set status = 'absent', next_due_at = now() + interval '10 days'
 where facet = 'zx-prices' and subject = '00000000-0000-0000-0000-00000000e001';
update ingest.task set status = 'absent', next_due_at = now() - interval '1 day'
 where facet = 'zx-prices' and subject = '00000000-0000-0000-0000-00000000e002';

do $$
declare
  askable text[];
begin
  -- THE SHIPPED PREDICATE, copied from `ASKABLE_SUBJECTS` — the `status` AND the date together.
  select array_agg(s.security_id::text order by s.security_id)
    into askable
    from market.security s
    join market.security_symbol sym on sym.security_id = s.security_id
    left join ingest.task t
           on t.facet = 'zx-prices' and t.security_id = s.security_id
          and t.status = 'absent' and t.next_due_at > now()
   where s.country_iso2 = 'ZX'
     and t.subject is null;

  if askable is distinct from array[
       '00000000-0000-0000-0000-00000000e002',
       '00000000-0000-0000-0000-00000000e003'] then
    raise exception
      'askable should be the EXPIRED mark and the unmarked security, got %', askable;
  end if;

  -- And the rule that ignores the date returns NEITHER marked security, which is the defect: the
  -- expired one is locked out for ever.
  select array_agg(s.security_id::text order by s.security_id)
    into askable
    from market.security s
    join market.security_symbol sym on sym.security_id = s.security_id
    left join ingest.task t
           on t.facet = 'zx-prices' and t.security_id = s.security_id
          and t.status = 'absent'
   where s.country_iso2 = 'ZX'
     and t.subject is null;

  if askable is distinct from array['00000000-0000-0000-0000-00000000e003'] then
    raise exception
      'the date-blind rule was expected to lock out BOTH marked securities, got % — if this no '
      'longer holds the fixture has stopped distinguishing the two rules', askable;
  end if;

  raise notice 'an absence expires: the 30-day mark is thirty days, not a life sentence';
end $$;

rollback;
