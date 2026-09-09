import * as jose from 'https://deno.land/x/jose@v4.14.4/index.ts'

console.log('main function started')

const JWT_SECRET = Deno.env.get('JWT_SECRET')
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')
const VERIFY_JWT = Deno.env.get('VERIFY_JWT') === 'true'

// Create JWKS for ES256/RS256 tokens (newer tokens)
let SUPABASE_JWT_KEYS: ReturnType<typeof jose.createRemoteJWKSet> | null = null
if (SUPABASE_URL) {
  try {
    SUPABASE_JWT_KEYS = jose.createRemoteJWKSet(
      new URL('/auth/v1/.well-known/jwks.json', SUPABASE_URL)
    )
  } catch (e) {
    console.error('Failed to fetch JWKS from SUPABASE_URL:', e)
  }
}

/**
 * Extract JWT token from Authorization header
 * 
 * Parses the Authorization header to extract the Bearer token.
 * Expects format: "Bearer <token>"
 * 
 * @param req - The HTTP request object
 * @returns The JWT token string
 * @throws Error if Authorization header is missing or malformed
 */
function getAuthToken(req: Request) {
  const authHeader = req.headers.get('authorization')
  if (!authHeader) {
    throw new Error('Missing authorization header')
  }
  const [bearer, token] = authHeader.split(' ')
  if (bearer !== 'Bearer') {
    throw new Error(`Auth header is not 'Bearer {token}'`)
  }
  return token
}

async function isValidLegacyJWT(jwt: string): Promise<boolean> {
  if (!JWT_SECRET) {
    console.error('JWT_SECRET not available for HS256 token verification')
    return false
  }

  const encoder = new TextEncoder();
  const secretKey = encoder.encode(JWT_SECRET)

  try {
    await jose.jwtVerify(jwt, secretKey);
  } catch (e) {
    console.error('Symmetric Legacy JWT verification error', e);
    return false;
  }
  return true;
}

async function isValidJWT(jwt: string): Promise<boolean> {
  if (!SUPABASE_JWT_KEYS) {
    console.error('JWKS not available for ES256/RS256 token verification')
    return false
  }

  try {
    await jose.jwtVerify(jwt, SUPABASE_JWT_KEYS)
  } catch (e) {
    console.error('Asymmetric JWT verification error', e);
    return false
  }

  return true;
}

/**
 * Verify JWT token, handling both legacy (HS256) and newer (ES256/RS256) algorithms
 * 
 * This function automatically detects the algorithm used in the token and applies
 * the appropriate verification method:
 * - HS256: Uses JWT_SECRET (symmetric key)
 * - ES256/RS256: Uses JWKS endpoint (asymmetric public keys)
 * 
 * This fix ensures compatibility with both legacy tokens and newer asymmetric tokens,
 * resolving the "Key for the ES256 algorithm must be of type CryptoKey" error.
 * 
 * @param jwt - The JWT token string to verify
 * @returns Promise resolving to true if verification succeeds, false otherwise
 */
async function isValidHybridJWT(jwt: string): Promise<boolean> {
  const { alg: jwtAlgorithm } = jose.decodeProtectedHeader(jwt)

  if (jwtAlgorithm === 'HS256') {
    console.log(`Legacy token type detected, attempting ${jwtAlgorithm} verification.`)

    return await isValidLegacyJWT(jwt)
  }

  if (jwtAlgorithm === 'ES256' || jwtAlgorithm === 'RS256') {
    return await isValidJWT(jwt)
  }

  return false;
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'OPTIONS' && VERIFY_JWT) {
    try {
      const token = getAuthToken(req)
      const isValidJWT = await isValidHybridJWT(token);

      if (!isValidJWT) {
        return new Response(JSON.stringify({ msg: 'Invalid JWT' }), {
          status: 401,
          headers: { 'Content-Type': 'application/json' },
        })
      }
    } catch (e) {
      console.error(e)
      return new Response(JSON.stringify({ msg: e.toString() }), {
        status: 401,
        headers: { 'Content-Type': 'application/json' },
      })
    }
  }

  const url = new URL(req.url)
  const { pathname } = url
  const path_parts = pathname.split('/')
  const service_name = path_parts[1]

  if (!service_name || service_name === '') {
    const error = { msg: 'missing function name in request' }
    return new Response(JSON.stringify(error), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const servicePath = `/home/deno/functions/${service_name}`
  console.error(`serving the request with ${servicePath}`)

  // These are OURS, not a platform limit — self-hosted edge-runtime takes whatever we pass. Both
  // were the defaults copied from Supabase's example router and were never sized for this node.
  //
  // MEMORY 150 -> 256 MB. The container's own limit is 512 MB, so this still fits two concurrent
  // workers. 150 MB is what made the price refresh and the FIGI resolver die with a BARE 502 (a
  // killed worker answers nothing), and it is why several resources batch more aggressively than
  // the provider requires.
  //
  // TIMEOUT 60 -> 90 s. The real ceiling is NOT this number: supabase.<domain> is proxied by
  // Cloudflare, which cuts a request at ~100 s, so 90 leaves margin to return an answer rather
  // than have one truncated in flight. Raising it further would only move where the failure
  // happens.
  //
  // This does NOT remove the need for incremental, wall-clock-bounded resources — a 9,786-security
  // backlog does not fit in 90 s either — it just stops the limit from being the thing that shapes
  // every batch size.
  // 256 -> 384 MB. MEASURED 2026-09-09 by driving the real CNINFO parser against the real document
  // at the head of `pending_cn_segments`: RSS scales with the PDF, 74 MB for a 1.46 MB report and
  // **129 MB for a 9.15 MB one**, while the parse itself is 577 ms and the heap only reaches 51 MB.
  // So one ordinary Chinese annual report plus this worker's own baseline does not fit 256 MB, and
  // `security-cn-segments` was killed by the supervisor in UNDER TWO SECONDS on every firing —
  // reproduced after a deploy, so it is not contention. A killed worker writes no `refresh_run`
  // row, so it went silent rather than red for two days.
  //
  // The container was raised to 1 GB in the same phase, so 384 MB still allows two concurrent
  // workers with headroom, and the kill is the isolate's own limit rather than the cgroup's —
  // which is why `OOMKilled` is false and the kernel logs no oom-kill for it.
  //
  // This is a ceiling, not a fix. The fix is parsing in a bounded subprocess, which is what
  // muffin-ingest does; see the ingestion rework design in the umbrella.
  const memoryLimitMb = 384
  const workerTimeoutMs = 90 * 1000
  // THE THIRD LIMIT, AND NOTHING HERE HAS EVER SET IT.
  //
  // `memoryLimitMb` and `workerTimeoutMs` were tuned and written up; CPU TIME was left at the
  // runtime's default and is what has actually been killing `security-cn-segments`. Measured
  // 2026-09-09, after raising the isolate to 384 MB and lowering the PDF gate changed nothing:
  //
  //   [Info] Warning: TT: undefined function: 3      <- the PDF parse has started
  //   CPU time soft limit reached: isolate: 51af54f5…
  //   CPU time hard limit reached: isolate: 51af54f5…
  //   user worker failed to respond: request has been cancelled by supervisor
  //
  // The request died after 2.87 SECONDS against a 70-second handler deadline and a 90-second
  // worker timeout, with `OOMKilled` false and no kernel oom-kill — which is why every memory
  // theory (a page of six, then one document, then a bigger isolate) was wrong in turn. A CPU
  // budget is not a wall clock: parsing a 90-page PDF costs 577 ms of CPU on an M-series laptop
  // and several times that on this node's Ampere core, so a default in the low seconds is a
  // ceiling the segment parsers sit right on top of.
  //
  // The wall clock stays the PRIMARY bound at 90 s, and every handler's own deadline is wall-clock
  // based, so these are set well under it: a runaway is still stopped, by the limit the code
  // already reasons about. The names are exactly as the runtime spells them — verified against the
  // binary's own symbols, because an unrecognised option here would be silently ignored, which is
  // the failure mode this whole file exists to avoid.
  const cpuTimeSoftLimitMs = 20 * 1000
  const cpuTimeHardLimitMs = 60 * 1000
  const noModuleCache = false
  const importMapPath = null
  const envVarsObj = Deno.env.toObject()
  const envVars = Object.keys(envVarsObj).map((k) => [k, envVarsObj[k]])

  try {
    const worker = await EdgeRuntime.userWorkers.create({
      servicePath,
      memoryLimitMb,
      workerTimeoutMs,
      cpuTimeSoftLimitMs,
      cpuTimeHardLimitMs,
      noModuleCache,
      importMapPath,
      envVars,
    })
    return await worker.fetch(req)
  } catch (e) {
    const error = { msg: e.toString() }
    return new Response(JSON.stringify(error), {
      status: 500,
      headers: { 'Content-Type': 'application/json' },
    })
  }
})
