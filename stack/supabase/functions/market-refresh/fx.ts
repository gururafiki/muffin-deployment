/**
 * FX rates, so a market cap in won can be compared with one in dollars.
 *
 * 71% of the market caps we hold (8,169 of 11,573) are denominated in something other than USD,
 * because `security.market_cap` stores what the provider reported rather than a converted figure.
 *
 * YAHOO, NOT THE ECB, and that was measured. The ECB's free daily reference rates are the obvious
 * choice and cover only **27 of our 41 currencies** — missing TWD (535 Taiwanese securities), VND,
 * AED, SAR, QAR, KWD, PEN, CLP, COP, ARS and GEL. Yahoo's chart endpoint returns all of them, is
 * keyless, and is already used by `security-yahoo-symbols`, so a second provider would add failure
 * modes while covering a strict subset.
 */

/** USD per ONE unit. Multiply a figure in this currency by it to reach USD. */
export interface FxQuote {
  currency: string;
  usdPerUnit: number;
  asOf: string;
}

/**
 * SUBUNITS ARE NOT CURRENCIES, and pretending otherwise is what made Tel Aviv look like a 100x
 * crash. Yahoo has no pair for agorot, cents or fils; they are a fixed fraction of their parent.
 *
 * Kept as data rather than as a branch at the call site, so a caller converting a figure never has
 * to know which of the 41 codes are subunits.
 */
export const SUBUNITS: Record<string, { parent: string; per: number }> = {
  ILA: { parent: 'ILS', per: 100 },
  ZAC: { parent: 'ZAR', per: 100 },
  KWF: { parent: 'KWD', per: 1000 },
};

/**
 * One currency's latest rate against USD.
 *
 * Returns null when the pair is unknown or the response carries no usable close — a currency we
 * cannot price is a currency we say nothing about. Writing a 1.0 "because it is probably close" is
 * how a Vietnamese dong market cap becomes a dollar one.
 */
export async function fetchUsdPerUnit(
  currency: string,
  timeoutMs = 10_000,
): Promise<FxQuote | null> {
  if (currency === 'USD') return { currency, usdPerUnit: 1, asOf: new Date().toISOString().slice(0, 10) };

  const res = await fetch(
    `https://query2.finance.yahoo.com/v8/finance/chart/${currency}USD=X?range=5d&interval=1d`,
    {
      // The default fetch UA is refused by Yahoo often enough to matter, and the failure reads like
      // an outage rather than a header problem.
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; muffin-market-data)' },
      signal: AbortSignal.timeout(timeoutMs),
    },
  );
  if (!res.ok) return null;

  const body = (await res.json()) as {
    chart?: {
      error?: unknown;
      result?: {
        timestamp?: number[];
        indicators?: { quote?: { close?: (number | null)[] }[] };
      }[];
    };
  };
  if (body.chart?.error) return null;
  const r = body.chart?.result?.[0];
  const closes = r?.indicators?.quote?.[0]?.close ?? [];
  const stamps = r?.timestamp ?? [];

  // The LAST NON-NULL close, walking back. A 5-day window over a weekend or a holiday has trailing
  // nulls, and taking `closes.at(-1)` blindly yields null on a Saturday — which would read as "this
  // currency has no rate" every weekend.
  for (let i = closes.length - 1; i >= 0; i--) {
    const c = closes[i];
    if (typeof c !== 'number' || !Number.isFinite(c) || c <= 0) continue;
    const ts = stamps[i];
    const asOf = typeof ts === 'number'
      ? new Date(ts * 1000).toISOString().slice(0, 10)
      : new Date().toISOString().slice(0, 10);
    return { currency, usdPerUnit: c, asOf };
  }
  return null;
}

/**
 * A SANITY BAND, because a wrong rate is silent and enormous.
 *
 * The failure it exists to catch is an INVERTED PAIR. `USDTWD` and `TWDUSD` are both valid Yahoo
 * symbols and exact reciprocals, and both return plausible-looking numbers — 31.9 and 0.0314 — so
 * nothing about the value itself announces which one was fetched.
 *
 * THE CEILING IS 10, NOT 100, and the first version got this wrong. Every real currency on earth
 * sits below it: the Kuwaiti dinar is the highest at ~3.26 USD, then Bahrain ~2.65 and Oman ~2.60.
 * A ceiling of 100 accepted an inverted TWD (31.9) — the guard's own headline case — while looking
 * generous. 10 keeps 3x headroom over the highest real currency and refuses the inversion.
 *
 * The floor is 1e-7: the Vietnamese dong, the lowest we hold, is ~0.0000382, and an inverted dong
 * would be ~26,200 and fail the ceiling.
 *
 * WHAT THIS CANNOT CATCH, stated rather than implied: an inversion where BOTH directions land
 * inside the band — a currency near 0.5 inverts to 2.0 and neither is refused. A band cannot see
 * that, and claiming otherwise would make it trusted beyond its reach. What protects those is the
 * pair being constructed as `<CODE>USD=X` in one place rather than assembled per call site.
 *
 * Rejecting is right rather than correcting: a rate we are unsure of must not silently reprice
 * 8,169 market caps.
 */
export function isPlausibleRate(usdPerUnit: number): boolean {
  return Number.isFinite(usdPerUnit) && usdPerUnit > 1e-7 && usdPerUnit < 10;
}

/**
 * TEN YEARS OF WEEKLY RATES for one currency.
 *
 * WHY HISTORY AT ALL. `fx_rate` held three days, which is enough to reprice a market cap TODAY and
 * useless for a ratio SERIES: converting a 2021 bar with today's rate produces a number that is
 * wrong by every intervening move and looks entirely ordinary — the exact shape this pipeline keeps
 * being bitten by. A P/E chart for a company that reports in one currency and trades in another
 * either has a rate per bar or it has nothing.
 *
 * WEEKLY, NOT DAILY, and that is deliberate: `security_price` is itself weekly beyond the recent
 * window, FX moves slowly relative to the quantity being converted, and 524 weekly bars per
 * currency against ~2,600 daily keeps the whole table small enough to join cheaply. The consumer
 * carries each rate forward to the following bars, so a daily price between two weekly rates uses
 * the most recent one rather than interpolating — a rate we did not observe is not a rate.
 */
export async function fetchUsdPerUnitHistory(
  currency: string,
  timeoutMs = 20_000,
): Promise<{ asOf: string; usdPerUnit: number }[]> {
  if (currency === 'USD') return [];

  const res = await fetch(
    `https://query2.finance.yahoo.com/v8/finance/chart/${currency}USD=X?range=10y&interval=1wk`,
    {
      headers: { 'User-Agent': 'Mozilla/5.0 (compatible; muffin-market-data)' },
      signal: AbortSignal.timeout(timeoutMs),
    },
  );
  if (!res.ok) return [];

  const body = (await res.json()) as {
    chart?: {
      error?: unknown;
      result?: {
        timestamp?: number[];
        indicators?: { quote?: { close?: (number | null)[] }[] };
      }[];
    };
  };
  if (body.chart?.error) return [];
  const r = body.chart?.result?.[0];
  const closes = r?.indicators?.quote?.[0]?.close ?? [];
  const stamps = r?.timestamp ?? [];

  const out: { asOf: string; usdPerUnit: number }[] = [];
  for (let i = 0; i < closes.length; i++) {
    const c = closes[i];
    const ts = stamps[i];
    if (typeof c !== 'number' || !Number.isFinite(c) || c <= 0) continue;
    if (typeof ts !== 'number') continue;
    // The SAME plausibility gate the spot path uses. An inverted pair is the likely fault and both
    // directions look reasonable, so a rate we cannot vouch for is dropped rather than corrected.
    if (!isPlausibleRate(c)) continue;
    out.push({ asOf: new Date(ts * 1000).toISOString().slice(0, 10), usdPerUnit: c });
  }
  return out;
}

/**
 * Alpha Vantage's EARNINGS endpoint, called DIRECTLY rather than through openbb-api.
 *
 * WHY BYPASS OPENBB HERE. The free key allows 25 requests a day, and when it is spent Alpha Vantage
 * answers 200 with an `Information` field explaining the limit — no error status, no empty body.
 * openbb translates that into an empty **204**, which is exactly what it returns for a symbol it
 * genuinely has nothing for. Measured 2026-08-22: MSFT returned full data from the raw API in the
 * same minute openbb reported 204 for it, because the quota had gone.
 *
 * That ambiguity is not survivable. A resource that marks an empty answer as "this security has no
 * EPS history" would negative-cache real companies for 90 days every time the day's quota ran out —
 * and at 24 calls a day against a 25 limit, that is most days. The `Information` field is the only
 * thing that distinguishes the two, so this reads it.
 *
 * The same pattern `fetchUsdPerUnit` already uses for Yahoo: when the wrapper hides the one field
 * that carries the meaning, call the provider.
 */
export interface AvEarnings {
  /** Null when the provider refused rather than answered — the caller must not mark on this. */
  quarters: { periodEnding: string; reportedDate: string | null; actual: number | null;
              estimated: number | null; surprise: number | null; surprisePct: number | null }[] | null
  rateLimited: boolean
  note: string | null
}

export async function fetchAlphaVantageEarnings(
  symbol: string,
  apiKey: string,
  timeoutMs = 20_000,
): Promise<AvEarnings> {
  const res = await fetch(
    `https://www.alphavantage.co/query?function=EARNINGS&symbol=${encodeURIComponent(symbol)}` +
      `&apikey=${encodeURIComponent(apiKey)}`,
    { signal: AbortSignal.timeout(timeoutMs) },
  )
  if (!res.ok) return { quarters: null, rateLimited: false, note: `http ${res.status}` }

  const body = (await res.json()) as Record<string, unknown>

  // THE RATE LIMIT ARRIVES AS A 200 WITH PROSE. `Information` carries it; `Note` is the older
  // spelling and still appears. Either means the answer is about our quota, not about the company.
  const info = String(body.Information ?? body.Note ?? '')
  if (info) return { quarters: null, rateLimited: true, note: info.slice(0, 200) }

  const raw = body.quarterlyEarnings
  // A SHAPE WE DID NOT EXPECT IS REPORTED, NEVER TREATED AS ABSENCE. If Alpha Vantage renames this
  // field the resource must say so loudly rather than quietly concluding that every security in the
  // page has no earnings history.
  if (!Array.isArray(raw)) {
    return { quarters: null, rateLimited: false, note: 'no quarterlyEarnings array in the response' }
  }

  const num = (v: unknown): number | null => {
    // Alpha Vantage sends numbers as STRINGS and uses "None" for absent values.
    const n = Number(v)
    return Number.isFinite(n) ? n : null
  }

  const quarters = raw.flatMap((q) => {
    const r = q as Record<string, unknown>
    const periodEnding = String(r.fiscalDateEnding ?? '').slice(0, 10)
    if (!periodEnding) return []
    return [{
      periodEnding,
      reportedDate: r.reportedDate ? String(r.reportedDate).slice(0, 10) : null,
      actual: num(r.reportedEPS),
      estimated: num(r.estimatedEPS),
      surprise: num(r.surprise),
      // Already a PERCENT here — the raw API sends 12.5891 where openbb's wrapper sends the
      // fraction 0.125891. Reading the provider directly means reading its units, not the
      // wrapper's.
      surprisePct: num(r.surprisePercentage),
    }]
  })
  return { quarters, rateLimited: false, note: null }
}
