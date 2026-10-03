-- THE SEGMENT SPINE RECORDS ITS OWN REFRESH.
--
-- It refreshes from a pg_cron job, which writes no `refresh_run` row, so the samples this
-- function writes are the only record that it ran: market-verify's spine check, the dashboard
-- panel and the staleness alert all read them (20261003190000). If the insert went, a healthy
-- spine and a frozen one would look the same, which is the ten days this replaced.

\set ON_ERROR_STOP on

begin;

select * from market.refresh_segment_spine();

do $$
declare
  stamps int;
  dur numeric;
  n numeric;
begin
  select count(distinct sampled_at) into stamps
    from market.universe_sample
   where metric in ('segment_spine.duration_ms', 'segment_spine.rows')
     and sampled_at >= now();
  if stamps <> 1 then
    raise exception 'one refresh must be one sample (one timestamp for both rows), got % timestamps', stamps;
  end if;
  select value into dur from market.universe_sample
   where metric = 'segment_spine.duration_ms' and sampled_at >= now();
  select value into n from market.universe_sample
   where metric = 'segment_spine.rows' and sampled_at >= now();
  if dur is null or dur < 0 then
    raise exception 'the refresh must record a duration, got %', dur;
  end if;
  if n is distinct from (select count(*) from market.security_segment_spine) then
    raise exception 'the recorded row count (%) must be the spine''s own', n;
  end if;
  raise notice 'ok  the segment spine records its own refresh (% ms, % rows)', dur, n;
end $$;

rollback;
