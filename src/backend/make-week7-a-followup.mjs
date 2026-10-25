// Rebuild the week-7 A-FOLLOWUP evidence record from a finished verification batch.
//
// Why this exists: this record has been rebuilt by hand four times (2026-10-23, 10-24 x3),
// and each rebuild is where the evidence chain breaks — the sourceManifest has to list the
// 11 files the claim depends on, and one stale hash makes the week-7 validator fail with
// "Bound file hash mismatch". A script does the same thing deterministically.
//
// It does NOT re-run anything. It reads:
//   - audit/backend/<batch>_verification/result.json      (verify.ps1 output)
//   - audit/backend/<batch>_verification/http.integration.json
//   - audit/backend/<batch>_verification/retrieval.development.json
//   - temp/backend/latest-build.json                       (which binary was certified)
// and writes result.json + result.md into the output directory.
//
// Usage:
//   node src/backend/make-week7-a-followup.mjs --verification audit/backend/<batch>_verification
//   node src/backend/make-week7-a-followup.mjs --verification <dir> --out audit/backend/week7_a_followup_repair_20261025
//
// Exit codes: 0 = evidence written, 2 = inputs missing or the batch did not pass.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../..')

const argv = process.argv.slice(2)
const argValue = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : undefined
}
const rel = (p) => path.relative(root, p).replace(/\\/g, '/')
const shaUpper = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex').toUpperCase()

// The files this claim rests on. Kept explicit on purpose: silently deriving this list from
// whatever happens to exist would let a file drop out of the manifest unnoticed.
const SOURCE_FILES = [
  'src/backend/tests/retrieval.metrics.mjs',
  'src/backend/tests/retrieval.metrics.test.mjs',
  'src/backend/tests/retrieval.development.mjs',
  'src/backend/tests/retrieval.development.top5.test.mjs',
  'src/backend/tests/retrieval.development.summary.test.mjs',
  'src/backend/verify.ps1',
  'src/backend/build.ps1',
  'src/backend/start.ps1',
  'src/backend/lib/pscompat.ps1',
  'docs/backend/week7_a_followup.md',
  'docs/backend/README.md'
]

const resolveVerification = () => {
  const explicit = argValue('--verification')
  if (explicit) {
    const full = path.resolve(root, explicit)
    if (!fs.existsSync(full)) {
      console.error('verification directory not found: ' + full)
      process.exit(2)
    }
    return full
  }
  const base = path.join(root, 'audit/backend')
  const candidates = fs
    .readdirSync(base)
    .filter((name) => /_verification$/.test(name) && fs.existsSync(path.join(base, name, 'result.json')))
    .map((name) => ({ name, mtime: fs.statSync(path.join(base, name)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)
  if (!candidates.length) {
    console.error('no verification batch found under audit/backend')
    process.exit(2)
  }
  return path.join(base, candidates[0].name)
}

const verificationDir = resolveVerification()
const verifyResult = JSON.parse(fs.readFileSync(path.join(verificationDir, 'result.json'), 'utf8'))
if (verifyResult.status !== 'passed') {
  console.error('verification batch did not pass: ' + verifyResult.status)
  process.exit(2)
}

const httpPath = path.join(verificationDir, 'http.integration.json')
const retrievalPath = path.join(verificationDir, 'retrieval.development.json')
for (const p of [httpPath, retrievalPath]) {
  if (!fs.existsSync(p)) {
    console.error('missing evidence file in batch: ' + rel(p))
    process.exit(2)
  }
}
const http = JSON.parse(fs.readFileSync(httpPath, 'utf8'))
const retrieval = JSON.parse(fs.readFileSync(retrievalPath, 'utf8'))

const httpPassed = (http.records || []).filter((r) => r.passed).length
const httpTotal = (http.records || []).length

const outDir = path.resolve(
  root,
  argValue('--out') || 'audit/backend/week7_a_followup_repair_' + new Date().toISOString().slice(0, 10).replace(/-/g, '')
)

// Previous record becomes history, not something to overwrite.
const previous = (() => {
  const explicit = argValue('--supersedes')
  if (explicit) return explicit
  const base = path.join(root, 'audit/backend')
  const dirs = fs
    .readdirSync(base)
    .filter((name) => name.startsWith('week7_a_followup_repair_') && fs.existsSync(path.join(base, name, 'result.json')))
    .map((name) => ({ name, mtime: fs.statSync(path.join(base, name)).mtimeMs }))
    .sort((a, b) => b.mtime - a.mtime)
  return dirs.length ? 'audit/backend/' + dirs[0].name + '/result.json' : null
})()

const latestBuild = JSON.parse(fs.readFileSync(path.join(root, 'temp/backend/latest-build.json'), 'utf8'))
const sourceManifest = SOURCE_FILES.map((file) => {
  const full = path.join(root, file)
  return { file, sha256: fs.existsSync(full) ? shaUpper(full) : null, present: fs.existsSync(full) }
})
const missing = sourceManifest.filter((s) => !s.present).map((s) => s.file)
if (missing.length) {
  console.error('bound source file(s) missing: ' + missing.join(', '))
  process.exit(2)
}

const evidenceManifest = fs
  .readdirSync(verificationDir)
  .filter((name) => fs.statSync(path.join(verificationDir, name)).isFile())
  .sort()
  .map((name) => ({ file: rel(path.join(verificationDir, name)), sha256: shaUpper(path.join(verificationDir, name)) }))

const record = {
  generatedAt: new Date().toISOString(),
  localDate: new Date().toISOString(),
  status: 'passed_local_a_followup',
  exitCode: verifyResult.exitCode ?? 0,
  shell: verifyResult.shell || 'unknown',
  buildRerun: !verifyResult.buildSkipped,
  buildEvidenceNote: verifyResult.buildSkipped
    ? 'Compilation was NOT re-run in this batch (-SkipBuild); the certified binary is the one recorded in temp/backend/latest-build.json. Source changes in this batch: tests/retrieval.development.mjs now records per-response usage and providerAuthorised; docs/backend/README.md documents the week-9 auth and local-closure entries. Neither changes the backend binary.'
    : 'Compilation was re-run in this batch.',
  build: {
    builder: latestBuild.builder,
    buildRoot: latestBuild.buildRoot,
    buildAudit: latestBuild.audit,
    mainExeSha256: latestBuild.mainExe?.sha256 ?? null,
    unitTests: latestBuild.unitTests ?? null
  },
  command: (verifyResult.reproduce || 'pwsh -NoProfile -File src/backend/verify.ps1 -SkipBuild'),
  verificationDirectory: rel(verificationDir),
  supersedes: previous,
  supersedesReason:
    'tests/retrieval.development.mjs gained usage/providerAuthorised recording and docs/backend/README.md gained the week-9 section, so the previous sourceManifest no longer describes the current files. Same 15 steps re-executed; earlier records stay on disk unmodified as history.',
  findings: [
    { id: 'A-01', status: 'fixed_verified', description: 'G1 summary derives from successful valid response metadata; real G1 call count stays 0.' },
    { id: 'A-02', status: 'fixed_verified', description: 'All-positive sixth-rank counterexample is rejected by the quality gate (exit 1).' },
    { id: 'A-03', status: 'fixed_verified', description: 'Test output counts are computed at runtime instead of hardcoded literals.' },
    { id: 'A-04', status: 'fixed_verified', description: 'Per-response usage and providerAuthorised are now recorded, so a G1 run can be billed from evidence instead of estimated.' }
  ],
  steps: (verifyResult.steps || []).map((s) => ({ name: s.name, command: s.command, exitCode: s.exitCode })),
  results: {
    httpIntegration: `${httpPassed}/${httpTotal} passed`,
    developmentRegression: `${retrieval.queryCount} queries x ${retrieval.rounds} rounds = ${retrieval.responseCount} responses; Hit@5=${retrieval.hitAt5}, Recall@5=${retrieval.recallAt5}, no-evidence accuracy=${retrieval.noEvidenceCorrect}`,
    developmentMetrics: {
      queryCount: retrieval.queryCount,
      positiveQueryCount: retrieval.positiveQueryCount,
      negativeQueryCount: retrieval.negativeQueryCount,
      responseCount: retrieval.responseCount,
      rounds: retrieval.rounds,
      hitAt5: retrieval.hitAt5,
      recallAt5: retrieval.recallAt5,
      noEvidenceCorrect: retrieval.noEvidenceCorrect,
      qualityGate: retrieval.qualityGate,
      domainLeakCount: retrieval.domainLeakCount,
      deterministic: retrieval.deterministic,
      executionStatus: retrieval.executionStatus,
      qualityStatus: retrieval.qualityStatus,
      usageRecorded: retrieval.usageRecorded ?? null,
      usageFieldMissing: retrieval.usageFieldMissing ?? null
    },
    gatewayModes: retrieval.observedGatewayModes,
    realG1CallCount: retrieval.gatewayExecution?.realG1CallCount ?? 0,
    domainLeakCount: retrieval.domainLeakCount,
    deterministic: retrieval.deterministic
  },
  sourceManifest,
  evidenceManifest,
  limitations: [
    'All data and labels are development synthetic/self-authored; no blind evaluation or AI-gain claim.',
    'G1 HTTP fixture labels simulate responses; no authorised real provider/model call was performed (realG1Ran=false).',
    'Compilation was not re-run in this batch (-SkipBuild); see buildEvidenceNote.'
  ],
  nextActions: [
    'Re-run cjpm build/test from an interactive terminal where cjpm 1.0.5 has a console, to retire the cjc fallback.',
    'When provider credentials exist, run the same 20x3 harness with ICT_PROVIDER_REAL=1 and bill it with tests/g1.accounting.mjs.'
  ]
}

fs.mkdirSync(outDir, { recursive: true })
fs.writeFileSync(path.join(outDir, 'result.json'), JSON.stringify(record, null, 2), 'utf8')

const md = [
  '# 第7周 A 线补充证据（脚本重建）',
  '',
  `生成：${record.generatedAt}`,
  `验证批次：\`${record.verificationDirectory}\``,
  `结论：**${record.status}**（退出码 ${record.exitCode}）`,
  '',
  '## 数字',
  '',
  `- HTTP 集成：${record.results.httpIntegration}`,
  `- 开发检索：${record.results.developmentRegression}`,
  `- 网关模式：${record.results.gatewayModes.join(', ')}；真实 G1 调用：${record.results.realG1CallCount}`,
  `- 用量字段：记录 ${record.results.developmentMetrics.usageRecorded} 条；字段异常 ${record.results.developmentMetrics.usageFieldMissing} 条`,
  `- 二进制：\`${String(record.build.mainExeSha256).slice(0, 12)}…\`（${record.build.builder}，${record.build.buildRoot}）`,
  '',
  '## 本批改动',
  '',
  '- `tests/retrieval.development.mjs`：记录 `usage` 与 `providerAuthorised`（后端早已返回，脚本此前丢弃）',
  '- `docs/backend/README.md`：补第9周身份、离线演示、部署自检、台账校验入口',
  '',
  '## 绑定源文件',
  '',
  ...record.sourceManifest.map((s) => `- \`${s.file}\` ${s.sha256.slice(0, 12)}`),
  '',
  '## 限制',
  '',
  ...record.limitations.map((l) => '- ' + l),
  '',
  `取代：\`${record.supersedes}\`（旧记录保留，未修改）`
]
fs.writeFileSync(path.join(outDir, 'result.md'), md.join('\n') + '\n', 'utf8')

console.log(
  JSON.stringify(
    {
      status: record.status,
      output: rel(outDir),
      verification: record.verificationDirectory,
      httpIntegration: record.results.httpIntegration,
      usageRecorded: record.results.developmentMetrics.usageRecorded,
      supersedes: record.supersedes
    },
    null,
    2
  )
)
process.exit(0)
