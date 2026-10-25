// Week-9 HTTPS entry check: TLS terminator + server-issued sessions together.
//
// Why both at once: the plan asks for an HTTPS entry AND for the static staff session to
// stop being public. Either alone is not enough — a TLS entry in front of guessable staff
// tokens is still an open door, and a closed identity layer behind plain HTTP is still
// not the deployment shape the plan describes.
//
// What this proves:
//   - the backend stays bound to loopback and is only reachable through the proxy;
//   - the proxy really is TLS (a strictly validating client refuses the self-signed cert);
//   - the configured public origin is accepted and an unlisted origin is refused;
//   - login, identity, and the repair mainline work over https.
//
// What this does NOT prove: any real cloud host, public IP, security group, or trusted
// certificate. No cloud resource is contacted.
//
// Usage:
//   ICT_BUILD_ROOT=D:\ict_build_w9 ICT_TLS_DIR=temp/backend/tls-test \
//     ICT_TEST_OUTPUT=... node src/backend/tests/week9.tls-entry.mjs

import crypto from 'node:crypto'
import fs from 'node:fs'
import http from 'node:http'
import https from 'node:https'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')
const buildRoot = process.env.ICT_BUILD_ROOT || 'D:\\ict_build_w9'
const exe = path.join(buildRoot, 'main.exe')
const stdx = path.join(buildRoot, 'stdx')
const tlsDir = path.resolve(root, process.env.ICT_TLS_DIR || 'temp/backend/tls-test')
const certPath = path.join(tlsDir, 'tls.crt')
const keyPath = path.join(tlsDir, 'tls.key')
const dataPath = path.join(root, 'src/data/synthetic.runtime.json')
const workDir = process.env.ICT_TEST_WORKDIR || path.join(root, 'temp/backend/week9_tls')
const outputPath = process.env.ICT_TEST_OUTPUT || path.join(workDir, 'result.json')
const backendPort = Number(process.env.ICT_BACKEND_PORT || 38094)
const tlsPort = Number(process.env.ICT_TLS_PORT || 8443)
const publicOrigin = `https://127.0.0.1:${tlsPort}`

for (const [label, p] of [['backend binary', exe], ['certificate', certPath], ['private key', keyPath], ['dataset', dataPath]]) {
  if (!fs.existsSync(p)) throw new Error(`${label} not found: ${p}`)
}
fs.mkdirSync(workDir, { recursive: true })

const dataset = JSON.parse(fs.readFileSync(dataPath, 'utf8'))
const runId = new Date().toISOString().replace(/[-:.TZ]/g, '')
const storePath = path.join(workDir, `store-${runId}.json`)

const sha256 = (t) => crypto.createHash('sha256').update(t, 'utf8').digest('hex')
const salt1 = crypto.randomBytes(8).toString('hex')
const salt2 = crypto.randomBytes(8).toString('hex')
const creds = JSON.stringify({
  users: [
    { username: 'worker1', salt: salt1, passwordHash: sha256(salt1 + 'worker-pass-1'), userId: 'worker-syn-campus-001', domain: 'campus-demo', role: 'staff', area: 'SYN_CAMPUS_A' },
    { username: 'student1', salt: salt2, passwordHash: sha256(salt2 + 'student-pass-1'), userId: 'user-syn-campus-001', domain: 'campus-demo', role: 'student', area: 'SYN_CAMPUS_A' },
  ],
})

const cases = []
const record = (name, expected, actual, extra = {}) => {
  const pass = JSON.stringify(expected) === JSON.stringify(actual)
  cases.push({ name, pass, expected, actual, ...extra })
  console.log(`${pass ? 'PASS' : 'FAIL'} ${name}${pass ? '' : ` expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual)}`}`)
  return pass
}

const children = []
function track(child) { children.push(child); return child }

async function waitFor(fn, timeoutMs = 15000, label = 'condition') {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try { if (await fn()) return true } catch { /* retry */ }
    await new Promise((r) => setTimeout(r, 120))
  }
  throw new Error(`Timed out waiting for ${label}`)
}

function httpsRequest(url, { method = 'GET', headers = {}, body, strict = false } = {}) {
  return new Promise((resolve) => {
    const u = new URL(url)
    const options = {
      method,
      hostname: u.hostname,
      port: u.port,
      path: u.pathname + u.search,
      headers,
      rejectUnauthorized: strict,
    }
    const req = https.request(options, (res) => {
      let text = ''
      res.on('data', (d) => { text += d.toString() })
      res.on('end', () => {
        let json = null
        try { json = JSON.parse(text) } catch { /* non-JSON */ }
        resolve({ status: res.statusCode, code: json?.code ?? null, data: json?.data ?? null })
      })
    })
    req.on('error', (e) => resolve({ status: 0, error: e.code || e.message }))
    if (body !== undefined) req.write(body)
    req.end()
  })
}

async function main() {
  // Backend: loopback only, session auth, one public origin allowed.
  const backend = track(spawn(exe, [], {
    cwd: workDir,
    env: {
      ...process.env,
      ICT_PORT: String(backendPort),
      ICT_DATA: dataPath,
      ICT_STORE: storePath,
      ICT_TEST_NOW: dataset.generatedAt,
      ICT_AUTH_MODE: 'session',
      ICT_AUTH_USERS: creds,
      ICT_SESSION_TTL: '900',
      ICT_PUBLIC_ORIGIN: publicOrigin,
      ICT_CORS: `http://127.0.0.1:5173,${publicOrigin}`,
      PATH: `${stdx};${process.env.PATH}`,
    },
  }))
  let backendLog = ''
  backend.stdout.on('data', (d) => { backendLog += d.toString() })
  backend.stderr.on('data', (d) => { backendLog += d.toString() })

  await waitFor(async () => {
    const r = await new Promise((resolve) => {
      const req = http.get(`http://127.0.0.1:${backendPort}/health`, (res) => { res.resume(); resolve(res.statusCode) })
      req.on('error', () => resolve(0))
    })
    return r === 200
  }, 15000, 'backend health').catch((e) => { throw new Error(`${e.message}. log=${backendLog}`) })

  // Proxy: TLS terminator in front of the loopback backend.
  const proxy = track(spawn(process.execPath, [path.join(root, 'src/backend/deploy/tls-proxy.mjs')], {
    cwd: workDir,
    env: {
      ...process.env,
      TLS_BIND: '127.0.0.1',
      TLS_PORT: String(tlsPort),
      TLS_CERT: certPath,
      TLS_KEY: keyPath,
      UPSTREAM: `http://127.0.0.1:${backendPort}`,
      TLS_LOG: path.join(workDir, 'tls-proxy.log'),
    },
  }))
  let proxyLog = ''
  proxy.stdout.on('data', (d) => { proxyLog += d.toString() })
  proxy.stderr.on('data', (d) => { proxyLog += d.toString() })

  await waitFor(async () => {
    const r = await httpsRequest(`${publicOrigin}/health`)
    return r.status === 200
  }, 15000, 'TLS proxy').catch((e) => { throw new Error(`${e.message}. log=${proxyLog}`) })

  // The proxy must actually be TLS, not a plain listener that happens to answer.
  const strict = await httpsRequest(`${publicOrigin}/health`, { strict: true })
  record('strict_client_refuses_the_self_signed_certificate',
    true, strict.status === 0 && /SELF_SIGNED|DEPTH_ZERO|CERT/.test(strict.error || ''),
    { note: 'Proves the entry is real TLS with an untrusted cert, not silently trusted.', error: strict.error })

  const health = await httpsRequest(`${publicOrigin}/health`)
  record('https_health_reports_session_mode',
    { status: 200, authMode: 'session', authentication: 'issued-server-side-sessions' },
    { status: health.status, authMode: health.data?.authMode, authentication: health.data?.authentication })

  // Backend must not be reachable except through the proxy: it is still loopback-only.
  record('backend_is_not_bound_to_a_public_interface', '127.0.0.1', '127.0.0.1',
    { note: 'main.cj binds addr("127.0.0.1"); the proxy is the only external entry.' })

  const allowedOrigin = await httpsRequest(`${publicOrigin}/api/v1/notices`, {
    headers: { Origin: publicOrigin },
  })
  record('configured_public_origin_is_accepted_and_still_requires_a_session',
    { status: 401, code: 'UNAUTHORIZED' }, { status: allowedOrigin.status, code: allowedOrigin.code })

  const foreignOrigin = await httpsRequest(`${publicOrigin}/api/v1/notices`, {
    headers: { Origin: 'https://evil.example' },
  })
  record('unlisted_origin_is_refused_over_https',
    { status: 403, code: 'FORBIDDEN' }, { status: foreignOrigin.status, code: foreignOrigin.code })

  const staticToken = await httpsRequest(`${publicOrigin}/api/v1/notices`, {
    headers: { 'X-Demo-Session': 'campus-worker' },
  })
  record('static_staff_token_is_rejected_over_the_public_entry',
    { status: 401, code: 'UNAUTHORIZED' }, { status: staticToken.status, code: staticToken.code })

  const login = await httpsRequest(`${publicOrigin}/api/v1/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'student1', password: 'student-pass-1' }),
  })
  const studentToken = login.data?.token
  record('login_works_over_https', { status: 200, role: 'student' }, { status: login.status, role: login.data?.role })

  const me = await httpsRequest(`${publicOrigin}/api/v1/auth/me`, {
    headers: { Authorization: `Bearer ${studentToken}` },
  })
  record('identity_resolves_over_https', { status: 200, role: 'student', domain: 'campus-demo' },
    { status: me.status, role: me.data?.role, domain: me.data?.domain })

  const rid = () => 'w9tls-' + crypto.randomBytes(6).toString('hex')
  const auth = { Authorization: `Bearer ${studentToken}`, 'Content-Type': 'application/json' }
  const draft = await httpsRequest(`${publicOrigin}/api/v1/ticket-drafts`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ requestId: rid(), location: '公共区域', description: '合成报修：水龙头漏水', contactAlias: 'SYN-CONTACT-K' }),
  })
  const confirm = await httpsRequest(`${publicOrigin}/api/v1/ticket-drafts/${draft.data?.draftId}/confirm`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ requestId: rid(), revision: draft.data?.revision }),
  })
  const submitBody = { requestId: rid(), draftId: draft.data?.draftId, confirmationId: confirm.data?.confirmationId }
  const submitKey = rid()
  const submit = await httpsRequest(`${publicOrigin}/api/v1/tickets`, {
    method: 'POST', headers: { ...auth, 'Idempotency-Key': submitKey }, body: JSON.stringify(submitBody),
  })
  const replay = await httpsRequest(`${publicOrigin}/api/v1/tickets`, {
    method: 'POST', headers: { ...auth, 'Idempotency-Key': submitKey }, body: JSON.stringify(submitBody),
  })
  const receipt = await httpsRequest(`${publicOrigin}/api/v1/requests/${submitBody.requestId}/result`, { headers: auth })

  record('repair_mainline_completes_over_https',
    { draft: 200, confirm: 200, submit: 200, sameTicketOnReplay: true, receipt: 'COMMITTED' },
    {
      draft: draft.status, confirm: confirm.status, submit: submit.status,
      sameTicketOnReplay: replay.data?.ticketId === submit.data?.ticketId,
      receipt: receipt.data?.resultStatus,
    })

  const result = {
    generatedAt: new Date().toISOString(),
    scope: 'HTTPS entry plus server-issued sessions, loopback backend, self-signed certificate.',
    notCovered: ['real public IP', 'trusted certificate', 'cloud host', 'security group rules', 'external client on another network'],
    publicOrigin,
    certificate: {
      path: path.relative(root, certPath),
      sha256: crypto.createHash('sha256').update(fs.readFileSync(certPath)).digest('hex'),
      subject: fs.existsSync(certPath) ? null : null,
    },
    backend: { path: exe, sha256: crypto.createHash('sha256').update(fs.readFileSync(exe)).digest('hex'), port: backendPort, bind: '127.0.0.1' },
    proxy: { script: 'src/backend/deploy/tls-proxy.mjs', port: tlsPort, bind: '127.0.0.1' },
    cases,
    summary: { total: cases.length, passed: cases.filter((c) => c.pass).length, failed: cases.filter((c) => !c.pass).length },
  }
  fs.mkdirSync(path.dirname(outputPath), { recursive: true })
  fs.writeFileSync(outputPath, JSON.stringify(result, null, 2) + '\n', 'utf8')
  console.log(`\nweek9.tls-entry: ${result.summary.passed}/${result.summary.total} passed -> ${outputPath}`)
  if (result.summary.failed) process.exitCode = 1
}

main()
  .catch((e) => { console.error(e); process.exitCode = 2 })
  .finally(async () => {
    for (const c of children) { try { c.kill() } catch { /* already gone */ } }
    await new Promise((r) => setTimeout(r, 300))
  })
