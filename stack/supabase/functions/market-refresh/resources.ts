// Pure helpers for market-refresh, with NO Supabase dependency.
//
// Split out from index.ts so the offline check (`logic-check.ts`) can drive them with nothing else
// running. What is left after the families moved to Dagster: the dedupe every `DO UPDATE` upsert
// needs, the throttle vocabulary the Wikidata resource reads, and the backlog TTL.

/**
 * Last-wins dedupe on the CONFLICT KEY, for anything about to be `upsert`ed with `DO UPDATE`.
 *
 * Postgres refuses an `INSERT ... ON CONFLICT DO UPDATE` whose statement contains the same conflict
 * key twice — `ON CONFLICT DO UPDATE command cannot affect row a second time` (SQLSTATE 21000). It
 * is not a warning and not a partial write: the whole statement fails, which fails the batch, which
 * fails the resource.
 *
 * MEASURED 2026-08-12, from the edge-runtime logs on the node:
 *   [Error] market-refresh(security-industries) failed:
 *           security_taxonomy upsert failed: ON CONFLICT DO UPDATE command cannot affect row a second time
 *
 * `pending_industry` yields one row per (security, level-1 sector), so a security classified into
 * two sectors is returned TWICE, fetched twice, and produces two identical
 * `(security_id, node_id, source_code)` writes. That is why the failure looked like it depended on
 * page size — the duplicated securities only fall inside the larger slices, so `limit` 10 and 20
 * succeeded while 40, 100 and 300 returned a bare 502.
 *
 * This is the THIRD time this shape has bitten: `ingest.ts` already dedupes fund holdings because
 * one filing lists a position in several lots, and the sector views had to `distinct on` for the
 * same reason. A provider list, a backlog view and a filing can all repeat a key; the upsert is
 * where that stops being harmless.
 *
 * `ignoreDuplicates: true` (DO NOTHING) has no such restriction, so those call sites are safe.
 */
export function dedupeBy<T>(rows: T[], key: (row: T) => string): T[] {
  const byKey = new Map<string, T>()
  for (const row of rows) byKey.set(key(row), row)
  return [...byKey.values()]
}

/**
 * Does this provider error say the provider is REFUSING us, rather than saying anything about the
 * symbol we asked for?
 *
 * Matched on the wire text because that is where the provider states it. Every entry was seen in a
 * real response from this deployment or is the standard HTTP spelling of the same thing; the list
 * is deliberately short, since a false positive here means a genuinely dead symbol is retried
 * forever, and a false negative means a rate limit is recorded as 20 unanswerable securities.
 */
export function throttled(message: string): boolean {
  const m = message.toLowerCase()
  return m.includes('ratelimit') ||
    m.includes('rate limit') ||
    m.includes('too many requests') ||
    m.includes('429') ||
    // WORDINGS PROVIDERS ACTUALLY USE, not the ones we expected them to. Tiingo says
    // "Error: You have run over your hourly request limit" — which matches NONE of the four above,
    // so six consecutive `security-corporate-actions` runs were rate-limited without
    // `throttledOut` ever being set, leaving the throttle-pressure panel and its alert blind to
    // that provider. The list above was a guess at vocabulary rather than a classifier; every
    // entry below is quoted from a body seen in production.
    m.includes('run over your') ||
    m.includes('request limit') ||
    m.includes('quota')
}

/**
 * TTL for the BACKLOG resources: the per-security queues the rotation drives.
 *
 * Short on purpose, and it costs nothing: an incremental resource with an empty backlog returns
 * without calling any provider, so the TTL only has to be long enough to avoid a pointless table
 * read. It has to be SHORT while a backlog exists, though — these have ~9,000 securities to work
 * through at ~1,000 a run, and a day-long TTL would stretch that over a week and a half.
 *
 * This is the same trap `security-tickers` fell into: it once carried the 7-day reference TTL, one
 * run resolved a page, and every run for the next week was told the data was fresh.
 */
export const BACKLOG_TTL_MINUTES = 10
