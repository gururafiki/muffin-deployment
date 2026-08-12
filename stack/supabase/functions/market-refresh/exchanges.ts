// Local exchange -> the symbol the price provider knows.
//
// WHY THIS EXISTS. Everything non-US was capped by one chain: ticker resolution asked OpenFIGI for
// the US listing (`exchCode: 'US'`), and a company with no US line got no ticker — so no profile,
// so no sector, and no price either. Measured 2026-08-11: Korea had 10 tickers across 467
// securities and exactly ONE classified sector, while Germany (which has plenty of US OTC lines)
// had 107 of 153.
//
// KEYED ON THE SECURITY'S COUNTRY, not on whatever OpenFIGI returns first. A large company lists
// in several places, and picking arbitrarily would price a Korean bank off its Frankfurt line —
// thin, differently-denominated, and quietly wrong.
//
// THE VENUE TABLE ITSELF NOW LIVES IN THE DATABASE (`market.exchange`). It used to be a hardcoded
// map here, with a second copy seeded into `exchange_cursor`; measured 2026-08-12 the two had
// drifted to 54 rows against 38, so local-symbol resolution covered sixteen venues the exchange
// sweep never visited. Everything below takes the catalog as an argument, which also lets the
// tests drive it with a fixture instead of the real world.

export interface ExchangeChoice {
  /** OpenFIGI's `exchCode` (Bloomberg exchange code) for the venue. */
  figi: string;
  /** The suffix the price provider appends to the local ticker. '' means none (US). */
  suffix: string;
}

/** country ISO-2 -> its venues, best first. Loaded from `market.exchange`. */
export type VenueMap = Record<string, ExchangeChoice[]>;

/** Does this country have a local venue we can address? */
export const hasLocalExchange = (iso2: string | null | undefined, venues: VenueMap): boolean =>
  !!iso2 && iso2 !== 'US' && iso2 in venues;

/**
 * Pick the best local listing OpenFIGI returned for a security in `iso2`.
 *
 * Returns the yfinance-addressable symbol, or null when none of the matches is on a venue we know
 * how to address — a null is reported and negative-cached rather than guessed at, because a symbol
 * the price provider does not recognise is worse than no symbol: it produces an empty series that
 * looks like a quiet outage.
 */
/**
 * OpenFIGI returns `exchCode` INCONSISTENTLY: bare for some venues and labelled for others.
 * Samsung comes back as `KS`, TSMC as `TT (Taiwan Stock Exchange)`. An exact comparison therefore
 * matches Korea and silently drops Taiwan — 534 securities with no symbol, no sector and no price,
 * and no error anywhere to say so.
 *
 * Found by measuring, not by reading: every other country had provider symbols and Taiwan had
 * exactly zero. The four samples this table was originally checked against all happened to be the
 * bare form.
 */
const exchCodeOf = (raw: string | undefined): string =>
  (raw ?? '').split(' (')[0].trim().toUpperCase();

export function pickLocalSymbol(
  iso2: string,
  matches: { ticker?: string; exchCode?: string; compositeFIGI?: string }[],
  venueMap: VenueMap,
): { symbol: string; compositeFigi?: string } | null {
  const venues = venueMap[iso2];
  if (!venues) return null;
  for (const venue of venues) {
    const hit = matches.find((m) => exchCodeOf(m.exchCode) === venue.figi && m.ticker);
    // The composite FIGI comes back with the match and is the ONLY key that joins a security to
    // `exchange_listing` — the directory endpoint returns no ISIN. Capturing it here is what makes
    // that table joinable at all, so it is carried even though nothing needs it in this call.
    if (hit) return { symbol: `${hit.ticker}${venue.suffix}`, compositeFigi: hit.compositeFIGI };
  }
  return null;
}

/**
 * Build the venue map from `market.exchange` rows.
 *
 * PURE, and the query lives in index.ts — the same split `resources.ts` uses, so this file has no
 * supabase-js dependency and the mapping can be driven by a fixture in `logic-check.ts`.
 *
 * Rows must arrive ordered by `preference` so a country's primary board wins when several venues
 * answer: Korea lists KOSPI before KOSDAQ, and a mid-cap on the secondary board still resolves.
 */
export function venuesFromRows(
  rows: { exch_code: string; country_iso2: string | null; suffix: string }[],
): VenueMap {
  const out: VenueMap = {};
  for (const r of rows) {
    if (!r.country_iso2) continue;
    (out[r.country_iso2] ??= []).push({ figi: r.exch_code, suffix: r.suffix });
  }
  return out;
}

/**
 * Which venue does a provider symbol belong to? `005930.KS` -> `KS`, `AAPL` -> `US`.
 *
 * LONGEST SUFFIX FIRST, then preference. Two venues can share a suffix (Canada's CT and CN are both
 * `.TO`, the UAE's DU and DH both `.AE`), and a shorter suffix can be the tail of a longer one — so
 * matching in table order would resolve by whichever row came first, which is not a decision.
 *
 * Mirrors the SQL backfill in migration 38 deliberately: the same rule stated twice in two
 * languages is a drift risk, so both are asserted — the SQL against fixtures in the migration test,
 * this against `logic-check.ts`.
 */
export function venueForSymbol(symbol: string, venues: VenueMap): string | null {
  const all: ExchangeChoice[] = [];
  for (const list of Object.values(venues)) all.push(...list);
  const suffixed = all
    .filter((v) => v.suffix !== '')
    .sort((a, b) => b.suffix.length - a.suffix.length);
  const upper = symbol.toUpperCase();
  for (const v of suffixed) {
    if (upper.endsWith(v.suffix.toUpperCase())) return v.figi;
  }
  // No suffix at all is a US listing — the same reason the backfill handles it as a separate case
  // rather than matching an empty suffix, which would match every symbol on every venue.
  return symbol.includes('.') ? null : 'US';
}
