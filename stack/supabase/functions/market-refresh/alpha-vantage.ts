/**
 * Alpha Vantage, called directly for EPS history. Its own module since the FX half of the file it
 * lived in retired with the price family (Dagster's `daily_fx` owns `market.fx_rate`).
 */
import { alphaVantage } from './origins.ts'

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
 * The same reason the Dagster FX lane reads Yahoo's chart endpoint itself: when the wrapper hides
 * the one field that carries the meaning, call the provider.
 */
export interface AvEarnings {
  /** Null when the provider refused rather than answered — the caller must not mark on this. */
  quarters: { periodEnding: string; reportedDate: string | null; actual: number | null;
              estimated: number | null; surprise: number | null; surprisePct: number | null }[] | null
  rateLimited: boolean
  /**
   * The provider ANSWERED and does not carry this symbol. Distinct from `quarters: null`, which
   * means it never answered at all — the caller may mark on this one and must not mark on that.
   */
  notCovered: boolean
  note: string | null
}

export async function fetchAlphaVantageEarnings(
  symbol: string,
  apiKey: string,
  timeoutMs = 20_000,
): Promise<AvEarnings> {
  const res = await fetch(
    `${alphaVantage()}/query?function=EARNINGS&symbol=${encodeURIComponent(symbol)}` +
      `&apikey=${encodeURIComponent(apiKey)}`,
    { signal: AbortSignal.timeout(timeoutMs) },
  )
  if (!res.ok) return { quarters: null, rateLimited: false, notCovered: false, note: `http ${res.status}` }

  const body = (await res.json()) as Record<string, unknown>

  // THE RATE LIMIT ARRIVES AS A 200 WITH PROSE. `Information` carries it; `Note` is the older
  // spelling and still appears. Either means the answer is about our quota, not about the company.
  const info = String(body.Information ?? body.Note ?? '')
  if (info) return { quarters: null, rateLimited: true, notCovered: false, note: info.slice(0, 200) }

  // AN EMPTY OBJECT IS "I DO NOT CARRY THAT SYMBOL", AND IT IS AN ANSWER.
  //
  // Measured 2026-08-22, seconds apart on one key: `ASMLF` (ASML's thin OTC foreign-ordinary line)
  // returns `{}` — not one key, not even `symbol` — while `ASML` returns 108 quarters and `MSFT`
  // 122. So the empty object is about the SYMBOL, not about our quota and not about the endpoint.
  //
  // The distinction is what lets the caller mark. Alpha Vantage serves US listings, and OpenFIGI's
  // US lookup hands this pipeline the OTC `F`-line for most foreign companies (`ASMLF`, `BUDFF`,
  // `ICTEF`) — bare tickers, so migration 123's suffix filter passes them through. Without a way to
  // record "asked, not carried", a weight-ordered backlog re-asks the same unanswerable head every
  // run and the 25-a-day quota buys nothing, for ever. Fifth instance of that stall in this schema.
  const raw = body.quarterlyEarnings
  if (Object.keys(body).length === 0) {
    return { quarters: [], rateLimited: false, notCovered: true, note: 'provider does not carry this symbol' }
  }
  // A SHAPE WE DID NOT EXPECT IS REPORTED, NEVER TREATED AS ABSENCE. If Alpha Vantage renames this
  // field the resource must say so loudly rather than quietly concluding that every security in the
  // page has no earnings history. Note this is reached only when the body HAS keys — a renamed
  // field still leaves `symbol` and `annualEarnings` behind, so it can never look like the empty
  // object above.
  if (!Array.isArray(raw)) {
    return { quarters: null, rateLimited: false, notCovered: false, note: 'no quarterlyEarnings array in the response' }
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
      // Already a PERCENT here, VERIFIED against the arithmetic rather than inferred: MSFT's
      // 2026-06-30 quarter reports 4.74 against an estimated 4.21, and (4.74 - 4.21) / 4.21 is
      // 12.589% — which is what `surprisePercentage` carries (12.5891). openbb's wrapper divides
      // it by 100 and sends 0.125891; reading the provider directly means reading ITS units.
      surprisePct: num(r.surprisePercentage),
    }]
  })
  return { quarters, rateLimited: false, notCovered: false, note: null }
}
