CREATE OR REPLACE FUNCTION market.prune_news(p_days integer DEFAULT 90)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
declare v_deleted integer := 0;
begin
  -- The join rows go with the article via `on delete cascade`, so pruning the article is enough.
  -- Deleting the LINKS first and the articles second would leave orphans on any partial failure.
  delete from market.news_article
   where published_at < now() - make_interval(days => p_days);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$function$;
