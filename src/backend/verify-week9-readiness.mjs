// Week-9 ledger validator.
//
// Week 9 introduces a failure mode the earlier weeks did not have: a local result that
// is easy to *describe* as a cloud result. The extra checks here are therefore about
// what a ledger is allowed to claim, not only about whether files exist:
//   1. a task marked complete must carry evidence (same rule as weeks 7 and 8);
//   2. a blocked task must not carry a completion claim and must name its blocker;
//   3. realG1Ran=true requires providerAuthorised=true (the stub-as-real guard);
//   4. an acceptance item may not be marked "met" without evidence;
//   5. cloud-scoped evidence must not be produced by a loopback-only run.
//
// Usage:
//   node src/backend/verify-week9-readiness.mjs [ledgerPath]
//   ICT_READINESS_AUDIT_DIR=<dir> node src/backend/verify-week9-readiness.mjs
//
// Exit code 0 only when every check passes.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../..')

const ledgerPath = process.argv[2]
  ? path.resolve(process.argv[2])
  : path.join(root, 'docs/backend/week9_readiness.json')

const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '')
const auditDir = process.env.ICT_READINESS_AUDIT_DIR
  ? path.resolve(process.env.ICT_READINESS_AUDIT_DIR)
  : path.join(root, 'audit/backend', `${stamp.replace(/[^0-9T]/g, '')}_week9_readiness`)

if (!auditDir.startsWith(root)) {
  console.error('ICT_READINESS_AUDIT_DIR must stay inside the workspace: ' + auditDir)
  process.exit(2)
}
fs.mkdirSync(auditDir, { recursive: true })

const failures = []
const warnings = []
const fail = (msg) => failures.push(msg)
const warn = (msg) => warnings.push(msg)

const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
const rel = (file) => path.relative(root, file).replace(/\\/g, '/')

if (!fs.existsSync(ledgerPath)) {
  console.error('ledger not found: ' + ledgerPath)
  process.exit(2)
}

let ledger
try {
  ledger = JSON.parse(fs.readFileSync(ledgerPath, 'utf8'))
} catch (error) {
  console.error('ledger is not valid JSON: ' + error.message)
  process.exit(2)
}

const ledgerSha256 = sha256(ledgerPath)

const REQUIRED_KEYS = ['schemaVersion', 'recordedAt', 'week', 'tasks', 'resources', 'evidence', 'statusVocabulary', 'acceptance']
for (const key of REQUIRED_KEYS) {
  if (!(key in ledger)) fail(`missing top-level key: ${key}`)
}
if (ledger.week !== 9) fail(`ledger.week is ${ledger.week}, expected 9`)

const vocabulary = new Set(ledger.statusVocabulary || [])
const tasks = Array.isArray(ledger.tasks) ? ledger.tasks : []
const resources = Array.isArray(ledger.resources) ? ledger.resources : []
const evidence = Array.isArray(ledger.evidence) ? ledger.evidence : []
const acceptance = Array.isArray(ledger.acceptance) ? ledger.acceptance : []

const taskIds = new Set()
for (const task of tasks) {
  if (!task.id) fail('task without id')
  if (taskIds.has(task.id)) fail(`duplicate task id: ${task.id}`)
  taskIds.add(task.id)
  if (!vocabulary.has(task.status)) fail(`${task.id}: status not in vocabulary: ${task.status}`)
}

// Gates are legitimate dependencies: a task may be waiting on a decision rather than on
// another task. They are collected separately so a typo still fails, and so the two kinds
// cannot be confused with each other.
const gates = Array.isArray(ledger.gates) ? ledger.gates : []
const gateIds = new Set()
for (const gate of gates) {
  if (!gate.id) fail('gate without id')
  if (gateIds.has(gate.id)) fail(`duplicate gate id: ${gate.id}`)
  if (taskIds.has(gate.id)) fail(`gate id collides with a task id: ${gate.id}`)
  gateIds.add(gate.id)
}

for (const task of tasks) {
  for (const dep of task.dependsOn || []) {
    if (!taskIds.has(dep) && !gateIds.has(dep)) fail(`${task.id}: dependsOn unknown task or gate ${dep}`)
  }
}

const evidenceById = new Map()
for (const item of evidence) {
  if (!item.id) { fail('evidence entry without id'); continue }
  if (evidenceById.has(item.id)) fail(`duplicate evidence id: ${item.id}`)
  const full = path.join(root, item.path || '')
  if (!item.path || !fs.existsSync(full)) {
    fail(`${item.id}: evidence file missing: ${item.path}`)
    continue
  }
  const actual = sha256(full)
  if (actual !== item.sha256) {
    fail(`${item.id}: hash mismatch (recorded ${String(item.sha256).slice(0, 12)}, actual ${actual.slice(0, 12)})`)
  }
  evidenceById.set(item.id, { ...item, full })
}

for (const task of tasks) {
  for (const eid of task.evidenceIds || []) {
    if (!evidenceById.has(eid)) fail(`${task.id}: references unknown evidence ${eid}`)
  }
  if (task.status === 'complete' && (task.evidenceIds || []).length === 0) {
    fail(`${task.id}: marked complete without any evidence`)
  }
  if (task.status === 'complete' && task.blocker) {
    warn(`${task.id}: complete but still carries a blocker text`)
  }
  if (task.status === 'blocked' && !task.blocker) {
    fail(`${task.id}: blocked without a stated blocker`)
  }
  if (task.status === 'blocked' && (task.evidenceIds || []).length > 0) {
    warn(`${task.id}: blocked but references evidence ${task.evidenceIds.join(',')} (check it is context, not a completion claim)`)
  }
}

// A G1 claim must be backed by an authorised provider.
const g1Claims = []
for (const [id, item] of evidenceById) {
  if (!item.full.endsWith('.json')) continue
  let payload
  try { payload = JSON.parse(fs.readFileSync(item.full, 'utf8')) } catch { continue }
  const seen = []
  const walk = (node, trail) => {
    if (!node || typeof node !== 'object') return
    if (Array.isArray(node)) { node.forEach((v, i) => walk(v, `${trail}[${i}]`)); return }
    if (node.realG1Ran === true) seen.push({ trail, authorised: node.providerAuthorised === true })
    for (const [k, v] of Object.entries(node)) walk(v, trail ? `${trail}.${k}` : k)
  }
  walk(payload, '')
  for (const hit of seen) {
    g1Claims.push({ evidence: id, path: hit.trail })
    if (!hit.authorised) fail(`${id}: realG1Ran=true at ${hit.trail} without providerAuthorised=true`)
  }
}

// An acceptance item may only be "met" when evidence is bound to it.
for (const item of acceptance) {
  if (!item.item) fail('acceptance entry without item text')
  if (!['met', 'partial', 'unmet'].includes(item.verdict)) {
    fail(`acceptance "${String(item.item).slice(0, 24)}": verdict must be met/partial/unmet, got ${item.verdict}`)
  }
  if (item.verdict === 'met' && (item.evidenceIds || []).length === 0) {
    fail(`acceptance "${String(item.item).slice(0, 24)}": met without evidence`)
  }
  for (const eid of item.evidenceIds || []) {
    if (!evidenceById.has(eid)) fail(`acceptance "${String(item.item).slice(0, 24)}": unknown evidence ${eid}`)
  }
}

// Cloud claims must not rest on loopback-only evidence. Week-9 evidence produced by the
// local runs declares its own notCovered list; if it does, the ledger must not mark a
// cloud acceptance item as met.
const cloudItems = acceptance.filter((a) => /云|cloud/i.test(a.item))
for (const item of cloudItems) {
  if (item.verdict !== 'met') continue
  const bound = (item.evidenceIds || []).map((id) => evidenceById.get(id)).filter(Boolean)
  const anyLoopbackOnly = bound.some((e) => {
    try {
      const payload = JSON.parse(fs.readFileSync(e.full, 'utf8'))
      const list = payload.notCovered || []
      return Array.isArray(list) && list.some((entry) => /cloud|云|public IP/i.test(String(entry)))
    } catch { return false }
  })
  if (anyLoopbackOnly) {
    fail(`acceptance "${String(item.item).slice(0, 24)}": marked met on evidence that declares cloud coverage absent`)
  }
}

// The device resource must not be reported as available unless hdc actually saw a target.
const device = resources.find((r) => r.id === 'device')
if (device && device.status === 'ready' && !device.observation) {
  fail('device resource marked ready without an hdc observation')
}

// Contest status: the plan makes week-9-end the decision point for a risk downgrade.
const contest = ledger.contestStatus
if (contest) {
  if (!['not_ready', 'high_risk', 'ready'].includes(contest.value)) {
    fail(`contestStatus.value is not one of not_ready/high_risk/ready: ${contest.value}`)
  }
  if (contest.value === 'ready') {
    const metAll = acceptance.every((a) => a.verdict === 'met')
    if (!metAll) fail('contestStatus=ready but not every acceptance item is met')
  }
}

const summary = {
  generatedAt: new Date().toISOString(),
  command: 'node src/backend/verify-week9-readiness.mjs',
  ledger: rel(ledgerPath),
  ledgerSha256,
  counts: { tasks: tasks.length, resources: resources.length, evidence: evidence.length, acceptance: acceptance.length },
  byStatus: tasks.reduce((acc, t) => { acc[t.status] = (acc[t.status] || 0) + 1; return acc }, {}),
  acceptanceVerdicts: acceptance.reduce((acc, a) => { acc[a.verdict] = (acc[a.verdict] || 0) + 1; return acc }, {}),
  g1Claims,
  failures,
  warnings,
  status: failures.length ? 'failed' : 'passed',
}

fs.writeFileSync(path.join(auditDir, 'result.json'), JSON.stringify(summary, null, 2), 'utf8')

const md = [
  '# 第9周台账校验',
  '',
  `时间：${summary.generatedAt}`,
  `台账：\`${summary.ledger}\``,
  `台账 SHA256：\`${ledgerSha256}\``,
  `结论：**${summary.status}**`,
  '',
  '## 数量',
  '',
  `- 任务 ${tasks.length}，资源 ${resources.length}，证据 ${evidence.length}，验收项 ${acceptance.length}`,
  `- 任务状态：${Object.entries(summary.byStatus).map(([k, v]) => `${k}=${v}`).join('，')}`,
  `- 验收判定：${Object.entries(summary.acceptanceVerdicts).map(([k, v]) => `${k}=${v}`).join('，')}`,
  '',
  '## 真实调用声明检查',
  '',
  summary.g1Claims.length
    ? summary.g1Claims.map((c) => `- 证据 \`${c.evidence}\` 在 \`${c.path}\` 声明 realG1Ran=true`).join('\n')
    : '- 未发现任何 realG1Ran=true 声明（真实调用仍为 0）',
  '',
  '## 失败项',
  '',
  failures.length ? failures.map((f) => `- ${f}`).join('\n') : '- 无',
  '',
  '## 警告',
  '',
  warnings.length ? warnings.map((w) => `- ${w}`).join('\n') : '- 无',
]
fs.writeFileSync(path.join(auditDir, 'result.md'), md.join('\n') + '\n', 'utf8')

console.log(JSON.stringify({ status: summary.status, failures, warnings, auditDirectory: rel(auditDir) }, null, 2))
process.exit(failures.length ? 1 : 0)
