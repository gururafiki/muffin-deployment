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

const ENDPOINT = 'https://api.openfigi.com/v3/mapping';

/** Anonymous limits. A key lifts both, which is why they are read at call time, not baked in. */
const ANON_JOBS_PER_REQUEST = 10;
const KEYED_JOBS_PER_REQUEST = 100;

export interface FigiRequest {
  securityId: string;
  isin: string;
}
export interface FigiResult {
  securityId: string;
  ticker: string;
  exchCode?: string;
  securityType?: string;
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
  const deadline = Date.now() + (opts.budgetMs ?? 35_000);

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
