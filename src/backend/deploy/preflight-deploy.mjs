// Cloud bundle preflight.
//
// The bundle is what actually gets uploaded to the cloud host. Two failure modes have
// already happened once each in this project, and both are silent without this check:
//   1. the bundle was assembled from an older binary than the one the ledgers certify
//      (rebuild after a code change, forget to repackage -> you deploy yesterday's exe);
//   2. a file listed in bundle-manifest.json was edited or removed after packaging, so
//      the manifest no longer describes what is on disk.
//
// This script answers one question only: "is this bundle safe to upload right now?"
// It makes no network request and starts nothing.
//
// Usage:
//   node src/backend/deploy/preflight-deploy.mjs
//   node src/backend/deploy/preflight-deploy.mjs --bundle artifacts/backend/cloud-bundle
//   node src/backend/deploy/preflight-deploy.mjs --json > report.json
//
// Exit codes: 0 = ready, 1 = not ready, 2 = bundle missing/unreadable.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')

const argv = process.argv.slice(2)
const argValue = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : undefined
}
const bundleDir = path.resolve(root, argValue('--bundle') || 'artifacts/backend/cloud-bundle')
const asJson = argv.includes('--json')

const checks = []
const add = (name, status, detail) => checks.push({ name, status, detail })

const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const rel = (file) => path.relative(root, file).replace(/\\/g, '/')

if (!fs.existsSync(bundleDir)) {
  console.error('bundle directory not found: ' + bundleDir)
  process.exit(2)
}
const manifestPath = path.join(bundleDir, 'bundle-manifest.json')
if (!fs.existsSync(manifestPath)) {
  console.error('bundle-manifest.json not found in ' + bundleDir)
  process.exit(2)
}

let manifest
try {
  manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
} catch (error) {
  console.error('bundle-manifest.json is not valid JSON: ' + error.message)
  process.exit(2)
}

// 1. manifest schema
if (manifest.schema === 'ict-cloud-bundle-v1') add('manifest-schema', 'pass', manifest.schema)
else add('manifest-schema', 'fail', `unexpected schema: ${String(manifest.schema)}`)

// 2. every listed file exists with the recorded size and hash
const listed = Array.isArray(manifest.files) ? manifest.files : []
if (listed.length === 0) add('manifest-file-list', 'fail', 'files[] is empty')
else add('manifest-file-list', 'pass', `${listed.length} files listed`)

let missing = 0
let mismatched = 0
const listedPaths = new Set()
for (const entry of listed) {
  const full = path.join(bundleDir, entry.path)
  listedPaths.add(entry.path.replace(/\\/g, '/'))
  if (!fs.existsSync(full)) {
    missing++
    add('file-present:' + entry.path, 'fail', 'listed in manifest but absent on disk')
    continue
  }
  const size = fs.statSync(full).size
  if (size !== entry.bytes) {
    mismatched++
    add('file-size:' + entry.path, 'fail', `manifest ${entry.bytes} B, disk ${size} B`)
    continue
  }
  const actual = sha256(full)
  if (actual !== String(entry.sha256).toLowerCase()) {
    mismatched++
    add('file-hash:' + entry.path, 'fail', `manifest ${String(entry.sha256).slice(0, 12)}, disk ${actual.slice(0, 12)}`)
  }
}
add('manifest-files-intact', missing || mismatched ? 'fail' : 'pass', `${listed.length} checked, ${missing} missing, ${mismatched} altered`)

// 3. files on disk that the manifest does not describe (uploading those is unreviewed)
const walk = (dir, base = dir) => {
  const out = []
  for (const name of fs.readdirSync(dir)) {
    const full = path.join(dir, name)
    const stat = fs.statSync(full)
    if (stat.isDirectory()) out.push(...walk(full, base))
    else out.push(path.relative(base, full).replace(/\\/g, '/'))
  }
  return out
}
const onDisk = walk(bundleDir).filter((p) => p !== 'bundle-manifest.json')
const unlisted = onDisk.filter((p) => !listedPaths.has(p))
add('no-unlisted-files', unlisted.length ? 'warn' : 'pass', unlisted.length ? `${unlisted.length} unlisted: ${unlisted.slice(0, 5).join(', ')}` : 'none')

// 4. entry points named by the manifest must exist
const entries = manifest.entry || {}
for (const [role, relPath] of Object.entries(entries)) {
  const full = path.join(bundleDir, relPath)
  add('entry:' + role, fs.existsSync(full) ? 'pass' : 'fail', relPath)
}
for (const required of ['data/synthetic.runtime.json', 'deploy/provider.env.example']) {
  add('required:' + required, fs.existsSync(path.join(bundleDir, required)) ? 'pass' : 'fail', required)
}
const stdxDir = path.join(bundleDir, 'stdx')
const stdxCount = fs.existsSync(stdxDir) ? fs.readdirSync(stdxDir).filter((f) => f.endsWith('.dll') || f.endsWith('.a')).length : 0
add('required:stdx', stdxCount > 0 ? 'pass' : 'fail', `${stdxCount} runtime libraries`)

// 5. the binary in the bundle must be the binary the build record certifies.
// This is the check that catches "rebuilt the code, forgot to repackage".
const latestPath = path.join(root, 'temp/backend/latest-build.json')
let latest = null
try {
  latest = JSON.parse(fs.readFileSync(latestPath, 'utf8'))
} catch {
  add('binary-freshness', 'warn', 'temp/backend/latest-build.json unreadable; cannot compare against the build record')
}
if (latest) {
  const bundledExe = path.join(bundleDir, 'main.exe')
  if (!fs.existsSync(bundledExe)) {
    add('binary-freshness', 'fail', 'main.exe missing from bundle')
  } else {
    const bundled = sha256(bundledExe)
    const certified = String(latest.mainExe?.sha256 || '')
    if (!certified) add('binary-freshness', 'fail', 'build record has no mainExe.sha256')
    else if (bundled !== certified) {
      add('binary-freshness', 'fail', `bundle main.exe ${bundled.slice(0, 12)} != certified ${certified.slice(0, 12)} (rebuild the bundle)`)
    } else {
      add('binary-freshness', 'pass', `matches build record ${certified.slice(0, 12)}`)
    }
    const bundledBytes = fs.statSync(bundledExe).size
    if (latest.mainExe?.bytes && bundledBytes !== latest.mainExe.bytes) {
      add('binary-size', 'fail', `bundle ${bundledBytes} B, record ${latest.mainExe.bytes} B`)
    }
  }
}

// 6. the provider template must still carry every variable the adapter reads
const templatePath = path.join(bundleDir, 'deploy/provider.env.example')
if (fs.existsSync(templatePath)) {
  const text = fs.readFileSync(templatePath, 'utf8')
  const expected = [
    'ICT_PROVIDER_ENDPOINT',
    'ICT_PROVIDER_API_KEY',
    'ICT_PROVIDER_MODEL',
    'ICT_PROVIDER_NAME',
    'ICT_PROVIDER_TIMEOUT_MS',
    'ICT_PROVIDER_REAL'
  ]
  const absent = expected.filter((key) => !new RegExp('^\\s*#?\\s*' + key + '\\s*=', 'm').test(text))
  add('provider-template', absent.length ? 'fail' : 'pass', absent.length ? `missing keys: ${absent.join(', ')}` : `${expected.length} keys present`)
}

// 7. TLS material, if already generated, must not be expired
const tlsDir = path.join(bundleDir, 'tls')
const certCandidates = fs.existsSync(tlsDir)
  ? fs.readdirSync(tlsDir).filter((f) => f.endsWith('.crt') || f.endsWith('.pem'))
  : []
if (certCandidates.length === 0) {
  add('tls-certificate', 'warn', 'no certificate in bundle/tls; generate it on the host with deploy/gen-cert.sh')
} else {
  for (const name of certCandidates) {
    const full = path.join(tlsDir, name)
    try {
      const out = execFileSync('openssl', ['x509', '-enddate', '-noout', '-in', full], { encoding: 'utf8', timeout: 5000 })
      const end = new Date(String(out).replace('notAfter=', '').trim())
      const days = Math.floor((end.getTime() - Date.now()) / 86400000)
      add('tls-certificate:' + name, days > 0 ? 'pass' : 'fail', days > 0 ? `expires in ${days} days (${end.toISOString().slice(0, 10)})` : `expired ${end.toISOString().slice(0, 10)}`)
    } catch (error) {
      add('tls-certificate:' + name, 'warn', 'openssl unavailable or unreadable: ' + String(error.message).slice(0, 80))
    }
  }
}

// 8. build record provenance, so a bundle can always be traced to one build batch
if (latest) {
  add('build-record', 'pass', `builder=${latest.builder} completedAt=${latest.completedAt} audit=${latest.audit || 'n/a'}`)
}

const failures = checks.filter((c) => c.status === 'fail')
const warnings = checks.filter((c) => c.status === 'warn')
const report = {
  generatedAt: new Date().toISOString(),
  bundle: rel(bundleDir),
  manifestBuiltAt: manifest.builtAt || null,
  checks,
  counts: { total: checks.length, pass: checks.filter((c) => c.status === 'pass').length, fail: failures.length, warn: warnings.length },
  ready: failures.length === 0,
  note: 'Preflight only. It does not prove the bundle runs on a cloud host, that the security group allows 8443, or that a public IP exists.'
}

if (asJson) {
  console.log(JSON.stringify(report, null, 2))
} else {
  console.log('bundle: ' + report.bundle)
  console.log('manifest built: ' + report.manifestBuiltAt)
  for (const c of checks) {
    if (c.status === 'pass') continue
    console.log(`  [${c.status.toUpperCase()}] ${c.name}: ${c.detail}`)
  }
  console.log(`ready: ${report.ready} (pass ${report.counts.pass}, fail ${report.counts.fail}, warn ${report.counts.warn})`)
}

process.exit(report.ready ? 0 : 1)
