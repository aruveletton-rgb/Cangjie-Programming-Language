// Device acceptance readiness.
//
// Weeks 8 and 9 both lost time to the same sequence: assume the device is up, write the
// test, discover `hdc list targets` is `[Empty]`, and then have nothing to show for it.
// This script makes the absence explicit and machine-readable instead of a failed run.
//
// It answers two questions:
//   1. is a device target actually visible to hdc right now?
//   2. is the artifact we would install the one the build record produced?
//
// When no target is visible it exits 0 with status SKIPPED_DEVICE_ABSENT and lists the
// exact steps that are queued. That is a *skip*, not a pass: nothing on the device has
// been verified, and the ledger must keep W9-B1/B2 blocked.
//
// Usage:
//   node src/backend/tests/device.acceptance.mjs
//   ICT_HDC="D:\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe" node ...
//
// Exit codes: 0 = ran and reported (device present or absent), 1 = harness itself broken.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')

const hdc = process.env.ICT_HDC || 'D:\\DevEco Studio\\sdk\\default\\openharmony\\toolchains\\hdc.exe'
const report = {
  generatedAt: new Date().toISOString(),
  hdc,
  hdcPresent: false,
  hdcVersion: null,
  targets: [],
  devicePresent: false,
  artifact: null,
  status: 'not_run',
  queuedSteps: [
    'aa force-stop com.example.myapplication   (it steals the foreground and makes uitest click the wrong window)',
    'hdc install -r <hap>                       (unsigned HAP installs; use a relative path, hdc prepends cwd)',
    'aa start -a EntryAbility -b <bundle>',
    'uitest dumpLayout                         (read real bounds; do not scale screenshot pixels)',
    'uitest uiInput click <x> <y>              (only after confirming the target app is in the foreground)',
    'collect /proc/net/tcp from the device sandbox uid as connection evidence, plus screenshots'
  ],
  boundary: 'A skip is not a pass. Nothing on a device was verified by this run.',
  checks: []
}
const check = (name, ok, detail) => {
  report.checks.push({ name, status: ok ? 'pass' : 'fail', detail })
  return ok
}

if (!check('hdc-present', fs.existsSync(hdc), hdc)) {
  console.log(JSON.stringify(report, null, 2))
  process.exit(1)
}
report.hdcPresent = true

try {
  report.hdcVersion = execFileSync(hdc, ['-v'], { encoding: 'utf8', timeout: 10000, env: { ...process.env, MSYS_NO_PATHCONV: '1' } }).trim()
  check('hdc-version', true, report.hdcVersion)
} catch (error) {
  check('hdc-version', false, String(error.message).slice(0, 120))
}

let rawTargets = ''
try {
  rawTargets = execFileSync(hdc, ['list', 'targets'], {
    encoding: 'utf8',
    timeout: 15000,
    env: { ...process.env, MSYS_NO_PATHCONV: '1' }
  })
  const lines = rawTargets
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l && !/^\[Empty\]$/i.test(l))
  report.targets = lines
  report.devicePresent = lines.length > 0
  check('hdc-targets', true, lines.length ? lines.join(', ') : '[Empty]')
} catch (error) {
  check('hdc-targets', false, String(error.message).slice(0, 120))
}

// The artifact check runs whether or not a device is present: when the device comes back,
// the next question is immediately "which HAP am I installing?".
const hapRoot = path.join(root, 'artifacts/client/hap')
let latest = null
if (fs.existsSync(hapRoot)) {
  const stamps = fs
    .readdirSync(hapRoot)
    .filter((name) => fs.statSync(path.join(hapRoot, name)).isDirectory())
    // Newest by directory mtime, not by name: stamps are not all the same shape
    // ("20261024T001641019" vs "week7_reaudit_20261023113230"), and name order puts
    // week-prefixed batches last.
    .sort((a, b) => fs.statSync(path.join(hapRoot, b)).mtimeMs - fs.statSync(path.join(hapRoot, a)).mtimeMs)
  for (const stamp of stamps) {
    const dir = path.join(hapRoot, stamp)
    const hap = fs.readdirSync(dir).find((f) => f.endsWith('.hap'))
    if (hap) {
      latest = { stamp, dir, hap: path.join(dir, hap) }
      break
    }
  }
}
if (latest) {
  const bytes = fs.statSync(latest.hap).size
  const sha = crypto.createHash('sha256').update(fs.readFileSync(latest.hap)).digest('hex')
  const manifestPath = path.join(latest.dir, 'manifest.json')
  let manifestStatus = null
  if (fs.existsSync(manifestPath)) {
    try {
      manifestStatus = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).status ?? null
    } catch {
      manifestStatus = 'unreadable'
    }
  }
  report.artifact = {
    stamp: latest.stamp,
    hap: path.relative(root, latest.hap).replace(/\\/g, '/'),
    bytes,
    sha256: sha,
    buildManifestStatus: manifestStatus
  }
  check('artifact-present', true, `${latest.stamp} / ${bytes} B / ${sha.slice(0, 12)}`)
} else {
  check('artifact-present', false, 'no .hap under artifacts/client/hap')
}

report.status = report.devicePresent ? 'DEVICE_PRESENT_UNVERIFIED' : 'SKIPPED_DEVICE_ABSENT'
report.queuedWhenPresent = report.devicePresent ? [] : report.queuedSteps

console.log(JSON.stringify(report, null, 2))
// A missing device is reported, not raised: the harness works, the precondition is absent.
process.exit(report.checks.every((c) => c.status === 'pass' || c.name === 'artifact-present') ? 0 : 1)
