// Week-8 ledger validator.
//
// Purpose: make the week-8 ledger machine-checkable the same way week 7 is, and in
// particular block the two failure modes that matter most here:
//   1. a task marked complete with no evidence behind it;
//   2. a stub or mock reported as a real model run (realG1Ran true without
//      providerAuthorised true).
//
// Usage:
//   node src/backend/verify-week8-readiness.mjs [ledgerPath]
//   ICT_READINESS_AUDIT_DIR=<dir> node src/backend/verify-week8-readiness.mjs
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
  : path.join(root, 'docs/backend/week8_readiness.json')

const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+/, '').replace('T', 'T')
const auditDir = process.env.ICT_READINESS_AUDIT_DIR
  ? path.resolve(process.env.ICT_READINESS_AUDIT_DIR)
  : path.join(root, 'audit/backend', `${stamp.replace(/[^0-9T]/g, '')}_week8_readiness`)

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

const REQUIRED_KEYS = ['schemaVersion', 'recordedAt', 'week', 'tasks', 'resources', 'evidence', 'statusVocabulary']
for (const key of REQUIRED_KEYS) {
  if (!(key in ledger)) fail(`missing top-level key: ${key}`)
}

const vocabulary = new Set(ledger.statusVocabulary || [])
const tasks = Array.isArray(ledger.tasks) ? ledger.tasks : []
const resources = Array.isArray(ledger.resources) ? ledger.resources : []
const evidence = Array.isArray(ledger.evidence) ? ledger.evidence : []

const taskIds = new Set()
for (const task of tasks) {
  if (!task.id) fail('task without id')
  if (taskIds.has(task.id)) fail(`duplicate task id: ${task.id}`)
  taskIds.add(task.id)
  if (!vocabulary.has(task.status)) fail(`${task.id}: status not in vocabulary: ${task.status}`)
}

for (const task of tasks) {
  for (const dep of task.dependsOn || []) {
    if (!taskIds.has(dep)) fail(`${task.id}: dependsOn unknown task ${dep}`)
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
  if (actual !== item.sha256) fail(`${item.id}: hash mismatch (recorded ${String(item.sha256).slice(0, 12)}, actual ${actual.slice(0, 12)})`)
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
}

// A G1 claim must be backed by an authorised provider. This is the check that stops a
// local stub returning 200 from being reported as a real model run.
const g1Claims = []
for (const [id, item] of evidenceById) {
  if (!item.full.endsWith('.json')) continue
  let payload
  try {
    payload = JSON.parse(fs.readFileSync(item.full, 'utf8'))
  } catch {
    continue
  }
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

// When A5 is blocked, an explicit G1_NOT_RUN declaration must exist.
const a5 = tasks.find((t) => t.id === 'W8-A5')
if (a5 && a5.status !== 'complete') {
  const hasDeclaration = [...evidenceById.values()].some((item) => item.kind === 'branch2_declaration')
  if (!hasDeclaration) fail('W8-A5 is not complete but no branch2_declaration evidence is bound')
}

// Frozen eval set must match its freeze receipt.
const evalRel = 'docs/research/eval_set_v1.json'
const freezeRel = 'docs/research/eval_set_v1.freeze.json'
if (fs.existsSync(path.join(root, evalRel)) && fs.existsSync(path.join(root, freezeRel))) {
  const evalDoc = JSON.parse(fs.readFileSync(path.join(root, evalRel), 'utf8'))
  const receipt = JSON.parse(fs.readFileSync(path.join(root, freezeRel), 'utf8'))
  if (evalDoc.status === 'frozen') {
    const actual = sha256(path.join(root, evalRel))
    if (actual !== receipt.sha256) fail('eval_set_v1 is frozen but its hash does not match the freeze receipt')
    if (!receipt.frozenAt) fail('freeze receipt has no frozenAt')
  } else {
    warn(`eval_set_v1 status is ${evalDoc.status}, not frozen`)
  }
}

// Approval record consistency.
const approvals = ledger.pendingApprovals
if (approvals) {
  const recordPath = path.join(root, approvals.record || '')
  if (!fs.existsSync(recordPath)) {
    fail('pendingApprovals record missing: ' + approvals.record)
  } else {
    const record = JSON.parse(fs.readFileSync(recordPath, 'utf8'))
    const open = (record.items || []).filter((i) => i.status === 'pending').length
    if (approvals.openCount !== undefined && approvals.openCount !== open) {
      fail(`pendingApprovals.openCount=${approvals.openCount} but record has ${open} pending items`)
    }
  }
}

const summary = {
  generatedAt: new Date().toISOString(),
  command: 'node src/backend/verify-week8-readiness.mjs',
  ledger: rel(ledgerPath),
  ledgerSha256,
  counts: { tasks: tasks.length, resources: resources.length, evidence: evidence.length },
  byStatus: tasks.reduce((acc, t) => { acc[t.status] = (acc[t.status] || 0) + 1; return acc }, {}),
  g1Claims,
  failures,
  warnings,
  status: failures.length ? 'failed' : 'passed',
}

fs.writeFileSync(path.join(auditDir, 'result.json'), JSON.stringify(summary, null, 2), 'utf8')

const md = [
  '# 第8周台账校验',
  '',
  `时间：${summary.generatedAt}`,
  `台账：\`${summary.ledger}\``,
  `台账 SHA256：\`${ledgerSha256}\``,
  `结论：**${summary.status}**`,
  '',
  '## 数量',
  '',
  `- 任务 ${tasks.length}，资源 ${resources.length}，证据 ${evidence.length}`,
  `- 状态分布：${Object.entries(summary.byStatus).map(([k, v]) => `${k}=${v}`).join('，')}`,
  '',
  '## 真实调用声明检查',
  '',
  summary.g1Claims.length
    ? summary.g1Claims.map((c) => `- 证据 \`${c.evidence}\` 在 \`${c.path}\` 声明 realG1Ran=true`).join('\n')
    : '- 未发现任何 realG1Ran=true 声明',
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
