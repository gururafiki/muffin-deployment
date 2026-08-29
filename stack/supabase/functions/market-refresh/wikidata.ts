/**
 * Wikidata industries — the only MULTI-VALUED classification available to this pipeline.
 *
 * Every other source here is single-valued per security: yfinance gives one sector and one
 * industry, a filing gives one, SEC gives one SIC. Measured 2026-08-28, that is why
 * `security_taxonomy` — modelled many-to-many since migration 10 — held exactly `{1: 7754}` at
 * level 2.
 *
 * `industry (P452)` is a list, and it joins on the ISIN this pipeline already holds (P946).
 * Measured live: 12 ISINs in ONE request taking **0.78 s**, 11 of them matched —
 *
 *     Amazon    retail | web service | e-commerce | web hosting service
 *     Unilever  food industry | personal care product | fast-moving consumer goods | ... (9)
 *     Tesla     automotive industry | solar industry | battery industry
 *
 * IT IS CROWD-SOURCED AND IT SHOWS, which is why the source is seeded at the lowest priority of
 * any here (30). Granularity is inconsistent — Nestlé is simply "food industry" where Apple has
 * seven — and there is noise: Microsoft's list includes "International Standard Industrial
 * Classification of All Economic Activities", a reference work rather than an industry. This must
 * never win `security_current.sector_id`; it is useful for exactly one thing, which is telling you
 * the other things a company also is.
 */

const WDQS = 'https://query.wikidata.org/sparql'
/** Wikidata asks for a descriptive agent with contact details; a browser string gets throttled. */
const UA = 'muffin-market-data/1.0 (admin@rafiki.guru)'

export interface WikidataIndustries {
  isin: string
  name: string | null
  industries: string[]
}

/**
 * ONE REQUEST FOR MANY ISINs, via SPARQL `VALUES`.
 *
 * The endpoint is public, free and shared, with a 60-second query timeout and a politeness limit
 * rather than a quota. Batching is therefore the whole game: 50 ISINs cost one request and about a
 * second, where 50 requests would be a minute of someone else's capacity.
 */
export function buildQuery(isins: string[]): string {
  const values = isins.map((i) => `"${i.replace(/[^A-Za-z0-9]/g, '')}"`).join(' ')
  return `SELECT ?isin (SAMPLE(?coLabel) AS ?name)
       (GROUP_CONCAT(DISTINCT ?indLabel; separator="|") AS ?industries) WHERE {
  VALUES ?isin { ${values} }
  ?co wdt:P946 ?isin .
  ?co rdfs:label ?coLabel FILTER(lang(?coLabel)="en")
  OPTIONAL { ?co wdt:P452 ?ind . ?ind rdfs:label ?indLabel FILTER(lang(?indLabel)="en") }
} GROUP BY ?isin`
}

/**
 * Parse the SPARQL JSON.
 *
 * An ISIN that matched a company but has NO `P452` comes back with an empty `industries` string —
 * which is an ANSWER ("Wikidata knows this company and tags it with no industry"), and different
 * from an ISIN that matched nothing at all. Both end up negative-cached, but only because the
 * outcome for us is the same; they are not conflated in the parse.
 */
export function industriesFrom(payload: unknown): WikidataIndustries[] {
  const d = (payload ?? {}) as { results?: { bindings?: Record<string, { value?: unknown }>[] } }
  const out: WikidataIndustries[] = []
  for (const b of d.results?.bindings ?? []) {
    const isin = String(b.isin?.value ?? '').trim()
    if (!isin) continue
    const raw = String(b.industries?.value ?? '')
    out.push({
      isin,
      name: b.name?.value ? String(b.name.value) : null,
      // De-duplicated and trimmed. GROUP_CONCAT with DISTINCT still yields duplicates when two
      // items differ only by whitespace, and a repeated industry would insert the same taxonomy
      // node twice in one statement — the SQLSTATE 21000 failure this schema has hit four times.
      industries: [...new Set(raw.split('|').map((x) => x.trim()).filter(Boolean))],
    })
  }
  return out
}

/**
 * A stable code for an industry label.
 *
 * Wikidata's vocabulary is open, so nodes are created on discovery and the label is the only
 * identity available. Slugged rather than used raw because `taxonomy_node.code` is a join key and
 * a code containing spaces and punctuation is one typo away from never matching.
 */
export function slug(label: string): string {
  return label
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80)
}

export async function fetchIndustries(
  isins: string[],
  timeoutMs = 45_000,
): Promise<WikidataIndustries[]> {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    const res = await fetch(WDQS, {
      method: 'POST',
      headers: {
        'User-Agent': UA,
        'Accept': 'application/sparql-results+json',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: new URLSearchParams({ query: buildQuery(isins) }),
      signal: ctl.signal,
    })
    if (!res.ok) throw new Error(`wikidata ${res.status}`)
    return industriesFrom(await res.json())
  } finally {
    clearTimeout(timer)
  }
}
