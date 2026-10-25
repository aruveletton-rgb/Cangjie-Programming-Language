// Week-9 acceptance checks: login throttle (ledger R-W9-5) over HTTP.
//
// What this covers, and what it deliberately does not:
//   covered  - per-username lockout engages after maxFailures consecutive failures and
//              rejects even the correct password with the same 401 as a wrong password;
//   covered  - the counters that prove the lock actually engaged are readable by staff
//              via /api/v1/auth/stats (lockEventsTotal / lockRejectsTotal);
//   covered  - a live session keeps working while its username is locked, because the
//              throttle gates login, not already-issued sessions;
//   covered  - a successful login resets the counter, and failures outside the window do
//              not accumulate (unit tests cover window expiry precisely; HTTP covers the
//              observable defaults);
//   covered  - absurd configuration (maxFailures=0) refuses to start instead of
//              disabling the throttle silently;
//   NOT covered - timing equalisation between "unknown user" and "wrong password"
//              (measuring it over HTTP would be flaky; the unit tests pin the behaviour),
//              and any real cloud host or public exposure.
//
// Usage:
//   ICT_BUILD_ROOT=D:\ict_build_w9 ICT_TEST_OUTPUT=.../result.json node src/backend/tests/week9.throttle.mjs
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
const workDir = process.env.ICT_TEST_WORKDIR || path.join(root, 'temp/backend/week9_throttle')
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
  ICT_AUTH_MODE: 'session',
  ICT_AUTH_USERS: credentialSpec(),
  ICT_LOGIN_MAX_FAILURES: '3',
  ICT_LOGIN_WINDOW_SECONDS: '300',
  ICT_LOGIN_LOCKOUT_SECONDS: '600',
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

async function call(server, method, endpoint, { body, session } = {}) {
  const headers = { 'Content-Type': 'application/json' }
  if (session) headers['X-Demo-Session'] = session
  const r = await fetch(server.url + endpoint, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  let json = null
  try { json = await r.json() } catch { /* empty body */ }
  return { status: r.status, code: json?.code ?? null, data: json?.data ?? null }
}

const login = (server, username, password) => call(server, 'POST', '/api/v1/auth/login', { body: { username, password } })

async function main() {
  const servers = []
  // Startup guard: a throttle that cannot engage must refuse to start, not run wide open.
  const bad = await runExpectingExit({ ICT_PORT: '38089', ICT_LOGIN_MAX_FAILURES: '0' })
  record('login_max_failures_zero_refuses_to_start', true, typeof bad.code === 'number' && bad.code !== 0, { exitCode: bad.code })

  const auth = await startServer('throttle', { ICT_PORT: '38089' })
  servers.push(auth)

  // A live token from BEFORE the lockout: used both as the staff reader for stats and
  // to prove that the throttle gates login only, not already-issued sessions.
  const first = await login(auth, 'worker1', 'worker-pass-1')
  record('first_login_with_correct_password_issues_token', { status: 200, code: 'OK' }, { status: first.status, code: first.code })
  const staffToken = first.data?.token

  for (let i = 1; i <= 3; i++) {
    const wrong = await login(auth, 'worker1', `wrong-${i}`)
    record(`wrong_password_${i}_of_3_is_401`, { status: 401, code: 'UNAUTHORIZED' }, { status: wrong.status, code: wrong.code })
  }
  const locked = await login(auth, 'worker1', 'worker-pass-1')
  record('correct_password_rejected_during_lockout', { status: 401, code: 'UNAUTHORIZED' }, { status: locked.status, code: locked.code })

  const stats = await call(auth, 'GET', '/api/v1/auth/stats', { session: staffToken })
  const guard = stats.data?.loginGuard ?? null
  record('stats_expose_lockout_counters_to_staff', { lockEventsTotal: 1, lockRejectsTotal: 1, lockedUsernames: 1, maxFailures: 3, windowSeconds: 300, lockoutSeconds: 600 }, guard === null ? null : {
    lockEventsTotal: guard.lockEventsTotal, lockRejectsTotal: guard.lockRejectsTotal,
    lockedUsernames: guard.lockedUsernames, maxFailures: guard.maxFailures,
    windowSeconds: guard.windowSeconds, lockoutSeconds: guard.lockoutSeconds,
  })

  const me = await call(auth, 'GET', '/api/v1/auth/me', { session: staffToken })
  record('existing_session_survives_its_username_lockout', { status: 200, code: 'OK' }, { status: me.status, code: me.code })

  const other = await login(auth, 'student1', 'student-pass-1')
  record('other_username_unaffected_by_lock', { status: 200, code: 'OK' }, { status: other.status, code: other.code })

  // Two failures, a success (reset), two more failures, a success: never three in a row.
  await login(auth, 'student1', 'nope-1')
  await login(auth, 'student1', 'nope-2')
  const reset1 = await login(auth, 'student1', 'student-pass-1')
  record('success_after_two_failures_still_logs_in', { status: 200, code: 'OK' }, { status: reset1.status, code: reset1.code })
  await login(auth, 'student1', 'nope-3')
  await login(auth, 'student1', 'nope-4')
  const reset2 = await login(auth, 'student1', 'student-pass-1')
  record('counter_reset_keeps_working_after_repeat', { status: 200, code: 'OK' }, { status: reset2.status, code: reset2.code })

  // Third consecutive failure crosses the threshold.
  await login(auth, 'student1', 'nope-5')
  await login(auth, 'student1', 'nope-6')
  await login(auth, 'student1', 'nope-7')
  const lockedAgain = await login(auth, 'student1', 'student-pass-1')
  record('third_consecutive_failure_locks_username', { status: 401, code: 'UNAUTHORIZED' }, { status: lockedAgain.status, code: lockedAgain.code })

  // Guessing a non-existent name is the same attack and locks the same way.
  for (let i = 1; i <= 3; i++) await login(auth, 'ghost', `guess-${i}`)
  const ghostLocked = await login(auth, 'ghost', 'guess-4')
  record('unknown_username_locks_after_threshold', { status: 401, code: 'UNAUTHORIZED' }, { status: ghostLocked.status, code: ghostLocked.code })

  const stats2 = await call(auth, 'GET', '/api/v1/auth/stats', { session: staffToken })
  // Rejects: worker1 (1 during lock) + student1 (1 during lock) + ghost's 4th guess (1).
  // Locked usernames: worker1, student1, ghost.
  record('final_counters_show_three_lockouts', { lockEventsTotal: 3, lockRejectsTotal: 3, lockedUsernames: 3 }, {
    lockEventsTotal: stats2.data?.loginGuard?.lockEventsTotal,
    lockRejectsTotal: stats2.data?.loginGuard?.lockRejectsTotal,
    lockedUsernames: stats2.data?.loginGuard?.lockedUsernames,
  })

  for (const s of servers) await s.stop()

  const failed = cases.filter((c) => !c.pass)
  const result = {
    generatedAt: new Date().toISOString(),
    scope: 'Week-9 login throttle over HTTP: per-username lockout, counters, live-session isolation, config guard.',
    notCovered: [
      'timing equalisation measurement over HTTP (unit tests pin the behaviour)',
      'any real cloud host / public exposure',
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
  console.log(`\nweek9.throttle: ${result.summary.passed}/${result.summary.total} passed -> ${outputPath}`)
  if (failed.length) process.exit(1)
}

main().catch((e) => {
  console.error(e)
  process.exit(2)
})
