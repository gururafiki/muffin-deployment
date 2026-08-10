// SEC EDGAR client: ticker -> fund -> latest N-PORT filing -> holdings.
//
// WHY NOT OPENBB. `etf/holdings` has no `sec` provider on the installed version, and
// `etf/nport_disclosure?provider=sec` 500s with a pydantic ValidationError on every equity fund
// (`other_id / counterparty / expiry_date … input_value=nan` — fields that only apply to
// derivative rows). We already run the latest openbb 4.7.2 / openbb-sec 1.6.7, so there is no
// upgrade. EDGAR is the source those providers wrap anyway.
//
// SEC ACCESS RULES, which are not optional:
//   * a descriptive User-Agent with contact details is REQUIRED — requests without one are refused
//   * fair-access limit is ~10 req/s; this stays far below it and is called monthly
//   * throttling under a burst is REAL and shows up as a non-ok response, not an error body —
//     see secFetch; treating it as "no data" silently loses a whole fund
//   * an earlier note here claimed the `browse-edgar` CGI returns 503. Re-measured 2026-08-10: it
//     answers 200 with a valid series-filtered atom feed. It is still unused — full-text search
//     returns JSON with the accession and period directly — but do not repeat the 503 claim
//   * SEC IGNORES `Range` headers (it returns 200 and the whole body), so reading "just the
//     header" means streaming and cancelling client-side, which is what probeSeriesId does

const UA = Deno.env.get('SEC_USER_AGENT') ?? 'muffin-market-data (contact: admin@rafiki.guru)';
const HEADERS = { 'User-Agent': UA, 'Accept-Encoding': 'gzip' };

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/**
 * Fetch from SEC, retrying the failures that are about LOAD rather than about the data.
 *
 * This exists because of a measured false negative: a 39-fund pass reported "no filing found" for
 * EPP and ILF, and both ingested perfectly when re-run alone. SEC had throttled the burst, the
 * throttle surfaced as a non-ok response, and the caller turned that into `null` — which reads as
 * "this fund does not file", a permanent condition, when it was a transient one. A retry costs a
 * second; a silent wrong answer costs a fund's entire holdings.
 *
 * 429/503 are the documented fair-access responses; other 5xx are retried on the same reasoning.
 * A 4xx other than 429 is about the request and is not retried.
 */
async function secFetch(url: string, attempts = 3): Promise<Response> {
  let last = '';
  for (let i = 0; i < attempts; i++) {
    if (i > 0) await sleep(400 * 2 ** (i - 1)); // 400ms, 800ms
    const res = await fetch(url, { headers: HEADERS }).catch((e) => {
      last = String(e);
      return null;
    });
    if (!res) continue;
    if (res.ok) return res;
    last = `${res.status}`;
    const retryable = res.status === 429 || res.status >= 500;
    // Drain the body so the connection can be reused rather than left dangling.
    await res.body?.cancel().catch(() => {});
    if (!retryable) throw new Error(`sec ${res.status} on ${url}`);
  }
  throw new Error(`sec unavailable after ${attempts} attempts on ${url} (last: ${last})`);
}

async function getJson<T>(url: string): Promise<T> {
  const res = await secFetch(url);
  return (await res.json()) as T;
}

// ─── 1. ticker -> (cik, seriesId) ────────────────────────────────────────────

export interface FundRef {
  symbol: string;
  cik: string;
  seriesId: string;
}

/**
 * ETFs are SERIES WITHIN A TRUST, so they are absent from `company_tickers.json` (operating
 * companies) and one CIK covers many funds — EWJ and EWG are both CIK 930667. The seriesId is
 * what identifies the fund, which is why every later step filters on it.
 */
export async function loadFundDirectory(): Promise<Map<string, FundRef>> {
  const raw = await getJson<{ fields: string[]; data: (string | number)[][] }>(
    'https://www.sec.gov/files/company_tickers_mf.json',
  );
  const col = Object.fromEntries(raw.fields.map((f, i) => [f, i]));
  const out = new Map<string, FundRef>();
  for (const row of raw.data) {
    const symbol = String(row[col.symbol] ?? '').toUpperCase();
    if (!symbol) continue;
    // First entry wins: a symbol maps to one share class of one series.
    if (!out.has(symbol)) {
      out.set(symbol, {
        symbol,
        cik: String(row[col.cik]).padStart(10, '0'),
        seriesId: String(row[col.seriesId]),
      });
    }
  }
  return out;
}

// ─── 2. cik -> candidate NPORT-P filings ─────────────────────────────────────

export interface FilingRef {
  accession: string; // no dashes, as the Archives path wants
  reportDate: string;
  filingDate: string;
}

/** Every NPORT-P the trust filed, newest report first. One trust files one per series per quarter. */
export async function listNportFilings(cik: string): Promise<FilingRef[]> {
  const sub = await getJson<{
    filings: { recent: Record<string, (string | number)[]> };
  }>(`https://data.sec.gov/submissions/CIK${cik}.json`);
  const r = sub.filings.recent;
  const out: FilingRef[] = [];
  for (let i = 0; i < (r.form?.length ?? 0); i++) {
    if (String(r.form[i]) !== 'NPORT-P') continue;
    out.push({
      accession: String(r.accessionNumber[i]).replace(/-/g, ''),
      reportDate: String(r.reportDate[i] ?? ''),
      filingDate: String(r.filingDate[i] ?? ''),
    });
  }
  out.sort((a, b) => b.reportDate.localeCompare(a.reportDate));
  return out;
}

const docUrl = (cik: string, accession: string) =>
  `https://www.sec.gov/Archives/edgar/data/${Number(cik)}/${accession}/primary_doc.xml`;

/**
 * Read a filing's seriesId without downloading all of it.
 *
 * The submissions feed does not say which series a filing belongs to, so matching means looking
 * inside. `seriesId` sits in the header, within the first few KB — but SEC ignores Range headers,
 * so the saving comes from cancelling the stream rather than from asking for less.
 */
export async function probeSeriesId(cik: string, accession: string): Promise<string | null> {
  const res = await secFetch(docUrl(cik, accession)).catch(() => null);
  if (!res?.ok || !res.body) return null;
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let head = '';
  try {
    while (head.length < 16_000) {
      const { done, value } = await reader.read();
      if (done) break;
      head += decoder.decode(value, { stream: true });
      const m = head.match(/<seriesId>([^<]+)<\/seriesId>/);
      if (m) return m[1].trim();
    }
  } finally {
    // Stop the download; without this we pay for the whole ~900 KB on every probe.
    await reader.cancel().catch(() => {});
  }
  return head.match(/<seriesId>([^<]+)<\/seriesId>/)?.[1]?.trim() ?? null;
}

/**
 * Find the series' newest filing via EDGAR FULL-TEXT SEARCH — one JSON request per fund.
 *
 * The probe walk below is the fallback, and on its own it is not good enough: a big trust files
 * one NPORT-P per series per quarter, so iShares' CIK 1100663 (hundreds of series) buries a given
 * fund's filing far deeper than any sane probe budget. Measured 2026-08-10: a 24-probe walk found
 * XLK, EWJ, EWZ but could NOT find MCHI or EWU at all. Full-text search finds all five in one hop.
 *
 * The seriesId appears verbatim in the document body, so searching for it is exact rather than
 * heuristic. Results come back RELEVANCE-ordered, not by date — hence the explicit sort, and the
 * date window that keeps the page from being filled with old filings.
 */
async function searchLatestFiling(fund: FundRef): Promise<FilingRef | null> {
  // ~10 months: N-PORT is quarterly and filed up to 60 days in arrears, so this always spans at
  // least two filings while keeping the result page small.
  const start = new Date(Date.now() - 300 * 86_400_000).toISOString().slice(0, 10);
  const end = new Date().toISOString().slice(0, 10);
  const url =
    `https://efts.sec.gov/LATEST/search-index?q=%22${fund.seriesId}%22&forms=NPORT-P` +
    `&startdt=${start}&enddt=${end}`;
  // Deliberately NOT caught here: a throttled request must not read as "this fund does not file".
  const res = await secFetch(url);
  const body = (await res.json()) as {
    hits?: { hits?: { _id?: string; _source?: { period_ending?: string; file_date?: string } }[] };
  };
  const hits = (body.hits?.hits ?? [])
    .map((h) => ({
      accession: String(h._id ?? '').split(':')[0].replace(/-/g, ''),
      reportDate: h._source?.period_ending ?? '',
      filingDate: h._source?.file_date ?? '',
    }))
    .filter((h) => h.accession && h.reportDate);
  if (hits.length === 0) return null;
  // Newest report first; among filings for the SAME period the latest filing date wins, which is
  // how an NPORT-P/A amendment supersedes the original it corrects.
  hits.sort((a, b) =>
    b.reportDate.localeCompare(a.reportDate) || b.filingDate.localeCompare(a.filingDate)
  );
  return hits[0];
}

/**
 * The newest filing belonging to THIS series.
 *
 * Full-text search first, then the probe walk for anything it cannot see (FTS coverage starts in
 * 2001 and can lag a very recent filing by a day or so). `maxProbes` bounds the walk.
 */
export async function findLatestFiling(
  fund: FundRef,
  maxProbes = 24,
): Promise<FilingRef | null> {
  // No catch: secFetch has already retried, so an error here is real and the caller must see the
  // reason rather than a null that means "no filing".
  const found = await searchLatestFiling(fund);
  if (found) return found;

  const filings = await listNportFilings(fund.cik);
  let probes = 0;
  for (const f of filings) {
    if (probes >= maxProbes) break;
    probes++;
    if ((await probeSeriesId(fund.cik, f.accession)) === fund.seriesId) return f;
  }
  return null;
}

// ─── 3. filing -> holdings ───────────────────────────────────────────────────

export interface NportHolding {
  name: string;
  title?: string;
  lei?: string;
  cusip?: string;
  isin?: string;
  /** `<other otherDesc="Bloomberg Identifier" value="BBG…"/>` — the only key some rows carry. */
  other?: { desc: string; value: string }[];
  balance?: number;
  units?: string;
  currency?: string;
  valueUsd?: number;
  weight?: number;
  assetCategory?: string;
  issuerCategory?: string;
  country?: string;
}

const tag = (block: string, name: string): string | undefined => {
  const m = block.match(new RegExp(`<${name}>([^<]*)</${name}>`));
  const v = m?.[1]?.trim();
  return v && v !== 'N/A' ? v : undefined;
};
const num = (v: string | undefined): number | undefined => {
  if (v === undefined) return undefined;
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
};

/**
 * Parse `<invstOrSec>` blocks out of a filing.
 *
 * Deliberately regex over the block rather than a DOM: the document is machine-generated and
 * regular, and building a DOM for ~900 KB inside a 150 MB worker (times a batch of funds) is the
 * kind of thing that made the price refresh die without answering.
 *
 * NOTE identifiers are ATTRIBUTES, not text: `<identifiers><isin value="US0378331005"/></…>`.
 * Reading them as element text yields empty strings and silently loses every ISIN.
 */
export function parseHoldings(xml: string): NportHolding[] {
  const out: NportHolding[] = [];
  const blocks = xml.match(/<invstOrSec>[\s\S]*?<\/invstOrSec>/g) ?? [];
  for (const b of blocks) {
    const name = tag(b, 'name');
    if (!name) continue;
    const isin = b.match(/<isin[^>]*value="([^"]+)"/)?.[1];
    const other = [...b.matchAll(/<other[^>]*otherDesc="([^"]*)"[^>]*value="([^"]+)"/g)]
      .map((m) => ({ desc: m[1], value: m[2] }));
    out.push({
      name,
      title: tag(b, 'title'),
      lei: tag(b, 'lei'),
      cusip: tag(b, 'cusip'),
      isin,
      other: other.length ? other : undefined,
      balance: num(tag(b, 'balance')),
      units: tag(b, 'units'),
      currency: tag(b, 'curCd'),
      valueUsd: num(tag(b, 'valUSD')),
      weight: num(tag(b, 'pctVal')),
      assetCategory: tag(b, 'assetCat'),
      issuerCategory: tag(b, 'issuerCat'),
      country: tag(b, 'invCountry'),
    });
  }
  return out;
}

export interface FundHoldings {
  fund: FundRef;
  filing: FilingRef;
  holdings: NportHolding[];
}

/** The whole walk for one fund. Callers batch over funds so peak memory is one filing. */
export async function fetchFundHoldings(
  fund: FundRef,
  known?: { accession?: string; reportDate?: string },
): Promise<FundHoldings | null> {
  // A cached accession skips the probe entirely — the common case after the first run.
  let filing: FilingRef | null = null;
  if (known?.accession && known?.reportDate) {
    const latest = (await listNportFilings(fund.cik))[0];
    if (latest && latest.reportDate <= known.reportDate) {
      filing = { accession: known.accession, reportDate: known.reportDate, filingDate: '' };
    }
  }
  filing ??= await findLatestFiling(fund);
  if (!filing) return null;

  const res = await secFetch(docUrl(fund.cik, filing.accession));
  return { fund, filing, holdings: parseHoldings(await res.text()) };
}
