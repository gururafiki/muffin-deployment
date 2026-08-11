// Local exchange -> the symbol yfinance knows.
//
// WHY THIS EXISTS. Everything non-US was capped by one chain: ticker resolution asked OpenFIGI for
// the US listing (`exchCode: 'US'`), and a company with no US line got no ticker — so no profile,
// so no sector, and no price either. Measured 2026-08-11: Korea had 10 tickers across 467
// securities and exactly ONE classified sector, while Germany (which has plenty of US OTC lines)
// had 107 of 153.
//
// The fix is to ask for the LOCAL listing and address it the way the price provider does. This is
// the general form of the `NESN -> NESN.SW` special case that `security_provider_symbol` was added
// for in the first place.
//
// KEYED ON THE SECURITY'S COUNTRY, not on whatever OpenFIGI returns first. A large company lists
// in several places, and picking arbitrarily would price a Korean bank off its Frankfurt line —
// thin, differently-denominated, and quietly wrong.

export interface ExchangeChoice {
  /** OpenFIGI's `exchCode` (Bloomberg exchange code) for the local venue. */
  figi: string;
  /** The suffix yfinance appends to the local ticker. '' means no suffix (US). */
  suffix: string;
}

/**
 * Preferred local venues per country, best first.
 *
 * Several countries have two real venues (Korea's KOSPI and KOSDAQ, India's NSE and BSE); both are
 * listed so a mid-cap on the secondary board still resolves. Countries absent from this map fall
 * back to the US lookup, which is the current behaviour and remains correct for US securities.
 */
export const LOCAL_EXCHANGES: Record<string, ExchangeChoice[]> = {
  US: [{ figi: 'US', suffix: '' }],
  KR: [{ figi: 'KS', suffix: '.KS' }, { figi: 'KQ', suffix: '.KQ' }],
  JP: [{ figi: 'JT', suffix: '.T' }, { figi: 'JP', suffix: '.T' }],
  DE: [{ figi: 'GY', suffix: '.DE' }, { figi: 'GR', suffix: '.DE' }],
  GB: [{ figi: 'LN', suffix: '.L' }],
  FR: [{ figi: 'FP', suffix: '.PA' }],
  CH: [{ figi: 'SW', suffix: '.SW' }, { figi: 'SE', suffix: '.SW' }],
  NL: [{ figi: 'NA', suffix: '.AS' }],
  IT: [{ figi: 'IM', suffix: '.MI' }],
  ES: [{ figi: 'SM', suffix: '.MC' }, { figi: 'SQ', suffix: '.MC' }],
  SE: [{ figi: 'SS', suffix: '.ST' }],
  NO: [{ figi: 'NO', suffix: '.OL' }],
  DK: [{ figi: 'DC', suffix: '.CO' }],
  FI: [{ figi: 'FH', suffix: '.HE' }],
  BE: [{ figi: 'BB', suffix: '.BR' }],
  AT: [{ figi: 'AV', suffix: '.VI' }],
  PT: [{ figi: 'PL', suffix: '.LS' }],
  IE: [{ figi: 'ID', suffix: '.IR' }],
  PL: [{ figi: 'PW', suffix: '.WA' }],
  GR: [{ figi: 'GA', suffix: '.AT' }],
  TR: [{ figi: 'TI', suffix: '.IS' }],
  IL: [{ figi: 'IT', suffix: '.TA' }],
  ZA: [{ figi: 'SJ', suffix: '.JO' }],
  SA: [{ figi: 'AB', suffix: '.SR' }],
  AE: [{ figi: 'DU', suffix: '.AE' }, { figi: 'DH', suffix: '.AE' }],
  HK: [{ figi: 'HK', suffix: '.HK' }],
  TW: [{ figi: 'TT', suffix: '.TW' }],
  CN: [{ figi: 'C1', suffix: '.SS' }, { figi: 'C2', suffix: '.SZ' }],
  IN: [{ figi: 'IS', suffix: '.NS' }, { figi: 'IB', suffix: '.BO' }],
  SG: [{ figi: 'SP', suffix: '.SI' }],
  TH: [{ figi: 'TB', suffix: '.BK' }],
  ID: [{ figi: 'IJ', suffix: '.JK' }],
  MY: [{ figi: 'MK', suffix: '.KL' }],
  PH: [{ figi: 'PM', suffix: '.PS' }],
  AU: [{ figi: 'AT', suffix: '.AX' }, { figi: 'AU', suffix: '.AX' }],
  NZ: [{ figi: 'NZ', suffix: '.NZ' }],
  CA: [{ figi: 'CT', suffix: '.TO' }, { figi: 'CN', suffix: '.TO' }],
  BR: [{ figi: 'BZ', suffix: '.SA' }, { figi: 'BS', suffix: '.SA' }],
  MX: [{ figi: 'MM', suffix: '.MX' }, { figi: 'MF', suffix: '.MX' }],
  CL: [{ figi: 'CI', suffix: '.SN' }],
  PE: [{ figi: 'PE', suffix: '.LM' }],
  CO: [{ figi: 'CX', suffix: '.CL' }],
};

/** Does this country have a local venue we can address? */
export const hasLocalExchange = (iso2: string | null | undefined): boolean =>
  !!iso2 && iso2 !== 'US' && iso2 in LOCAL_EXCHANGES;

/**
 * Pick the best local listing OpenFIGI returned for a security in `iso2`.
 *
 * Returns the yfinance-addressable symbol, or null when none of the matches is on a venue we know
 * how to address — a null is reported and negative-cached rather than guessed at, because a symbol
 * the price provider does not recognise is worse than no symbol: it produces an empty series that
 * looks like a quiet outage.
 */
export function pickLocalSymbol(
  iso2: string,
  matches: { ticker?: string; exchCode?: string; compositeFIGI?: string }[],
): { symbol: string; compositeFigi?: string } | null {
  const venues = LOCAL_EXCHANGES[iso2];
  if (!venues) return null;
  for (const venue of venues) {
    const hit = matches.find((m) => m.exchCode === venue.figi && m.ticker);
    // The composite FIGI comes back with the match and is the ONLY key that joins a security to
    // `exchange_listing` — the directory endpoint returns no ISIN. Capturing it here is what makes
    // that table joinable at all, so it is carried even though nothing needs it in this call.
    if (hit) return { symbol: `${hit.ticker}${venue.suffix}`, compositeFigi: hit.compositeFIGI };
  }
  return null;
}
