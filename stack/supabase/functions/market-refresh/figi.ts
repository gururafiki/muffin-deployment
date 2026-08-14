// ISIN -> ticker, via OpenFIGI.
//
// WHY THIS IS NEEDED AT ALL. N-PORT identifies a holding by ISIN/CUSIP/LEI and almost never by
// ticker, so 9,786 ingested securities arrive with no symbol — they cannot be linked to a stock
// page or priced. Nothing already in the stack bridges that gap: OpenBB's `equity/search` returns
// ZERO hits for an ISIN (measured against the deployed image on both a US and an Irish ISIN), and
// `equity/profile` does not return an ISIN either, so it cannot be joined from the other side.
//
// OpenFIGI is Bloomberg's open symbology service and is the standard answer: free, no key needed
// for low volume, and it maps in BULK. `US0378331005 -> AAPL`, `IE00B4BNMY34 -> ACN`.
//
// RATE LIMITS shape the whole design — anonymous is 25 requests/minute at 10 jobs each, a key
// (free, instant) raises it to 250 x 100. So this resource is INCREMENTAL by construction: it
// resolves the most visible securities first and leaves the rest for the next run, rather than
// trying to do 9,786 in one worker.

import { pickLocalSymbol, type VenueMap } from './exchanges.ts';

const ENDPOINT = 'https://api.openfigi.com/v3/mapping';

/** Anonymous limits. A key lifts both, which is why they are read at call time, not baked in. */
const ANON_JOBS_PER_REQUEST = 10;
const KEYED_JOBS_PER_REQUEST = 100;

export interface FigiRequest {
  securityId: string;
  isin: string;
  /** Set for a LOCAL lookup: the country whose venue we want, e.g. 'KR' -> `005930.KS`. */
  countryIso2?: string;
}
export interface FigiResult {
  securityId: string;
  ticker: string;
  exchCode?: string;
  securityType?: string;
  /**
   * The issuer name OpenFIGI holds, which arrives in the SAME response as the ticker and was being
   * discarded. It is the only route to a usable name for the 28 securities N-PORT reports as
   * `New Issuer: BB Company ID:<n>` — a filer placeholder, not a company, which the app would
   * render verbatim. Measured 2026-08-13: INE377Y01014 -> BAJAJ HOUSING FINANCE LTD,
   * AEE01569T248 -> TALABAT HOLDING PLC, INE379A01028 -> ITC HOTELS LIMITED.
   */
  name?: string;
}

export interface LocalSymbolResult {
  securityId: string;
  /** yfinance-addressable, suffix included. */
  symbol: string;
  /** Joins the security to `market.exchange_listing`, which carries no ISIN. */
  compositeFigi?: string;
}

interface FigiJob {
  idType: 'ID_ISIN';
  idValue: string;
  exchCode?: string;
}

/**
 * Resolve a batch of ISINs to tickers.
 *
 * `exchCode: 'US'` is deliberate. Without it an ISIN can return 138 matches (Toyota resolves on
 * every exchange that lists it), and picking one of those arbitrarily would attach a symbol the
 * price provider does not know. Restricting to the US listing yields at most a couple of rows and
 * matches what the app can actually price today; non-US local lines need an exchange -> provider
 * suffix map and are deliberately out of scope (see todos.md).
 */
export async function mapIsinsToTickers(
  requests: FigiRequest[],
  opts: {
    apiKey?: string
    maxRequests?: number
    budgetMs?: number
    /**
     * Called with each batch as it resolves, so results are PERSISTED AS THEY ARRIVE rather than
     * accumulated and written at the end.
     *
     * With a key a run maps thousands of ISINs, and holding all of that plus every response body
     * in a 150 MB worker is what made it die and return a bare 502 — the same failure mode, and
     * the same fix, as the price refresh. Writing per batch also means a worker that dies keeps
     * the progress it already made.
     */
    onBatch?: (batch: FigiResult[], missed: string[]) => Promise<void>
  } = {},
): Promise<{ results: FigiResult[]; requestsUsed: number; unresolved: number; resolvedCount: number }> {
  const apiKey = opts.apiKey?.trim() || undefined;
  const perRequest = apiKey ? KEYED_JOBS_PER_REQUEST : ANON_JOBS_PER_REQUEST;
  // Keyed: 25 requests x 100 ISINs = 2,500 per run, which clears a ~9,600 backlog in four passes
  // without asking one worker to do the whole thing. The failure mode when a run is too ambitious
  // is a dead worker returning a bare 502, not a slow success.
  const maxRequests = opts.maxRequests ?? (apiKey ? 25 : 15);

  /**
   * A WALL-CLOCK budget, not just a request count.
   *
   * The worker is killed at 60s ("WorkerRequestCancelled: request has been cancelled by
   * supervisor"), and a request count cannot express that: 15 anonymous requests took ~40s on a
   * laptop and blew the limit on the Oracle node, which is slower and further from the API. Since
   * the resource is incremental, stopping early costs nothing — the remainder is the next run's
   * work — while overrunning loses the entire batch including what was already resolved.
   */
  const deadline = Date.now() + (opts.budgetMs ?? 60_000);

  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (apiKey) headers['X-OPENFIGI-APIKEY'] = apiKey;

  const results: FigiResult[] = [];
  let requestsUsed = 0;
  let unresolved = 0;
  let resolvedCount = 0;

  for (let i = 0; i < requests.length && requestsUsed < maxRequests; i += perRequest) {
    // Leave room for the request itself plus the writes the caller still has to do.
    if (Date.now() > deadline) break;
    const batch = requests.slice(i, i + perRequest);
    const jobs: FigiJob[] = batch.map((r) => ({
      idType: 'ID_ISIN',
      idValue: r.isin,
      exchCode: 'US',
    }));

    const res = await fetch(ENDPOINT, {
      method: 'POST',
      headers,
      body: JSON.stringify(jobs),
    });
    requestsUsed++;

    // 429 means the minute's budget is gone. Stop rather than retry: this resource is incremental,
    // so the remainder is simply the next run's work, and hammering a fair-use API to finish a
    // batch of reference data is not a trade worth making.
    if (res.status === 429) break;
    if (!res.ok) {
      throw new Error(`openfigi ${res.status}: ${(await res.text()).slice(0, 200)}`);
    }

    const body = (await res.json()) as ({ data?: Record<string, unknown>[]; warning?: string })[];
    const resolved: FigiResult[] = [];
    // Securities OpenFIGI had no US listing for. Recorded so they are not re-asked on every run —
    // most of a Japan or emerging-markets fund can never resolve against `exchCode: 'US'`.
    const missed: string[] = [];
    for (let j = 0; j < batch.length; j++) {
      // The response is POSITIONAL — entry j answers job j. A filtered or reordered read here
      // would attach the wrong ticker to the wrong security, which is worse than no ticker.
      const row = body[j];
      const hit = row?.data?.[0];
      const ticker = hit?.ticker ? String(hit.ticker) : '';
      if (!ticker) {
        unresolved++;
        missed.push(batch[j].securityId);
        continue;
      }
      resolved.push({
        securityId: batch[j].securityId,
        ticker: ticker.toUpperCase(),
        exchCode: hit?.exchCode ? String(hit.exchCode) : undefined,
        securityType: hit?.securityType ? String(hit.securityType) : undefined,
        name: hit?.name ? String(hit.name) : undefined,
      });
    }
    if (opts.onBatch) await opts.onBatch(resolved, missed);
    else results.push(...resolved);
    resolvedCount += resolved.length;

    // Stay under the per-minute ceiling without needing to track a window. Skip the wait when the
    // budget is spent — the loop is about to exit anyway.
    const gap = apiKey ? 250 : 2500;
    if (requestsUsed < maxRequests && Date.now() + gap < deadline) {
      await new Promise((r) => setTimeout(r, gap));
    }
  }

  return { results, requestsUsed, unresolved, resolvedCount };
}


/**
 * Resolve ISINs to their LOCAL listing, as the price provider addresses it.
 *
 * Deliberately asks OpenFIGI with NO `exchCode` filter, because the point is to see every venue and
 * then choose — Samsung returns 49 matches across KS, KP, US, PQ and more, and picking the first
 * would price a Korean bank off a thin foreign line. `pickLocalSymbol` chooses by the security's
 * own country.
 *
 * Shares the batching, pacing and wall-clock budget of `mapIsinsToTickers` for the same reasons:
 * the rate limit is the design constraint, and the worker dies at 60s.
 */
export async function mapIsinsToLocalSymbols(
  requests: FigiRequest[],
  opts: {
    apiKey?: string
    maxRequests?: number
    budgetMs?: number
    onBatch?: (found: LocalSymbolResult[], missed: string[]) => Promise<void>
    /** The venue catalog from `market.exchange`. Passed in so this file holds no copy of it. */
    venues: VenueMap
  },
): Promise<{ resolvedCount: number; requestsUsed: number; unresolved: number }> {
  const apiKey = opts.apiKey?.trim() || undefined;
  const perRequest = apiKey ? KEYED_JOBS_PER_REQUEST : ANON_JOBS_PER_REQUEST;
  const maxRequests = opts.maxRequests ?? (apiKey ? 25 : 15);
  const deadline = Date.now() + (opts.budgetMs ?? 60_000);

  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (apiKey) headers['X-OPENFIGI-APIKEY'] = apiKey;

  let requestsUsed = 0;
  let unresolved = 0;
  let resolvedCount = 0;

  for (let i = 0; i < requests.length && requestsUsed < maxRequests; i += perRequest) {
    if (Date.now() > deadline) break;
    const batch = requests.slice(i, i + perRequest);
    const res = await fetch(ENDPOINT, {
      method: 'POST',
      headers,
      body: JSON.stringify(batch.map((r) => ({ idType: 'ID_ISIN', idValue: r.isin }))),
    });
    requestsUsed++;
    if (res.status === 429) break;
    if (!res.ok) throw new Error(`openfigi ${res.status}: ${(await res.text()).slice(0, 200)}`);

    const body = (await res.json()) as ({ data?: Record<string, unknown>[] })[];
    const found: LocalSymbolResult[] = [];
    const missed: string[] = [];
    for (let j = 0; j < batch.length; j++) {
      // POSITIONAL: entry j answers job j. Reordering here would attach one company's listing to
      // another, which is worse than resolving nothing.
      const matches = (body[j]?.data ?? []) as {
        ticker?: string
        exchCode?: string
        compositeFIGI?: string
      }[];
      const picked = pickLocalSymbol(batch[j].countryIso2 ?? '', matches, opts.venues);
      if (picked) {
        found.push({
          securityId: batch[j].securityId,
          symbol: picked.symbol,
          compositeFigi: picked.compositeFigi,
        });
      }
      else {
        unresolved++;
        missed.push(batch[j].securityId);
      }
    }
    if (opts.onBatch) await opts.onBatch(found, missed);
    resolvedCount += found.length;

    const gap = apiKey ? 250 : 2500;
    if (requestsUsed < maxRequests && Date.now() + gap < deadline) {
      await new Promise((r) => setTimeout(r, gap));
    }
  }

  return { resolvedCount, requestsUsed, unresolved };
}

export interface ExchangeListing {
  figi: string;
  compositeFigi?: string;
  ticker: string;
  name?: string;
  securityType?: string;
}

/**
 * Enumerate one exchange's common stocks, a page at a time.
 *
 * `/v3/filter` is a DIFFERENT endpoint from `/v3/mapping`: it lists a venue rather than resolving
 * an identifier, returns 100 rows with a `next` cursor, and — importantly — carries NO ISIN. Only
 * tickers, names and FIGIs, which is why the listing table joins on FIGI.
 *
 * `securityType2: 'Common Stock'` is not optional: an unfiltered query returns derivatives too
 * (searching "Samsung Electronics" gives 8,725 hits, nearly all options on it).
 */
/**
 * @param securityType2 What kind of instrument to enumerate. Defaults to `Common Stock`.
 *
 * **ADRs ARE A SEPARATE TYPE, AND SWEEPING ONLY COMMON STOCK LOSES EVERY ONE OF THEM.** Measured
 * 2026-08-13: `BABA` carries `securityType2: 'Depositary Receipt'` (`securityType: 'ADR'`), so it
 * was absent from a 15,000-row US sweep that contained `BABB`, `BABAF` and `BABYF`. The same is
 * true of every major foreign company's US listing — TSM, NVO, SAP's ADR — which is exactly the
 * population someone expects to find and cannot.
 */
/**
 * OpenFIGI `/v3/filter` reports the true `total` but stops PAGING here. Measured 2026-08-14:
 * `exchCode: US` + `Common Stock` reports 20,107 and yields exactly 15,000, then offers no further
 * cursor. It is a silent ceiling — the sweep looks finished rather than truncated.
 */
export const PAGING_CEILING = 15_000;

/**
 * Resolve a NAMED TICKER to its composite FIGI, so a company can be promoted without waiting for
 * its exchange to be enumerated.
 *
 * The directory route needs the sweep to have reached the listing, and it pages no deeper than
 * `PAGING_CEILING` — the US reports 20,107 common stocks and yields 15,000. So `BABA` was
 * unreachable that way while being one `/v3/mapping` call away:
 *
 *   TICKER=BABA exchCode=US -> BBG006G2JVL2, ALIBABA GROUP HOLDING-SP ADR, Depositary Receipt
 *
 * Deliberately does NOT filter by `securityType2`: the caller named a specific ticker, so an ADR is
 * as valid an answer as a common share — which is the point, since ADRs are exactly what a
 * Common-Stock-only sweep drops.
 */
export async function mapTickers(
  wanted: { ticker: string; exchCode?: string }[],
  opts: { apiKey?: string; timeoutMs?: number } = {},
): Promise<{ ticker: string; name?: string; compositeFigi?: string; securityType?: string }[]> {
  if (wanted.length === 0) return [];
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (opts.apiKey?.trim()) headers['X-OPENFIGI-APIKEY'] = opts.apiKey.trim();

  const res = await fetch('https://api.openfigi.com/v3/mapping', {
    method: 'POST',
    headers,
    body: JSON.stringify(
      wanted.map((w) => ({
        idType: 'TICKER',
        idValue: w.ticker.toUpperCase(),
        ...(w.exchCode ? { exchCode: w.exchCode.toUpperCase() } : {}),
      })),
    ),
    signal: AbortSignal.timeout(opts.timeoutMs ?? 20_000),
  });
  if (!res.ok) throw new Error(`openfigi mapping ${res.status}`);

  const body = (await res.json()) as ({ data?: Record<string, unknown>[]; warning?: string })[];
  return wanted.map((w, i) => {
    const hit = body[i]?.data?.[0];
    return {
      ticker: w.ticker.toUpperCase(),
      name: hit?.name ? String(hit.name) : undefined,
      compositeFigi: hit?.compositeFIGI ? String(hit.compositeFIGI) : undefined,
      securityType: hit?.securityType2 ? String(hit.securityType2) : undefined,
    };
  });
}

export async function listExchange(
  exchCode: string,
  cursor: string | undefined,
  opts: {
    apiKey?: string; maxPages?: number; budgetMs?: number;
    securityType2?: string;
    /** Ticker prefix, when the venue is too large to enumerate whole. See PAGING_CEILING. */
    query?: string;
  } = {},
): Promise<{
  listings: ExchangeListing[];
  next?: string;
  pages: number;
  total?: number;
  /**
   * OpenFIGI refused us mid-sweep. NOT the same as "this venue is exhausted", and the caller must
   * not treat the two alike: a 429 on the FIRST page returns zero listings and zero pages, which
   * is byte-identical to a venue that had nothing to add.
   *
   * Measured 2026-08-14: three `exchange-listings` runs fired 15 seconds apart. The second swept
   * Japan for 1,800 listings across 18 pages; the third hit the rate limit on page one and
   * reported `written: 0, pages: 0, complete: false` — a success, with `ok: true` in refresh_log.
   * The venue's recorded total was then overwritten with that zero.
   */
  throttled: boolean;
}> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json' };
  if (opts.apiKey?.trim()) headers['X-OPENFIGI-APIKEY'] = opts.apiKey.trim();

  const deadline = Date.now() + (opts.budgetMs ?? 60_000);
  const maxPages = opts.maxPages ?? 20;
  const listings: ExchangeListing[] = [];
  let next = cursor;
  let pages = 0;
  let total: number | undefined;
  let throttled = false;

  for (; pages < maxPages; pages++) {
    if (Date.now() > deadline) break;
    const res = await fetch('https://api.openfigi.com/v3/filter', {
      method: 'POST',
      headers,
      body: JSON.stringify({
        exchCode,
        securityType2: opts.securityType2 ?? 'Common Stock',
        ...(opts.query ? { query: opts.query } : {}),
        ...(next ? { start: next } : {}),
      }),
      signal: AbortSignal.timeout(20_000),
    });
    // Out of budget for this minute — stop and resume from the cursor next run, and SAY SO. A
    // silent break makes a refusal look like completion.
    if (res.status === 429) { throttled = true; break; }
    if (!res.ok) throw new Error(`openfigi filter ${res.status}: ${(await res.text()).slice(0, 200)}`);

    const body = (await res.json()) as {
      data?: Record<string, unknown>[];
      next?: string;
      total?: number;
    };
    total ??= body.total;
    for (const r of body.data ?? []) {
      const figi = String(r.figi ?? '');
      const ticker = String(r.ticker ?? '');
      if (!figi || !ticker) continue;
      listings.push({
        figi,
        compositeFigi: r.compositeFIGI ? String(r.compositeFIGI) : undefined,
        ticker,
        name: r.name ? String(r.name) : undefined,
        securityType: r.securityType2 ? String(r.securityType2) : undefined,
      });
    }
    next = body.next;
    // No cursor means the venue is exhausted; returning undefined is what tells the caller to
    // start again from the top next time rather than resuming a stale page.
    if (!next) break;
    await new Promise((r) => setTimeout(r, 250));
  }

  return { listings, next, pages, total, throttled };
}
