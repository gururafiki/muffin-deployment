// Land SEC N-PORT holdings into the normalised model.
//
// The whole job is IDENTITY: a filing names a position by ISIN/CUSIP/LEI and usually not by
// ticker, so every holding has to be resolved to a `security` before it can be stored. Resolution
// is ISIN -> CUSIP -> FIGI/other -> create, and `security_identifier`'s PRIMARY KEY (kind, value)
// is what makes it deterministic — one ISIN can only ever point at one security.
//
// NOT via LEI, though the original design said so: an LEI names the ISSUER, so resolving on it
// merges GOOG into GOOGL. It populates `market.issuer` instead.
//
// Everything is done in BULK. A filing is 70-900 rows; doing this per holding would be thousands
// of round trips inside a worker that has 60 seconds.

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0'
import { fetchFundHoldings, loadFundDirectory, type NportHolding } from './edgar.ts'

/**
 * What `supabase.schema('market')` returns — a PostgrestClient, NOT a SupabaseClient. Typing these
 * helpers as SupabaseClient compiles against the top-level client and then fails at the call site,
 * which is how this was caught.
 */
type MarketClient = ReturnType<SupabaseClient['schema']>

const SOURCE = 'sec-nport'

/**
 * How many identifiers to look up per request.
 *
 * A PostgREST `in.(…)` filter travels in the QUERY STRING, so this is a URL-length budget rather
 * than a row budget. Measured 2026-08-10: 500 ISINs is a ~6.5 KB URL and the proxy in front of
 * PostgREST answers **502**, with nothing in the message to suggest the cause. 250 works; 100
 * keeps the URL near 1.4 KB and leaves room for longer identifier kinds.
 */
const LOOKUP_CHUNK = 100

/** Rows per write. Not URL-bound (these are POST bodies), so it can stay large. */
const WRITE_CHUNK = 500

/** N-PORT `units` for a share position; anything else is a bond, contract, etc. */
const SHARE_UNITS = new Set(['NS'])

export interface IngestResult {
  fund: string
  reportDate: string
  holdings: number
  securitiesAdded: number
  skipped: number
}

/**
 * Lookup values (currency, assetCat, issuerCat) are DISCOVERED from filings, not seeded.
 *
 * `fund_holding` has FKs to all three, so an unseen currency would fail the whole insert. Learning
 * them keeps the tables honest (they only ever contain codes we have actually seen) and means a
 * new asset category never needs a migration.
 */
async function learnLookups(db: MarketClient, holdings: NportHolding[]) {
  const uniq = (vals: (string | undefined)[]) => [...new Set(vals.filter((v): v is string => !!v))]
  const rows = (codes: string[]) => codes.map((code) => ({ code, name: code }))

  const currencies = uniq(holdings.map((h) => h.currency))
  const assetCats = uniq(holdings.map((h) => h.assetCategory))
  const issuerCats = uniq(holdings.map((h) => h.issuerCategory))

  for (const [table, data] of [
    ['currency', currencies.map((code) => ({ code }))],
    ['asset_category', rows(assetCats)],
    ['issuer_category', rows(issuerCats)],
  ] as const) {
    if (data.length === 0) continue
    const { error } = await db.from(table).upsert(data, { onConflict: 'code', ignoreDuplicates: true })
    if (error) throw new Error(`${table} upsert failed: ${error.message}`)
  }
}

/**
 * Reject SEC's PLACEHOLDER identifiers. This is the single most important guard in the file.
 *
 * `<cusip>000000000</cusip>` means "this security has no CUSIP" — it is not a value. Measured over
 * five funds on 2026-08-10: 221 of 308 holdings (72%) carry it, and for EWJ it is 176 of 182.
 * Treating it as real makes `security_identifier`'s PRIMARY KEY (kind, value) collapse every one of
 * them into a SINGLE security, so Accenture, Seagate, TE Connectivity and NXP all resolve to
 * whichever was seen first. Nothing errors; the fund simply reports the wrong companies. It showed
 * up only as XLK's weights summing to 97.1% instead of 100%.
 *
 * Format checks come along for free and catch the same class of junk (empty, 'N/A', 'NONE').
 */
const IDENTIFIER_FORMAT: Record<string, RegExp> = {
  isin: /^[A-Z]{2}[A-Z0-9]{9}[0-9]$/,
  cusip: /^[A-Z0-9]{9}$/,
  figi: /^BBG[A-Z0-9]{9}$/,
  lei: /^[A-Z0-9]{20}$/,
}

function isUsableIdentifier(kind: string, raw: string | undefined): raw is string {
  if (!raw) return false
  const v = raw.trim().toUpperCase()
  if (!v || v === 'N/A' || v === 'NONE' || v === 'UNKNOWN') return false
  // All-zero (or all-same-character) values are placeholders, never identifiers.
  if (/^(.)\1*$/.test(v)) return false
  const fmt = IDENTIFIER_FORMAT[kind]
  return fmt ? fmt.test(v) : true
}

/**
 * The identifiers that identify THE SECURITY, most authoritative first.
 *
 * LEI IS DELIBERATELY ABSENT. An LEI names the *issuer*, not the instrument — GOOG and GOOGL share
 * one, and so do two share classes in the same filing. Resolving on it would merge distinct
 * securities exactly the way the placeholder CUSIP did. It is used below to populate
 * `market.issuer`, which is what the model always intended it for.
 */
function identifiersOf(h: NportHolding): { kind: string; value: string }[] {
  const out: { kind: string; value: string }[] = []
  if (isUsableIdentifier('isin', h.isin)) out.push({ kind: 'isin', value: h.isin!.trim().toUpperCase() })
  if (isUsableIdentifier('cusip', h.cusip)) out.push({ kind: 'cusip', value: h.cusip!.trim().toUpperCase() })
  for (const o of h.other ?? []) {
    // A Bloomberg Identifier is a FIGI/BBGID and is the only key some derivative rows carry.
    const kind = /bloomberg/i.test(o.desc) ? 'figi' : 'other'
    if (isUsableIdentifier(kind, o.value)) out.push({ kind, value: o.value.trim().toUpperCase() })
  }
  return out
}

/**
 * The ISO-2 codes `market.countries` actually knows.
 *
 * Both `issuer.country_iso2` and `security.country_iso2` are FKs to it, and N-PORT uses `XX` for
 * "country unknown" — a real value in the filings (MCHI has one) that is not a country. Left
 * unchecked it aborts the whole fund with a foreign-key violation, which is how MCHI and EWU
 * failed. Anything the table does not know becomes NULL: unknown provenance is not worth losing
 * a 500-holding filing over, and inventing a country would be worse.
 */
async function loadKnownCountries(db: MarketClient): Promise<Set<string>> {
  const { data, error } = await db.from('countries').select('iso2')
  if (error) throw new Error(`countries read failed: ${error.message}`)
  return new Set((data ?? []).map((c) => c.iso2 as string))
}

const countryOf = (h: NportHolding, known: Set<string>): string | null =>
  h.country && known.has(h.country.toUpperCase()) ? h.country.toUpperCase() : null

/**
 * Resolve LEIs to issuers, creating the ones we have never seen.
 *
 * This is where the LEI belongs: `market.issuer.lei` is UNIQUE, so two share classes of one company
 * converge on one issuer row instead of being merged into one security. Returns lei -> issuer_id.
 */
async function resolveIssuers(
  db: MarketClient,
  holdings: NportHolding[],
  countries: Set<string>,
): Promise<Map<string, string>> {
  const leis = [
    ...new Set(
      holdings
        .map((h) => (isUsableIdentifier('lei', h.lei) ? h.lei!.trim().toUpperCase() : null))
        .filter((v): v is string => !!v),
    ),
  ]
  const byLei = new Map<string, string>()
  if (leis.length === 0) return byLei

  for (let i = 0; i < leis.length; i += LOOKUP_CHUNK) {
    const { data, error } = await db
      .from('issuer')
      .select('issuer_id,lei')
      .in('lei', leis.slice(i, i + LOOKUP_CHUNK))
    if (error) throw new Error(`issuer lookup failed: ${error.message}`)
    for (const r of data ?? []) byLei.set(r.lei as string, r.issuer_id as string)
  }

  // Name/country come from the FIRST holding carrying each LEI — they agree across share classes.
  const fresh: Record<string, unknown>[] = []
  for (const h of holdings) {
    if (!isUsableIdentifier('lei', h.lei)) continue
    const lei = h.lei!.trim().toUpperCase()
    if (byLei.has(lei)) continue
    const issuerId = crypto.randomUUID()
    byLei.set(lei, issuerId)
    fresh.push({
      issuer_id: issuerId,
      name: h.name,
      lei,
      country_iso2: countryOf(h, countries),
    })
  }
  for (let i = 0; i < fresh.length; i += WRITE_CHUNK) {
    const { error } = await db
      .from('issuer')
      .upsert(fresh.slice(i, i + WRITE_CHUNK), { onConflict: 'lei', ignoreDuplicates: true })
    if (error) throw new Error(`issuer insert failed: ${error.message}`)
  }
  return byLei
}

/**
 * Resolve every holding to a security_id, creating the ones we have never seen.
 *
 * Returns a map from the holding's index to its security_id. A holding with NO usable identifier
 * is skipped rather than invented — an unidentifiable position cannot be joined to anything later,
 * and a synthetic key would quietly become a duplicate of a real security.
 */
async function resolveSecurities(
  db: MarketClient,
  holdings: NportHolding[],
  issuers: Map<string, string>,
  countries: Set<string>,
): Promise<{ ids: (string | null)[]; added: number; skipped: number }> {
  const wanted = holdings.map(identifiersOf)
  const allValues = [...new Set(wanted.flat().map((i) => i.value))]

  // One query per LOOKUP_CHUNK identifiers in the filing.
  const known = new Map<string, string>() // "kind:value" -> security_id
  for (let i = 0; i < allValues.length; i += LOOKUP_CHUNK) {
    const chunk = allValues.slice(i, i + LOOKUP_CHUNK)
    const { data, error } = await db
      .from('security_identifier')
      .select('kind_code,value,security_id')
      .in('value', chunk)
    if (error) throw new Error(`identifier lookup failed: ${error.message}`)
    for (const r of data ?? []) known.set(`${r.kind_code}:${r.value}`, r.security_id as string)
  }

  const ids: (string | null)[] = []
  const newSecurities: Record<string, unknown>[] = []
  const newIdentifiers: Record<string, unknown>[] = []
  let skipped = 0

  for (let i = 0; i < holdings.length; i++) {
    const h = holdings[i]
    const idents = wanted[i]
    if (idents.length === 0) {
      ids.push(null)
      skipped++
      continue
    }
    const hit = idents.map((d) => known.get(`${d.kind}:${d.value}`)).find(Boolean)
    if (hit) {
      ids.push(hit)
      continue
    }
    // New security. crypto.randomUUID is available in the edge runtime; generating the id here
    // lets the identifiers be inserted in the same batch instead of reading ids back.
    const securityId = crypto.randomUUID()
    ids.push(securityId)
    const lei = isUsableIdentifier('lei', h.lei) ? h.lei!.trim().toUpperCase() : null
    newSecurities.push({
      security_id: securityId,
      issuer_id: lei ? (issuers.get(lei) ?? null) : null,
      name: h.name,
      // A share position is an equity; everything else stays `other` until something classifies
      // it. Guessing a type from a filing's asset category would be a fiction.
      security_type_code: SHARE_UNITS.has(h.units ?? '') ? 'equity' : 'other',
      currency_code: h.currency ?? null,
      country_iso2: countryOf(h, countries),
      is_tradeable: false, // until a ticker is resolved by the profile enrichment
    })
    for (const d of idents) {
      newIdentifiers.push({
        kind_code: d.kind,
        value: d.value,
        security_id: securityId,
        source_code: SOURCE,
      })
      known.set(`${d.kind}:${d.value}`, securityId)
    }
  }

  for (let i = 0; i < newSecurities.length; i += WRITE_CHUNK) {
    const { error } = await db.from('security').insert(newSecurities.slice(i, i + WRITE_CHUNK))
    if (error) throw new Error(`security insert failed: ${error.message}`)
  }
  for (let i = 0; i < newIdentifiers.length; i += WRITE_CHUNK) {
    // ignoreDuplicates: a filing can list the same security in two lots, so the same (kind, value)
    // can appear twice in one batch and the PK would otherwise reject the whole insert.
    const { error } = await db
      .from('security_identifier')
      .upsert(newIdentifiers.slice(i, i + WRITE_CHUNK), { onConflict: 'kind_code,value', ignoreDuplicates: true })
    if (error) throw new Error(`identifier insert failed: ${error.message}`)
  }

  return { ids, added: newSecurities.length, skipped }
}

/** Resolve (or create) the fund itself — a fund IS a security, keyed by its ticker. */
async function resolveFund(db: MarketClient, symbol: string, name: string): Promise<string> {
  const { data, error } = await db
    .from('security_identifier')
    .select('security_id')
    .eq('kind_code', 'ticker')
    .eq('value', symbol)
    .maybeSingle()
  if (error) throw new Error(`fund lookup failed: ${error.message}`)
  if (data?.security_id) return data.security_id as string

  const securityId = crypto.randomUUID()
  const ins = await db.from('security').insert({
    security_id: securityId,
    name,
    security_type_code: 'etf',
    is_tradeable: true,
  })
  if (ins.error) throw new Error(`fund insert failed: ${ins.error.message}`)
  const idn = await db
    .from('security_identifier')
    .upsert(
      { kind_code: 'ticker', value: symbol, security_id: securityId, source_code: SOURCE },
      { onConflict: 'kind_code,value', ignoreDuplicates: true },
    )
  if (idn.error) throw new Error(`fund identifier insert failed: ${idn.error.message}`)
  return securityId
}

/**
 * Ingest one fund's latest filing.
 *
 * Re-running is a no-op: the holdings snapshot upserts on (fund, security, as_of), and resolution
 * finds the securities it created last time. That idempotence is what makes the monthly schedule
 * and a manual scoped refresh interchangeable.
 */
export async function ingestFund(
  db: MarketClient,
  symbol: string,
  directory?: Map<string, { symbol: string; cik: string; seriesId: string }>,
): Promise<IngestResult | null> {
  const dir = directory ?? (await loadFundDirectory())
  const ref = dir.get(symbol.toUpperCase())
  if (!ref) throw new Error(`${symbol} is not an SEC-registered fund (no N-PORT to read)`)

  // Cached cik/series/accession make later runs skip the series probe entirely.
  const { data: tracked } = await db
    .from('tracked_fund')
    .select('name,last_accession,last_report_date')
    .eq('symbol', symbol)
    .maybeSingle()

  const result = await fetchFundHoldings(ref, {
    accession: tracked?.last_accession ?? undefined,
    reportDate: tracked?.last_report_date ?? undefined,
  })
  if (!result) return null

  await learnLookups(db, result.holdings)
  const fundId = await resolveFund(db, symbol, tracked?.name ?? symbol)
  const countries = await loadKnownCountries(db)
  const issuers = await resolveIssuers(db, result.holdings, countries)
  const { ids, added, skipped } = await resolveSecurities(db, result.holdings, issuers, countries)

  const rows = result.holdings.flatMap((h, i) =>
    ids[i] === null
      ? []
      : [{
          fund_id: fundId,
          security_id: ids[i],
          as_of: result.filing.reportDate,
          weight: h.weight ?? null,
          balance: h.balance ?? null,
          market_value: h.valueUsd ?? null,
          currency_code: h.currency ?? null,
          asset_category_code: h.assetCategory ?? null,
          issuer_category_code: h.issuerCategory ?? null,
          source_code: SOURCE,
        }],
  )
  // A fund can hold the same security in two lots, which the PK (fund, security, as_of) cannot
  // store twice. COMBINE them rather than keeping the first: a fund holding a security in two lots
  // holds the sum, so dropping one silently understates the position (XLK reported State Street
  // twice, and keeping only the first lost 0.07 of its 0.10%).
  const byId = new Map<string, typeof rows[number]>()
  for (const r of rows) {
    const prev = byId.get(r.security_id as string)
    if (!prev) {
      byId.set(r.security_id as string, r)
      continue
    }
    const add = (a: number | null, b: number | null) => (a === null && b === null ? null : (a ?? 0) + (b ?? 0))
    prev.weight = add(prev.weight, r.weight)
    prev.balance = add(prev.balance, r.balance)
    prev.market_value = add(prev.market_value, r.market_value)
  }
  const deduped = [...byId.values()]

  for (let i = 0; i < deduped.length; i += WRITE_CHUNK) {
    const { error } = await db
      .from('fund_holding')
      .upsert(deduped.slice(i, i + WRITE_CHUNK), { onConflict: 'fund_id,security_id,as_of' })
    if (error) throw new Error(`fund_holding upsert failed: ${error.message}`)
  }

  await db
    .from('tracked_fund')
    .update({
      cik: ref.cik,
      series_id: ref.seriesId,
      last_accession: result.filing.accession,
      last_report_date: result.filing.reportDate,
      last_ingested_at: new Date().toISOString(),
    })
    .eq('symbol', symbol)

  return {
    fund: symbol,
    reportDate: result.filing.reportDate,
    holdings: deduped.length,
    securitiesAdded: added,
    skipped,
  }
}
