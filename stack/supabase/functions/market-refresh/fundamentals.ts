// Fundamentals from yfinance, via the OpenBB we already run.
//
// I ORIGINALLY GOT THIS WRONG and it is worth recording why. Asked whether another provider could
// supply fundamentals, I probed the ones we hold KEYS for and concluded none could:
//   * FMP free gates PER SYMBOL — 402 on BHP, SAP, NEE while AAPL returns 200;
//   * Tiingo free is "limited to the DOW 30";
//   * Alpha Vantage has no per-symbol gating but covers US listings ONLY and caps at 25 calls/day.
//
// All true, and all beside the point: the provider already serving us sectors, prices and market
// cap — keyless yfinance — serves `equity/fundamental/metrics` too. Measured against the exact
// symbols that defeated the others: AAPL, SAP, BHP and NEE all return 30-35 fields, and so do
// `005930.KS`, `7203.T` and `KGH.WA`, which Alpha Vantage returns empty for.
//
// The lesson is the one already in CLAUDE.md: I searched among the things I had keys for instead
// of among the things that could answer.

import type { Fetcher } from './resources.ts'

export interface Fundamentals {
  peRatio?: number
  forwardPe?: number
  pegRatio?: number
  priceToBook?: number
  profitMargin?: number
  grossMargin?: number
  operatingMargin?: number
  returnOnEquity?: number
  revenueGrowth?: number
  debtToEquity?: number
  dividendYield?: number
  beta?: number
  enterpriseValue?: number
  raw: Record<string, unknown>
}

const num = (v: unknown): number | undefined => {
  const n = Number(v)
  return Number.isFinite(n) ? n : undefined
}

/** @returns null when the provider has nothing for this symbol — reported, never stored as zero. */
export async function fetchFundamentals(
  fetcher: Fetcher,
  symbol: string,
  timeoutMs = 15_000,
): Promise<Fundamentals | null> {
  const rows = await fetcher(
    `/api/v1/equity/fundamental/metrics?symbol=${encodeURIComponent(symbol)}&provider=yfinance`,
    timeoutMs,
  )
  const r = rows[0]
  if (!r) return null
  return {
    peRatio: num(r.pe_ratio),
    forwardPe: num(r.forward_pe),
    pegRatio: num(r.peg_ratio),
    priceToBook: num(r.price_to_book),
    profitMargin: num(r.profit_margin),
    grossMargin: num(r.gross_margin),
    operatingMargin: num(r.operating_margin),
    returnOnEquity: num(r.return_on_equity),
    revenueGrowth: num(r.revenue_growth),
    debtToEquity: num(r.debt_to_equity),
    dividendYield: num(r.dividend_yield),
    beta: num(r.beta),
    enterpriseValue: num(r.enterprise_value),
    raw: r,
  }
}
