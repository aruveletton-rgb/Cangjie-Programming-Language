// Bundle smoke test: does the assembled bundle run *by itself*?
//
// The bundle is meant to be self-contained (exe + stdx + data). The failure this catches
// is the quiet one: the exe starts, cannot resolve a stdx DLL from its own folder, and
// exits before printing anything useful. On the cloud host that looks like "the service
// will not start" with no clue why.
//
// It starts the bundled exe on a spare port, waits for /health, records the payload, and
// stops it. It does not touch TLS, does not need a certificate, and does not need the
// source tree.
//
// Usage:
//   node src/backend/deploy/smoke-bundle.mjs
//   node src/backend/deploy/smoke-bundle.mjs --bundle artifacts/backend/cloud-bundle --port 38084
//
// Exit codes: 0 = bundle serves /health, 1 = it did not.

import fs from 'node:fs'
import path from 'node:path'
import net from 'node:net'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')

const argv = process.argv.slice(2)
const argValue = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : undefined
}
const bundleDir = path.resolve(root, argValue('--bundle') || 'artifacts/backend/cloud-bundle')
const port = Number(argValue('--port') || process.env.ICT_SMOKE_PORT || 38084)
const timeoutMs = Number(argValue('--timeout-ms') || 20000)

const exe = path.join(bundleDir, 'main.exe')
const stdxDir = path.join(bundleDir, 'stdx')
const dataPath = path.join(bundleDir, 'data/synthetic.runtime.json')
const stateDir = path.join(bundleDir, 'state')

const result = {
  generatedAt: new Date().toISOString(),
  bundle: path.relative(root, bundleDir).replace(/\\/g, '/'),
  port,
  checks: [],
  health: null,
  stderrHead: null,
  selfContained: false,
  note: 'Loopback smoke test of the bundle only. It does not prove cloud reachability, TLS, or an external client.'
}
const check = (name, ok, detail) => {
  result.checks.push({ name, status: ok ? 'pass' : 'fail', detail })
  return ok
}

for (const [name, file] of [['main.exe', exe], ['stdx', stdxDir], ['data', dataPath]]) {
  if (!check('present:' + name, fs.existsSync(file), file)) {
    console.log(JSON.stringify(result, null, 2))
    process.exit(1)
  }
}

const waitPortFree = () =>
  new Promise((resolve) => {
    const probe = net.connect({ host: '127.0.0.1', port }, () => {
      probe.destroy()
      resolve(false)
    })
    probe.on('error', () => resolve(true))
    setTimeout(() => {
      probe.destroy()
      resolve(true)
    }, 800)
  })

if (!(await waitPortFree())) {
  check('port-free', false, `port ${port} already in use`)
  console.log(JSON.stringify(result, null, 2))
  process.exit(1)
}
check('port-free', true, String(port))

fs.mkdirSync(stateDir, { recursive: true })

// The exe resolves stdx next to itself; prepending the bundled folder proves the bundle
// carries everything it needs rather than borrowing the build machine's runtime.
const env = {
  ...process.env,
  PATH: stdxDir + path.delimiter + (process.env.PATH || ''),
  ICT_PORT: String(port),
  ICT_DATA: dataPath,
  ICT_STORE: path.join(stateDir, 'smoke-store.json')
}
delete env.ICT_PUBLIC_ORIGIN

const child = spawn(exe, [], { cwd: bundleDir, env, windowsHide: true })
let stderr = ''
child.stderr.on('data', (chunk) => {
  stderr += String(chunk)
  if (stderr.length > 4000) stderr = stderr.slice(-4000)
})

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
let health = null
const started = Date.now()
while (Date.now() - started < timeoutMs) {
  if (child.exitCode !== null) break
  try {
    const response = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(1500) })
    if (response.ok) {
      health = await response.json()
      break
    }
  } catch {
    /* not up yet */
  }
  await sleep(250)
}

const elapsed = Date.now() - started
if (child.exitCode === null) child.kill()
await sleep(300)

check('process-stayed-up', child.exitCode === null || health !== null, child.exitCode === null ? 'running when stopped' : `exited early with ${child.exitCode}`)
check('health-reachable', Boolean(health), health ? `${elapsed} ms` : `no /health within ${timeoutMs} ms`)
if (health) {
  check('health-code-ok', health.code === 'OK', String(health.code))
  const data = health.data || {}
  check('health-synthetic-flag', data.synthetic === true, `synthetic=${String(data.synthetic)}`)
  check('health-real-write-flag', data.realBusinessWrite === false, `realBusinessWrite=${String(data.realBusinessWrite)}`)
  result.health = health
}
result.stderrHead = stderr ? stderr.slice(0, 600) : null
result.selfContained = result.checks.every((c) => c.status === 'pass')
result.elapsedMs = elapsed

console.log(JSON.stringify(result, null, 2))
process.exit(result.selfContained ? 0 : 1)
