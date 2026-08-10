// Land SEC N-PORT holdings into the normalised model.
//
// The whole job is IDENTITY: a filing names a position by ISIN/CUSIP/LEI and usually not by
// ticker, so every holding has to be resolved to a `security` before it can be stored. Resolution
// is ISIN -> CUSIP -> LEI -> create, and `security_identifier`'s PRIMARY KEY (kind, value) is what
// makes it deterministic — one ISIN can only ever point at one security.
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

/** Every identifier a holding offers, most authoritative first. */
function identifiersOf(h: NportHolding): { kind: string; value: string }[] {
  const out: { kind: string; value: string }[] = []
  if (h.isin) out.push({ kind: 'isin', value: h.isin })
  if (h.cusip) out.push({ kind: 'cusip', value: h.cusip })
  if (h.lei) out.push({ kind: 'lei', value: h.lei })
  return out
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
): Promise<{ ids: (string | null)[]; added: number; skipped: number }> {
  const wanted = holdings.map(identifiersOf)
  const allValues = [...new Set(wanted.flat().map((i) => i.value))]

  // One query for every identifier in the filing.
  const known = new Map<string, string>() // "kind:value" -> security_id
  for (let i = 0; i < allValues.length; i += 500) {
    const chunk = allValues.slice(i, i + 500)
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
    newSecurities.push({
      security_id: securityId,
      name: h.name,
      // A share position is an equity; everything else stays `other` until something classifies
      // it. Guessing a type from a filing's asset category would be a fiction.
      security_type_code: SHARE_UNITS.has(h.units ?? '') ? 'equity' : 'other',
      currency_code: h.currency ?? null,
      country_iso2: h.country && h.country.length === 2 ? h.country : null,
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

  for (let i = 0; i < newSecurities.length; i += 500) {
    const { error } = await db.from('security').insert(newSecurities.slice(i, i + 500))
    if (error) throw new Error(`security insert failed: ${error.message}`)
  }
  for (let i = 0; i < newIdentifiers.length; i += 500) {
    // ignoreDuplicates: two holdings in one filing can share an LEI (different share classes of
    // the same issuer), and the PK would otherwise reject the second.
    const { error } = await db
      .from('security_identifier')
      .upsert(newIdentifiers.slice(i, i + 500), { onConflict: 'kind_code,value', ignoreDuplicates: true })
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
  const { ids, added, skipped } = await resolveSecurities(db, result.holdings)

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
  // A fund can hold the same security twice (different lots); the PK would reject the second, and
  // one filing's duplicates are not worth failing the whole ingest over.
  const seen = new Set<string>()
  const deduped = rows.filter((r) => {
    const k = `${r.security_id}`
    if (seen.has(k)) return false
    seen.add(k)
    return true
  })

  for (let i = 0; i < deduped.length; i += 500) {
    const { error } = await db
      .from('fund_holding')
      .upsert(deduped.slice(i, i + 500), { onConflict: 'fund_id,security_id,as_of' })
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
