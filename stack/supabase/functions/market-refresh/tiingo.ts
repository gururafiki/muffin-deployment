/**
 * Tiingo daily EOD — the only source here for splits and dividends.
 *
 * WHY A FIFTH UPSTREAM. Nothing in this pipeline knew about corporate actions. `firstComparableIndex`
 * INFERS a discontinuity from a >5x single-bar move, which stops a split fabricating a +900% and
 * does nothing else: the stored closes stay unadjusted, the pre-split history is excluded rather
 * than corrected, and a REDENOMINATION trips the same rule while not being a corporate action at
 * all. Inference cannot separate those; a recorded `splitFactor` can.
 *
 * WHY TIINGO, having been ruled out here before. `todos.md` recorded "Tiingo free is limited to the
 * DOW 30". Measured 2026-08-15 with the key that had been in GitHub secrets since 08-10, that is
 * false: it answered for every US-listed name tried — ROST, STX, TPR, ISRG, SNDK — plus ADRs, and a
 * 28-symbol sample of our own tickers came back 26 covered (93%), thin OTC lines included.
 *
 * WHAT IT DOES NOT COVER, stated so nobody re-tests it: local foreign listings. `7203.T`, `SAP.DE`,
 * `005930.KS` and `NESN.SW` all return 404 `Ticker not found`. This reaches the ~6,645 securities
 * with a US ticker, not the 12,350 equities.
 *
 * THE BINDING CONSTRAINT IS UNIQUE SYMBOLS, NOT REQUESTS. Tiingo's free tier caps how many distinct
 * tickers an account may touch in a period, so — unlike the yfinance-bound resources, where the
 * limit is requests per unit time — asking for fewer symbols is the only lever, and the ones asked
 * for must be the ones that matter. That is why the backlog is ordered by fund weight.
 */

import { tiingo as tiingoOrigin } from './origins.ts'

export interface CorporateAction {
  exDate: string;
  kind: 'split' | 'dividend';
  /** A split RATIO (2 = two-for-one, 0.1 = one-for-ten reverse) or cash per share. */
  value: number;
}

/** Tiingo answers 404 with this shape for a ticker it does not carry — a fact, not a failure. */
export class TiingoNoSuchTicker extends Error {}

/**
 * Tiingo has refused us for the period, and it says so with **HTTP 200 and a plain-text body**.
 *
 * Measured 2026-08-28 across six consecutive `security-corporate-actions` runs, every one
 * reporting `ok: true` with `written: 0`. Five carried
 * `Unexpected token 'Y', "You have r"... is not valid JSON` — the parse error from calling
 * `res.json()` on `You have run over your hourly request limit` — and one carried a proper
 * `tiingo 429`. So the SAME limit arrives two ways, and only one of them was recognisable.
 *
 * This is the Alpha Vantage trap with a second provider: that one answers exhaustion with 200 plus
 * an `Information` field, which openbb turns into a bare 204. A rate limit that does not arrive as
 * an error status is invisible to every rule that watches for one — including `throttledOut`, and
 * therefore the throttle-pressure panel and its alert.
 */
export class TiingoRateLimited extends Error {}

/**
 * Does this body say "you have had enough"? Matched on the wording Tiingo ACTUALLY uses, quoted
 * from production rather than guessed: `Error: You have run over your hourly request limit`.
 * Note it contains neither "rate limit" nor "429" — the two things a classifier would reach for.
 */
function rateLimited(body: string): boolean {
  const b = body.toLowerCase();
  return b.includes('run over your') ||
    b.includes('request limit') ||
    b.includes('rate limit') ||
    b.includes('too many requests') ||
    b.includes('quota');
}

/**
 * Every split and dividend Tiingo reports for one symbol since `startDate`.
 *
 * ONE SYMBOL PER CALL because the endpoint is per-ticker; there is no batch form. That is the same
 * shape as `security-statements`, and it has the same consequence — the page size is small and the
 * backlog drains over days rather than in a session.
 */
export async function corporateActions(
  symbol: string,
  startDate: string,
  token: string,
  timeoutMs = 15_000,
): Promise<CorporateAction[]> {
  const url =
    `${tiingoOrigin()}/tiingo/daily/${encodeURIComponent(symbol)}/prices` +
    `?startDate=${startDate}&token=${encodeURIComponent(token)}`;
  const res = await fetch(url, {
    headers: { 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (res.status === 404) throw new TiingoNoSuchTicker(`tiingo has no ticker ${symbol}`);

  // READ THE BODY ONCE, AS TEXT, AND CLASSIFY BEFORE PARSING. A response can only be consumed
  // once, and `res.ok` is TRUE for a rate limit here — so the previous order (status check, then
  // `res.json()`) skipped the error branch entirely and failed inside the parser instead, with a
  // message that named the first two characters of the body and nothing else.
  const raw = await res.text();

  if (!res.ok) {
    if (rateLimited(raw)) throw new TiingoRateLimited(`tiingo ${res.status}: ${raw.slice(0, 200)}`);
    throw new Error(`tiingo ${res.status}: ${raw.slice(0, 200)}`);
  }
  // A 200 THAT IS NOT JSON. This is the case that cost six silent runs.
  if (rateLimited(raw)) throw new TiingoRateLimited(`tiingo refused (HTTP 200): ${raw.slice(0, 200)}`);

  let body: Record<string, unknown>[];
  try {
    body = JSON.parse(raw) as Record<string, unknown>[];
  } catch {
    // QUOTE WHAT ARRIVED. `Unexpected token 'Y'` is not diagnosable; the body is. The next
    // provider that invents a new way to say "no" should be readable from the log rather than
    // from a database session.
    throw new Error(`tiingo returned non-JSON for ${symbol}: ${raw.slice(0, 200)}`);
  }
  if (!Array.isArray(body)) throw new Error(`tiingo returned a non-array for ${symbol}`);

  const out: CorporateAction[] = [];
  for (const bar of body) {
    const exDate = String(bar.date ?? '').slice(0, 10);
    if (!exDate) continue;

    // A split factor of exactly 1 is "no split", which is every ordinary bar. Compared with a
    // tolerance rather than `!== 1` because the field is a float and a 3-for-1 arrives as
    // 3.0000000001 often enough to matter.
    const factor = Number(bar.splitFactor);
    if (Number.isFinite(factor) && factor > 0 && Math.abs(factor - 1) > 1e-9) {
      out.push({ exDate, kind: 'split', value: factor });
    }

    // `divCash` is 0 on an ordinary bar. Negative would be nonsense and is dropped rather than
    // stored — the same rule `barFrom` applies to a non-positive close.
    const cash = Number(bar.divCash);
    if (Number.isFinite(cash) && cash > 0) {
      out.push({ exDate, kind: 'dividend', value: cash });
    }
  }
  return out;
}
