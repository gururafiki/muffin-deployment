/**
 * DART transport, offline. No network, no key — `quality.yml` runs this on every PR.
 *
 * WHY A BUILT ZIP RATHER THAN A CAPTURED ONE. The real Samsung archive is 802 KB of binary; a
 * fixture that size does not belong in the repo, and a truncated one would exercise nothing. So the
 * test COMPRESSES a document with `CompressionStream` and assembles a real ZIP around it, which
 * makes the round trip genuine: if the reader mis-parses an offset, the inflate fails or returns
 * the wrong bytes.
 *
 * The reader was separately proven against the real archive during planning — 7 entries, 194,624
 * deflate bytes -> 3,943,904, byte-exact, axes intact. This keeps that true.
 */
import { classifyBody, parseListBody, readZipEntry, stockCodeFromSymbol, TOO_LARGE } from './dart.ts'

let failures = 0
function check(label: string, ok: boolean, detail = ''): void {
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${label}${detail ? ` — ${detail}` : ''}`)
  if (!ok) failures += 1
}

const enc = new TextEncoder()

async function deflate(bytes: Uint8Array): Promise<Uint8Array> {
  const copy = new Uint8Array(bytes.length)
  copy.set(bytes)
  const s = new Blob([copy]).stream().pipeThrough(new CompressionStream('deflate-raw'))
  return new Uint8Array(await new Response(s).arrayBuffer())
}

/** A real single-entry ZIP: local header, data, central directory, EOCD. */
async function buildZip(
  entries: { name: string; body: string; store?: boolean }[],
): Promise<Uint8Array> {
  const parts: Uint8Array[] = []
  const central: Uint8Array[] = []
  let offset = 0
  // EXTRA FIELDS, AND DIFFERENT LENGTHS IN EACH HEADER. Real archives carry them (DART's do), and a
  // fixture without them cannot tell the local header's extra length from the central directory's —
  // a reader that used the wrong one would land mid-data and still pass. Measured: with both at
  // zero, deleting `+ lExtraLen` from the data offset was undetectable.
  const L_EXTRA = 7
  const C_EXTRA = 4
  for (const e of entries) {
    const raw = enc.encode(e.body)
    const data = e.store ? raw : await deflate(raw)
    const name = enc.encode(e.name)
    const lh = new Uint8Array(30 + name.length + L_EXTRA)
    const ldv = new DataView(lh.buffer)
    ldv.setUint32(0, 0x04034b50, true)
    ldv.setUint16(8, e.store ? 0 : 8, true)
    ldv.setUint32(18, data.length, true)
    ldv.setUint32(22, raw.length, true)
    ldv.setUint16(26, name.length, true)
    ldv.setUint16(28, L_EXTRA, true)
    lh.set(name, 30)

    const cd = new Uint8Array(46 + name.length + C_EXTRA)
    const cdv = new DataView(cd.buffer)
    cdv.setUint32(0, 0x02014b50, true)
    cdv.setUint16(10, e.store ? 0 : 8, true)
    cdv.setUint32(20, data.length, true)
    cdv.setUint32(24, raw.length, true)
    cdv.setUint16(28, name.length, true)
    cdv.setUint16(30, C_EXTRA, true)
    cdv.setUint32(42, offset, true)
    cd.set(name, 46)

    parts.push(lh, data)
    central.push(cd)
    offset += lh.length + data.length
  }
  const cdBytes = central.reduce((a, c) => a + c.length, 0)
  const eocd = new Uint8Array(22)
  const edv = new DataView(eocd.buffer)
  edv.setUint32(0, 0x06054b50, true)
  edv.setUint16(8, entries.length, true)
  edv.setUint16(10, entries.length, true)
  edv.setUint32(12, cdBytes, true)
  edv.setUint32(16, offset, true)

  const all = [...parts, ...central, eocd]
  const total = all.reduce((a, p) => a + p.length, 0)
  const out = new Uint8Array(total)
  let at = 0
  for (const p of all) { out.set(p, at); at += p.length }
  return out
}

console.log('\nthe zip reader')
{
  // The shape DART actually returns: several files, only one of which is the instance.
  const instance = '<?xml version="1.0"?><xbrli:xbrl><ifrs-full:Revenue contextRef="c0" unitRef="krw">7050068258000</ifrs-full:Revenue></xbrli:xbrl>'
  const zip = await buildZip([
    { name: 'entity00126380_2025-12-31.xsd', body: '<schema/>' },
    { name: 'entity00126380_2025-12-31.xbrl', body: instance },
    { name: 'entity00126380_2025-12-31_lab-en.xml', body: '<labels/>' },
  ])
  const got = await readZipEntry(zip, (n) => n.toLowerCase().endsWith('.xbrl'))
  check('the .xbrl entry is found among several files and inflates byte-exact',
    got === instance, typeof got === 'string' ? `${got.length} chars` : String(got))

  // NOT THE FIRST ENTRY. A reader that returned entry zero would pass a single-file fixture and
  // fail on every real archive, where the schema sorts first.
  check('...and it is not simply the first entry',
    (await readZipEntry(zip, (n) => n.endsWith('.xsd'))) === '<schema/>')

  check('a name nothing matches returns null, rather than throwing',
    (await readZipEntry(zip, (n) => n.endsWith('.nope'))) === null)

  const stored = await buildZip([{ name: 'a.xbrl', body: '<x/>', store: true }])
  check('a STORED (uncompressed) entry is read too', (await readZipEntry(stored, () => true)) === '<x/>')

  // A JSON error body wearing a 200 must not reach the reader as if it were an archive. Asserted
  // against `classifyBody`, which is the decision that actually makes it: pointing this at
  // `readZipEntry` proved nothing, because that throws on a missing EOCD either way — the mutation
  // deleting the guard passed clean until this was split out.
  check('DART answering an error as JSON+200 reads as an error, not an archive',
    classifyBody(enc.encode('{"status":"010","message":"등록되지 않은 키입니다."}')) === 'dart-error')
  check('...and a real archive reads as one',
    classifyBody(await buildZip([{ name: 'a.xbrl', body: '<x/>' }])) === 'zip')
  check('...while an unrecognised body is neither, and must not be swallowed',
    classifyBody(enc.encode('<html>gateway timeout</html>')) === 'not-a-zip')
  check('a DART body reporting SUCCESS but not being a zip is still not-a-zip',
    classifyBody(enc.encode('{"status":"000","message":"정상"}')) === 'not-a-zip')

  // AND DART SAYS NO IN XML TOO, WHICH IS THE FORM `document.xml` ACTUALLY USES.
  //
  // Quoted from production 2026-09-06. Status 014 is "the file does not exist" — an ordinary,
  // permanent fact about an immutable filing. Matching only the JSON form made it fall through to
  // `not-a-zip`, which THROWS, and a throw never reaches the code that stamps
  // `segments_parsed_at`: four filings held the head of a 6,393-filing backlog through 143
  // IDENTICAL runs over twelve hours.
  check('DART answering an error as XML+200 reads as an error, not an archive',
    classifyBody(enc.encode(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      + '<result><status>014</status><message>파일이 존재하지 않습니다</message></result>',
    )) === 'dart-error')
  check('...the XML success status is still not an archive',
    classifyBody(enc.encode(
      '<?xml version="1.0"?><result><status>000</status><message>정상</message></result>',
    )) === 'not-a-zip')
  // The unrecognised-body case must survive the widening: an HTML gateway page carries no status
  // at all, and swallowing it would turn a proxy outage into 6,393 filings marked as read.
  check('...and an HTML error page is STILL not-a-zip after the widening',
    classifyBody(enc.encode('<html><body>504 Gateway Time-out</body></html>')) === 'not-a-zip')

  const huge = await buildZip([{ name: 'big.xbrl', body: 'x' }])
  const dv = new DataView(huge.buffer)
  // Rewrite the central directory's uncompressed size to claim 64 MB.
  const eocdAt = huge.length - 22
  const cdOff = dv.getUint32(eocdAt + 16, true)
  dv.setUint32(cdOff + 24, 64 * 1024 * 1024, true)
  check('an entry claiming more than the 32 MB ceiling is refused, not inflated',
    (await readZipEntry(huge, () => true)) === TOO_LARGE)
}

console.log('\nthe filing list')
{
  const ok = parseListBody({
    status: '000', message: '정상', total_page: 10, total_count: 950,
    list: [
      { rcept_no: '20260310002820', corp_code: '00126380', stock_code: '005930',
        corp_name: '삼성전자', report_nm: '사업보고서 (2025.12)', rcept_dt: '20260310' },
      // An unlisted filer: no stock_code, so nothing in muffin can join to it.
      { rcept_no: '20260311000001', corp_code: '00999999', stock_code: '  ',
        corp_name: '비상장', report_nm: '사업보고서 (2025.12)', rcept_dt: '20260311' },
    ],
  })
  check('a normal page parses', ok.filings.length === 2 && ok.totalPages === 10)
  check('the stock_code survives as the join key', ok.filings[0].stockCode === '005930')
  check('a blank stock_code is normalised to empty, not whitespace', ok.filings[1].stockCode === '')

  // '013' IS AN ANSWER. DART returns it for a window with no filings, with HTTP 200 — treating it
  // as a fault would make an ordinary empty window look like an outage and stall the sweep.
  check('status 013 (no data) is an empty answer, not an error',
    parseListBody({ status: '013', message: '조회된 데이타가 없습니다.' }).filings.length === 0)

  // …and every OTHER non-zero status is a real failure, including the one that bit during planning.
  let threw = false
  try {
    parseListBody({ status: '100', message: 'corp_code가 없는 경우 검색기간은 3개월만 가능합니다.' })
  } catch { threw = true }
  check('status 100 (the 3-month window cap) throws', threw)
}

console.log('\nthe symbol join')
{
  check('a KOSPI symbol yields six digits', stockCodeFromSymbol('005930.KS') === '005930')
  check('a KOSDAQ symbol does too', stockCodeFromSymbol('086520.KQ') === '086520')
  check('a US ticker is not a Korean listing', stockCodeFromSymbol('AAPL') === null)
  // `.KS` is not enough on its own: the six digits are the contract, and a five-digit code would
  // silently join to nothing.
  check('a malformed code is refused', stockCodeFromSymbol('12345.KS') === null)
  check('null in, null out', stockCodeFromSymbol(null) === null)
}

console.log(failures === 0 ? '\nALL DART CHECKS PASSED' : `\n${failures} DART CHECK(S) FAILED`)
if (failures > 0) Deno.exit(1)
