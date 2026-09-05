/**
 * DART (Korea) — filing discovery and XBRL transport.
 *
 * THIS FILE IS DISCOVERY AND TRANSPORT ONLY. The parsing is `segments.ts`, unchanged: DART publishes
 * `ifrs-full:ProductsAndServicesAxis`, `SegmentsAxis`, `GeographicalAreasAxis` and
 * `SegmentConsolidationItemsAxis` — the same axes `market.segment_axis` already carries for Diageo —
 * and `parseFacts` matches on the LOCAL name, so `ifrs-full:Revenue` matches the catalogued
 * `Revenue`. Measured 2026-09-05 against Samsung's FY2025 filing: 55 distinct dimensions, all four
 * segment axes present. Nothing about the parser needed to change for Korea.
 *
 * What IS different from SEC, and why this file exists:
 *
 *   - **A filer is addressed by `corp_code`**, not a CIK, and the mapping to a listed company comes
 *     free: every `list.json` row carries `stock_code`, the six digits in front of muffin's `.KS` /
 *     `.KQ` symbols. `corpCode.xml` — the 3.6 MB archive that timed out twice at 240 s in an earlier
 *     spike — is NOT needed and is deliberately not used.
 *   - **`fnlttXbrl.xml` returns a ZIP**, not an XML document.
 *   - **DART is slow from outside Korea.** Measured: 802 KB ZIP in 73.5 s, inflating to a 3.94 MB
 *     instance. Against a 90 s worker that is one filing per run with no margin, which is why every
 *     call here takes an explicit budget and why the caller must pass the REMAINING budget rather
 *     than a fixed timeout.
 */
import { dart as dartOrigin } from './origins.ts'

/** Matches `segments.ts`: a 256 MB worker must not try to hold a bigger document. */
const MAX_INSTANCE_BYTES = 32 * 1024 * 1024
/** The ZIP itself. Samsung's is 802 KB; anything near this is not a filing we can use. */
const MAX_ARCHIVE_BYTES = 24 * 1024 * 1024

export const TOO_LARGE = Symbol('dart archive too large')

const key = () => Deno.env.get('DART_API_KEY') ?? ''

export interface DartFiling {
  rceptNo: string
  corpCode: string
  /** Six digits — the join key to muffin's `005930.KS`. Empty for an unlisted filer. */
  stockCode: string
  corpName: string
  reportName: string
  /** `YYYYMMDD` as DART returns it. */
  receiptDate: string
}

interface ListOptions {
  /** With a corp_code there is NO date-range limit. Without one, DART caps the window at 3 MONTHS. */
  corpCode?: string
  from: string
  to: string
  /** `Y` = KOSPI, `K` = KOSDAQ. Omitted when `corpCode` is given. */
  corpCls?: 'Y' | 'K'
  page?: number
  pageCount?: number
}

export interface ListPage {
  filings: DartFiling[]
  totalPages: number
  totalCount: number
}

/**
 * One page of `list.json`, restricted to periodic disclosures (`pblntf_ty=A`).
 *
 * DART SIGNALS AN ERROR WITH HTTP 200 AND A `status` FIELD, so the status code proves nothing —
 * `status: '100'` with a Korean message is how it reported the 3-month window cap during planning,
 * and `'013'` is its "no data" answer, which is an ANSWER rather than a fault. Treating either as a
 * transport failure would make a normal empty window look like an outage.
 */
export async function listFilings(opts: ListOptions, timeoutMs: number): Promise<ListPage> {
  const q = new URLSearchParams({
    crtfc_key: key(),
    bgn_de: opts.from,
    end_de: opts.to,
    pblntf_ty: 'A',
    page_count: String(opts.pageCount ?? 100),
    page_no: String(opts.page ?? 1),
  })
  if (opts.corpCode) q.set('corp_code', opts.corpCode)
  if (opts.corpCls) q.set('corp_cls', opts.corpCls)

  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    const res = await fetch(`${dartOrigin()}/api/list.json?${q}`, { signal: ctl.signal })
    if (!res.ok) throw new Error(`dart list ${res.status}`)
    const body = await res.json()
    return parseListBody(body)
  } finally {
    clearTimeout(timer)
  }
}

/** Split out so `dart-check.ts` can drive it on a captured body with no network. */
export function parseListBody(body: unknown): ListPage {
  const b = body as Record<string, unknown>
  const status = String(b.status ?? '')
  // '013' is "no matching data" — an empty answer, not a failure. Anything else non-zero is.
  if (status === '013') return { filings: [], totalPages: 0, totalCount: 0 }
  if (status !== '000') throw new Error(`dart list status ${status}: ${String(b.message ?? '')}`)
  const list = Array.isArray(b.list) ? b.list : []
  return {
    totalPages: Number(b.total_page ?? 0),
    totalCount: Number(b.total_count ?? 0),
    filings: list.map((r) => {
      const x = r as Record<string, unknown>
      return {
        rceptNo: String(x.rcept_no ?? ''),
        corpCode: String(x.corp_code ?? ''),
        stockCode: String(x.stock_code ?? '').trim(),
        corpName: String(x.corp_name ?? ''),
        reportName: String(x.report_nm ?? ''),
        receiptDate: String(x.rcept_dt ?? ''),
      }
    }).filter((f) => f.rceptNo !== '' && f.corpCode !== ''),
  }
}

/**
 * The filing's XBRL instance, unzipped.
 *
 * `reprt_code` 11011 is the annual report (사업보고서); DART rejects the request without it.
 * Returns null when DART has no XBRL for the receipt — which is an answer about the filing, not a
 * fault, and must be recorded as such rather than retried for ever.
 */
export async function fetchInstance(
  rceptNo: string,
  timeoutMs: number,
  reprtCode = '11011',
): Promise<string | null | typeof TOO_LARGE> {
  const q = new URLSearchParams({ crtfc_key: key(), rcept_no: rceptNo, reprt_code: reprtCode })
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    const res = await fetch(`${dartOrigin()}/api/fnlttXbrl.xml?${q}`, { signal: ctl.signal })
    if (res.status === 404) return null
    if (!res.ok) throw new Error(`dart xbrl ${res.status} for ${rceptNo}`)

    const declared = Number(res.headers.get('content-length') ?? 0)
    if (declared > MAX_ARCHIVE_BYTES) {
      await res.body?.cancel()
      return TOO_LARGE
    }
    const bytes = new Uint8Array(await res.arrayBuffer())
    const verdict = classifyBody(bytes)
    if (verdict === 'dart-error') return null
    if (verdict === 'not-a-zip') {
      throw new Error(
        `dart xbrl for ${rceptNo} is not a zip: ${new TextDecoder().decode(bytes.subarray(0, 120))}`,
      )
    }
    return readZipEntry(bytes, (name) => name.toLowerCase().endsWith('.xbrl'))
  } finally {
    clearTimeout(timer)
  }
}

/**
 * Is this body an archive, DART saying no, or something we do not understand?
 *
 * A ZIP always starts `PK`. DART answers a bad key or an unknown receipt with a JSON body and HTTP
 * 200 — so the status code proves nothing and, without this, the archive reader would fail on what
 * is really a readable error message. Split out from `fetchInstance` so it can be tested without a
 * network: left inline it was an untested branch, and the mutation that deleted it passed clean.
 */
export function classifyBody(bytes: Uint8Array): 'zip' | 'dart-error' | 'not-a-zip' {
  if (bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b) return 'zip'
  const text = new TextDecoder().decode(bytes.subarray(0, 300))
  const m = text.match(/"status"\s*:\s*"(\d+)"/)
  if (m && m[1] !== '000') return 'dart-error'
  return 'not-a-zip'
}

/**
 * The first entry matching `want`, inflated — a minimal ZIP reader over `DecompressionStream`.
 *
 * HAND-ROLLED ON PURPOSE. The alternative was a CDN import in the hot path of a resource that is
 * already 73 s per call, for about sixty lines of well-specified format. `DecompressionStream` is
 * standard and `segments.ts` sets the precedent for parsing a format directly rather than pulling a
 * library in. Proven against the real Samsung archive during planning: 7 entries, 194,624 bytes
 * deflate -> 3,943,904 bytes, byte-exact.
 *
 * Reads the CENTRAL DIRECTORY rather than scanning local headers, because a local header may carry
 * a zero size with the real one in a trailing data descriptor; the central directory always has it.
 */
export async function readZipEntry(
  bytes: Uint8Array,
  want: (name: string) => boolean,
): Promise<string | null | typeof TOO_LARGE> {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

  // End of Central Directory, scanned backwards. Its comment field is at most 64 KB, so the
  // signature cannot be further from the end than that plus the record itself.
  let eocd = -1
  const floor = Math.max(0, bytes.length - (22 + 0xffff))
  for (let i = bytes.length - 22; i >= floor; i--) {
    if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break }
  }
  if (eocd < 0) throw new Error('dart zip: no end-of-central-directory record')

  const count = dv.getUint16(eocd + 10, true)
  let off = dv.getUint32(eocd + 16, true)
  for (let i = 0; i < count; i++) {
    if (off + 46 > bytes.length || dv.getUint32(off, true) !== 0x02014b50) break
    const method = dv.getUint16(off + 10, true)
    const compSize = dv.getUint32(off + 20, true)
    const uncompSize = dv.getUint32(off + 24, true)
    const nameLen = dv.getUint16(off + 28, true)
    const extraLen = dv.getUint16(off + 30, true)
    const cmtLen = dv.getUint16(off + 32, true)
    const localOff = dv.getUint32(off + 42, true)
    const name = new TextDecoder().decode(bytes.subarray(off + 46, off + 46 + nameLen))

    if (want(name)) {
      if (uncompSize > MAX_INSTANCE_BYTES) return TOO_LARGE
      const lNameLen = dv.getUint16(localOff + 26, true)
      const lExtraLen = dv.getUint16(localOff + 28, true)
      const start = localOff + 30 + lNameLen + lExtraLen
      // COPIED, not a subarray. `subarray` shares the archive's buffer, which TypeScript types as
      // `ArrayBufferLike` (possibly shared) and therefore refuses as a `BlobPart` — and copying the
      // one entry also lets the rest of the archive be collected rather than pinned by the stream.
      const comp = new Uint8Array(compSize)
      comp.set(bytes.subarray(start, start + compSize))
      // 0 = stored, 8 = deflate. DART uses deflate; stored is handled because it is free to.
      if (method === 0) return new TextDecoder('utf-8').decode(comp)
      if (method !== 8) throw new Error(`dart zip: unsupported compression method ${method}`)
      const stream = new Blob([comp]).stream().pipeThrough(new DecompressionStream('deflate-raw'))
      const out = new Uint8Array(await new Response(stream).arrayBuffer())
      return new TextDecoder('utf-8').decode(out)
    }
    off += 46 + nameLen + extraLen + cmtLen
  }
  return null
}

/** `005930.KS` / `000250.KQ` -> `005930`. Null for anything that is not a Korean listing. */
export function stockCodeFromSymbol(symbol: string | null | undefined): string | null {
  if (!symbol) return null
  const m = symbol.match(/^(\d{6})\.(KS|KQ)$/i)
  return m ? m[1] : null
}
