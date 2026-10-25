// Week-9 acceptance checks: controlled cloud-demo preconditions.
//
// What this covers, and what it deliberately does not:
//   covered  - the service refuses to expose itself with guessable staff sessions;
//   covered  - server-issued sessions (login / me / logout / stats) behave correctly;
//   covered  - the repair mainline (draft -> confirm -> submit -> receipt) still works
//              end to end under issued tokens;
//   covered  - a repeated submission produces exactly one business result;
//   NOT covered - any real cloud host, public IP, certificate or object storage. Those
//              require resources the account holder has not supplied, and this script
//              does not pretend otherwise.
//
// Usage:
//   ICT_BUILD_ROOT=D:\ict_build_w9 ICT_TEST_OUTPUT=.../result.json node src/backend/tests/week9.cloud-demo.mjs
// Exit code 0 only when every case passes.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')
const buildRoot = process.env.ICT_BUILD_ROOT || 'D:\\ict_build_w9'
const exe = path.join(buildRoot, 'main.exe')
const stdx = path.join(buildRoot, 'stdx')
const dataPath = path.join(root, 'src/data/synthetic.runtime.json')
const workDir = process.env.ICT_TEST_WORKDIR || path.join(root, 'temp/backend/week9_auth')
const outputPath = process.env.ICT_TEST_OUTPUT || path.join(workDir, 'result.json')

if (!fs.existsSync(exe)) throw new Error(`Backend binary not found: ${exe} (build first)`)
if (!fs.existsSync(dataPath)) throw new Error(`Dataset not found: ${dataPath}`)
fs.mkdirSync(workDir, { recursive: true })

const dataset = JSON.parse(fs.readFileSync(dataPath, 'utf8'))
const fixedNow = dataset.generatedAt

const cases = []
const record = (name, expected, actual, extra = {}) => {
  const pass = JSON.stringify(expected) === JSON.stringify(actual)
  cases.push({ name, pass, expected, actual, ...extra })
  console.log(`${pass ? 'PASS' : 'FAIL'} ${name}${pass ? '' : ` expected=${JSON.stringify(expected)} actual=${JSON.stringify(actual)}`}`)
  return pass
}

const sha256 = (text) => crypto.createHash('sha256').update(text, 'utf8').digest('hex')

function credentialSpec() {
  const make = (username, password, role, domain, userId, area) => {
    const salt = crypto.randomBytes(8).toString('hex')
    return { username, salt, passwordHash: sha256(salt + password), userId, domain, role, area }
  }
  return JSON.stringify({
    users: [
      make('worker1', 'worker-pass-1', 'staff', 'campus-demo', 'worker-syn-campus-001', 'SYN_CAMPUS_A'),
      make('student1', 'student-pass-1', 'student', 'campus-demo', 'user-syn-campus-001', 'SYN_CAMPUS_A'),
    ],
  })
}

const baseEnv = {
  ICT_DATA: dataPath,
  ICT_TEST_NOW: fixedNow,
  ICT_ENABLE_TEST_FAULTS: '1',
  PATH: `${stdx};${process.env.PATH}`,
}

async function waitHealthy(url, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`${url}/health`)
      if (r.status === 200) return true
    } catch { /* not up yet */ }
    await new Promise((r) => setTimeout(r, 120))
  }
  return false
}

// Runs the binary to completion for startup-guard cases (expected to exit non-zero).
function runExpectingExit(env, timeoutMs = 12000) {
  return new Promise((resolve) => {
    const child = spawn(exe, [], { env: { ...process.env, ...baseEnv, ...env }, cwd: workDir })
    let out = ''
    child.stdout.on('data', (d) => { out += d.toString() })
    child.stderr.on('data', (d) => { out += d.toString() })
    const timer = setTimeout(() => { child.kill(); resolve({ code: 'TIMEOUT', out }) }, timeoutMs)
    child.on('exit', (code) => { clearTimeout(timer); resolve({ code, out }) })
  })
}

async function startServer(name, env) {
  const port = env.ICT_PORT
  const child = spawn(exe, [], { env: { ...process.env, ...baseEnv, ...env }, cwd: workDir })
  let log = ''
  child.stdout.on('data', (d) => { log += d.toString() })
  child.stderr.on('data', (d) => { log += d.toString() })
  const url = `http://127.0.0.1:${port}`
  const healthy = await waitHealthy(url)
  if (!healthy) {
    child.kill()
    throw new Error(`Server ${name} did not become healthy. log=${log}`)
  }
  return { name, port, url, child, log: () => log, stop: () => new Promise((res) => { child.on('exit', res); child.kill() }) }
}

async function call(server, method, endpoint, { body, session, bearer, key } = {}) {
  const headers = { 'Content-Type': 'application/json' }
  if (session) headers['X-Demo-Session'] = session
  if (bearer) headers['Authorization'] = `Bearer ${bearer}`
  if (key) headers['Idempotency-Key'] = key
  const r = await fetch(server.url + endpoint, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  let json = null
  try { json = await r.json() } catch { /* empty body */ }
  return { status: r.status, code: json?.code ?? null, data: json?.data ?? null }
}

const rid = () => 'w9-' + crypto.randomBytes(6).toString('hex')

async function main() {
  const servers = []
  // A fresh store per run. Reusing one store made the "exactly one business result"
  // assertion depend on whether an earlier run had already committed a ticket, which is
  // a defect in the test, not in the service.
  const runId = new Date().toISOString().replace(/[-:.TZ]/g, '')
  const store = (name) => path.join(workDir, `${name}-${runId}.json`)

  // --- startup guards -------------------------------------------------------
  const guardPublicDemo = await runExpectingExit({
    ICT_PORT: '38090', ICT_STORE: store('guard1'),
    ICT_PUBLIC_ORIGIN: 'https://203.0.113.10:8443', ICT_AUTH_MODE: 'demo',
  })
  record('startup_refuses_public_origin_with_static_sessions', 1, guardPublicDemo.code,
    { note: 'A public origin plus demo sessions is the exact exposure the plan says to close.', output: guardPublicDemo.out.trim().slice(0, 200) })

  const guardNoCreds = await runExpectingExit({
    ICT_PORT: '38090', ICT_STORE: store('guard2'), ICT_AUTH_MODE: 'session',
  })
  record('startup_refuses_session_mode_without_credentials', 1, guardNoCreds.code,
    { note: 'Session mode with no user table would fail every login for no visible reason.', output: guardNoCreds.out.trim().slice(0, 200) })

  // --- demo mode keeps the local workflow intact ----------------------------
  const demo = await startServer('demo', { ICT_PORT: '38091', ICT_STORE: store('demo') })
  servers.push(demo)
  const demoHealth = await call(demo, 'GET', '/health')
  record('demo_mode_health_reports_its_own_auth_mode', 'static-demo-sessions-not-for-public-exposure',
    demoHealth.data?.authentication)
  const demoMe = await call(demo, 'GET', '/api/v1/auth/me', { session: 'campus-worker' })
  record('demo_mode_static_staff_session_still_works', 'staff', demoMe.data?.role)
  const demoNotices = await call(demo, 'GET', '/api/v1/notices', { session: 'campus-user' })
  record('demo_mode_static_student_session_still_works', 200, demoNotices.status)
  const demoLogin = await call(demo, 'POST', '/api/v1/auth/login', { body: { username: 'worker1', password: 'worker-pass-1' } })
  record('demo_mode_without_credentials_refuses_login', 'SERVICE_UNAVAILABLE', demoLogin.code)

  // --- session mode ---------------------------------------------------------
  const creds = credentialSpec()
  const auth = await startServer('session', {
    ICT_PORT: '38092', ICT_STORE: store('session'),
    ICT_AUTH_MODE: 'session', ICT_AUTH_USERS: creds, ICT_SESSION_TTL: '900',
  })
  servers.push(auth)

  const health = await call(auth, 'GET', '/health')
  record('session_mode_health_reports_issued_sessions', 'issued-server-side-sessions', health.data?.authentication)

  for (const staticName of ['campus-user', 'campus-worker', 'community-worker']) {
    const r = await call(auth, 'GET', '/api/v1/notices', { session: staticName })
    record(`session_mode_rejects_static_token_${staticName}`, { status: 401, code: 'UNAUTHORIZED' }, { status: r.status, code: r.code })
  }

  const wrong = await call(auth, 'POST', '/api/v1/auth/login', { body: { username: 'worker1', password: 'nope-nope' } })
  record('login_with_wrong_password_is_401', { status: 401, code: 'UNAUTHORIZED' }, { status: wrong.status, code: wrong.code })

  const unknown = await call(auth, 'POST', '/api/v1/auth/login', { body: { username: 'ghost', password: 'whatever1' } })
  record('login_with_unknown_user_is_indistinguishable', { status: 401, code: 'UNAUTHORIZED' }, { status: unknown.status, code: unknown.code })

  const staffLogin = await call(auth, 'POST', '/api/v1/auth/login', { body: { username: 'worker1', password: 'worker-pass-1' } })
  record('login_issues_a_token_without_echoing_secrets',
    { hasToken: true, role: 'staff', noPassword: true },
    {
      hasToken: typeof staffLogin.data?.token === 'string' && staffLogin.data.token.startsWith('sess-'),
      role: staffLogin.data?.role,
      noPassword: !('password' in (staffLogin.data ?? {})) && !('passwordHash' in (staffLogin.data ?? {})),
    })
  const staffToken = staffLogin.data?.token

  const me = await call(auth, 'GET', '/api/v1/auth/me', { session: staffToken })
  record('issued_token_resolves_to_the_bound_identity',
    { userId: 'worker-syn-campus-001', role: 'staff', domain: 'campus-demo' },
    { userId: me.data?.userId, role: me.data?.role, domain: me.data?.domain })

  const bearerMe = await call(auth, 'GET', '/api/v1/auth/me', { bearer: staffToken })
  record('authorization_bearer_header_is_accepted', 'staff', bearerMe.data?.role)

  const studentLogin = await call(auth, 'POST', '/api/v1/auth/login', { body: { username: 'student1', password: 'student-pass-1' } })
  const studentToken = studentLogin.data?.token
  record('student_login_gets_student_role', 'student', studentLogin.data?.role)

  const statsAsStaff = await call(auth, 'GET', '/api/v1/auth/stats', { session: staffToken })
  record('session_stats_are_staff_only_and_report_counters',
    { status: 200, issuedAtLeast2: true }, { status: statsAsStaff.status, issuedAtLeast2: (statsAsStaff.data?.issuedTotal ?? 0) >= 2 },
    { counters: statsAsStaff.data })
  const statsAsStudent = await call(auth, 'GET', '/api/v1/auth/stats', { session: studentToken })
  record('session_stats_reject_student', { status: 403, code: 'FORBIDDEN' }, { status: statsAsStudent.status, code: statsAsStudent.code })

  // --- repair mainline under issued tokens ----------------------------------
  const draftBody = {
    requestId: rid(), location: '公共区域', description: '合成报修：走廊灯不亮',
    contactAlias: 'SYN-CONTACT-K',
  }
  const draft = await call(auth, 'POST', '/api/v1/ticket-drafts', { body: draftBody, session: studentToken })
  record('draft_created_with_issued_token', 200, draft.status)

  const confirm = await call(auth, 'POST', `/api/v1/ticket-drafts/${draft.data?.draftId}/confirm`, {
    body: { requestId: rid(), revision: draft.data?.revision }, session: studentToken,
  })
  record('confirmation_created_with_issued_token', 200, confirm.status)

  const submission = {
    requestId: rid(), draftId: draft.data?.draftId, confirmationId: confirm.data?.confirmationId,
  }
  const submitKey = rid()
  const first = await call(auth, 'POST', '/api/v1/tickets', { body: submission, session: studentToken, key: submitKey })
  record('submission_committed_with_issued_token', 200, first.status)
  const ticketId = first.data?.ticketId

  const receipt = await call(auth, 'GET', `/api/v1/requests/${submission.requestId}/result`, { session: studentToken })
  record('receipt_queryable_with_issued_token', 'COMMITTED', receipt.data?.resultStatus)

  // Duplicate submissions, including concurrent ones, must not create a second ticket.
  const replays = await Promise.all(Array.from({ length: 8 }, () =>
    call(auth, 'POST', '/api/v1/tickets', { body: submission, session: studentToken, key: submitKey })))
  record('duplicate_submission_returns_the_same_ticket',
    { allSameTicket: true, allOk: true },
    {
      allSameTicket: replays.every((r) => r.data?.ticketId === ticketId),
      allOk: replays.every((r) => r.status === 200),
    })

  const list = await call(auth, 'GET', '/api/v1/tickets', { session: staffToken })
  record('duplicate_submission_produced_exactly_one_business_result', 1, list.data?.items?.length,
    { note: 'Acceptance wording: repeated submission yields one business result.' })

  const studentDraft = await call(auth, 'POST', '/api/v1/ticket-drafts', { body: { ...draftBody, requestId: rid() }, session: staffToken })
  record('staff_cannot_create_a_student_draft', { status: 403, code: 'FORBIDDEN' }, { status: studentDraft.status, code: studentDraft.code })

  // --- logout ---------------------------------------------------------------
  const logout = await call(auth, 'POST', '/api/v1/auth/logout', { session: studentToken })
  record('logout_is_acknowledged', { status: 200, revoked: true }, { status: logout.status, revoked: logout.data?.revoked })
  const afterLogout = await call(auth, 'GET', '/api/v1/auth/me', { session: studentToken })
  record('logged_out_token_is_rejected', { status: 401, code: 'UNAUTHORIZED' }, { status: afterLogout.status, code: afterLogout.code })

  for (const s of servers) await s.stop()

  const failed = cases.filter((c) => !c.pass)
  const result = {
    generatedAt: new Date().toISOString(),
    scope: 'Week-9 preconditions verifiable without a cloud host: identity, permission, repair mainline, idempotency.',
    notCovered: [
      'real cloud host / public IP / certificate',
      'object storage read-write',
      'device notification and card (emulator was offline at run time)',
      'any real model provider call',
    ],
    binary: { path: exe, bytes: fs.statSync(exe).size, sha256: crypto.createHash('sha256').update(fs.readFileSync(exe)).digest('hex') },
    dataset: { path: dataPath, version: dataset.version, generatedAt: dataset.generatedAt },
    fixedClock: fixedNow,
    cases,
    summary: { total: cases.length, passed: cases.length - failed.length, failed: failed.length },
    servers: servers.map((s) => ({ name: s.name, port: s.port })),
  }
  fs.mkdirSync(path.dirname(outputPath), { recursive: true })
  fs.writeFileSync(outputPath, JSON.stringify(result, null, 2) + '\n', 'utf8')
  console.log(`\nweek9.cloud-demo: ${result.summary.passed}/${result.summary.total} passed -> ${outputPath}`)
  if (failed.length) process.exit(1)
}

main().catch((e) => {
  console.error(e)
  process.exit(2)
})
