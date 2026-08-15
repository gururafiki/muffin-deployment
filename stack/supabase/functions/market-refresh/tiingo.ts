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

export interface CorporateAction {
  exDate: string;
  kind: 'split' | 'dividend';
  /** A split RATIO (2 = two-for-one, 0.1 = one-for-ten reverse) or cash per share. */
  value: number;
}

/** Tiingo answers 404 with this shape for a ticker it does not carry — a fact, not a failure. */
export class TiingoNoSuchTicker extends Error {}

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
    `https://api.tiingo.com/tiingo/daily/${encodeURIComponent(symbol)}/prices` +
    `?startDate=${startDate}&token=${encodeURIComponent(token)}`;
  const res = await fetch(url, {
    headers: { 'Content-Type': 'application/json' },
    signal: AbortSignal.timeout(timeoutMs),
  });
  if (res.status === 404) throw new TiingoNoSuchTicker(`tiingo has no ticker ${symbol}`);
  if (!res.ok) throw new Error(`tiingo ${res.status}: ${(await res.text()).slice(0, 200)}`);

  const body = (await res.json()) as Record<string, unknown>[];
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
