/**
 * Where each upstream lives — configurable so an HTTP cache can sit in front of it.
 *
 * WHY THIS EXISTS. Re-running a resource after fixing a parser used to mean re-fetching everything
 * from a rate-limited provider. With a caching proxy in front, the same run re-issues the same URLs
 * and is served from disk. Nothing here is cache LOGIC — these are hostnames, exactly as
 * `OPENBB_API_URL` already is (`index.ts`, `openbbFetcher(baseUrl)`). The TTLs, the keys and the
 * eviction all live in the proxy; a caller cannot tell whether it was served from cache.
 *
 * EVERY DEFAULT IS THE REAL ORIGIN, which is what makes the proxy optional: with none of these set
 * the functions talk to the providers directly, exactly as before. That is deliberate — a cache
 * that can take production down when it is removed is not worth having.
 *
 * READ LAZILY, NEVER AT MODULE SCOPE. A top-level `Deno.env.get` executes on import, so a module
 * that merely imports this one would demand `--allow-env` — which `logic-check.ts` deliberately
 * does not grant, because a network-free check that needs permissions to reach a pure parser has
 * defeated its own purpose. `edgar.ts` records the same trap for its User-Agent. These are
 * therefore FUNCTIONS, not consts, and calling one is what reads the environment.
 */

/** One origin, trailing slashes stripped so callers can always template `${origin()}/path`. */
function origin(envVar: string, fallback: string): string {
  const raw = Deno.env.get(envVar)
  return (raw && raw.trim() ? raw.trim() : fallback).replace(/\/+$/, '')
}

/** `www.sec.gov` — bulk files and the EDGAR archives (N-PORT `primary_doc.xml`). */
export const secWww = () => origin('SEC_WWW_BASE_URL', 'https://www.sec.gov')

/** `data.sec.gov` — submissions and the XBRL `companyfacts` API. */
export const secData = () => origin('SEC_DATA_BASE_URL', 'https://data.sec.gov')

/** `efts.sec.gov` — EDGAR full-text search, which is how a fund's filing is found. */
export const secFts = () => origin('SEC_FTS_BASE_URL', 'https://efts.sec.gov')

/** `api.openfigi.com` — ISIN -> ticker. POSTs, so the cache key must include the body. */
export const openFigi = () => origin('OPENFIGI_BASE_URL', 'https://api.openfigi.com')

/** `query2.finance.yahoo.com` — ISIN search and FX chart history. */
export const yahoo = () => origin('YAHOO_BASE_URL', 'https://query2.finance.yahoo.com')

/** `www.alphavantage.co` — historical EPS. 25 calls a DAY, so a cache hit here is worth the most. */
export const alphaVantage = () => origin('ALPHAVANTAGE_BASE_URL', 'https://www.alphavantage.co')

/** `api.tiingo.com` — splits and dividends. */
export const tiingo = () => origin('TIINGO_BASE_URL', 'https://api.tiingo.com')

/**
 * `query.wikidata.org` — SPARQL, ISIN -> the industries a crowd says a company is in.
 *
 * IT IS A POST, so the cache key must include the body — which it does, because `$body_key` is an
 * MD5 computed in Lua at SERVER level in `nginx.conf` and every location inherits it. `nginx`'s
 * own `$request_body` would be silently EMPTY for a large query (a 50-ISIN SPARQL body is a few
 * KB, well under the buffer, but the failure mode is silent and the MD5 costs nothing).
 *
 * This entry exists because it was MISSING and nothing could report that. `wikidata.ts` hardcoded
 * `https://query.wikidata.org/sparql`, so every run went straight out — and
 * `http-cache-covers-every-provider` passed, because it compares origins.ts against nginx.conf in
 * both directions and a provider that never entered origins.ts is in neither. The guard now also
 * fails on a hardcoded provider URL in the functions, which is the direction that was blind.
 */
export const wikidata = () => origin('WIKIDATA_BASE_URL', 'https://query.wikidata.org')

/**
 * DART (Korea). The cache in front of this is load-bearing rather than an optimisation: one filing
 * is 802 KB and takes 73.5 s from outside Korea, measured, against a 90 s worker. A filed document
 * is immutable, so the entry is good for ever — and with `proxy_ignore_client_abort on` a run that
 * gives up still leaves the next one an instant hit.
 */
export const dart = () => origin('DART_BASE_URL', 'https://opendart.fss.or.kr')
