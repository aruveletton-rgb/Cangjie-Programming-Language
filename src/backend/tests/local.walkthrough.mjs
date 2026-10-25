// Local end-to-end walkthrough (offline demo).
//
// Purpose: one command that shows the whole business loop working with no cloud, no
// device, and no frontend build: query -> draft -> confirm -> submit -> receipt, plus
// replay and cross-domain isolation. It is a *demonstration and smoke check*, not a
// replacement for the full regression (tests/http.integration.mjs) — it asserts far less.
//
// Usage:
//   node src/backend/tests/local.walkthrough.mjs
//   node src/backend/tests/local.walkthrough.mjs --base http://127.0.0.1:38083 --out temp/backend/walkthrough.json
//
// Exit codes: 0 = every step passed, 1 = at least one step failed, 2 = server unreachable.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')

const argv = process.argv.slice(2)
const argValue = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : undefined
}
const base = (argValue('--base') || process.env.ICT_BASE_URL || 'http://127.0.0.1:38082').replace(/\/$/, '')
const outPath = path.resolve(root, argValue('--out') || 'temp/backend/local_walkthrough.json')
const session = argValue('--session') || 'campus-user'

const run = Date.now().toString(36)
let counter = 0
const rid = () => `walk-${run}-${++counter}`
const steps = []

const call = async (method, endpoint, body, extra = {}) => {
  const headers = { 'Content-Type': 'application/json', 'X-Demo-Session': session, ...extra }
  const started = Date.now()
  const response = await fetch(base + endpoint, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body)
  })
  const text = await response.text()
  let value = null
  try {
    value = JSON.parse(text)
  } catch {
    value = { raw: text.slice(0, 200) }
  }
  return { status: response.status, value, ms: Date.now() - started }
}

const record = (name, ok, detail, ms = null) => {
  steps.push({ name, status: ok ? 'pass' : 'fail', detail, ms })
  return ok
}

// Reachability first: a connection error here is a setup problem, not a business failure.
try {
  await fetch(base + '/health', { signal: AbortSignal.timeout(3000) })
} catch (error) {
  console.log(JSON.stringify({ status: 'unreachable', base, error: error.message }, null, 2))
  process.exit(2)
}

// 1. health
const health = await call('GET', '/health')
const h = health.value?.data || {}
record('health', health.value?.code === 'OK', `code=${health.value?.code} synthetic=${h.synthetic} authMode=${h.authMode} gateway=${h.gateway}`, health.ms)

// 2. query with evidence
const chat = await call('POST', '/api/v1/chat', { requestId: rid(), text: '最近的停水通知是什么时候？' })
const chatData = chat.value?.data || {}
const refs = Array.isArray(chatData.evidenceRefs) ? chatData.evidenceRefs : []
record('query', chat.value?.code === 'OK' && refs.length > 0, `refs=${refs.length} status=${chatData.answerStatus ?? 'n/a'}`, chat.ms)

// 3. draft
const draftResp = await call('POST', '/api/v1/ticket-drafts', {
  requestId: rid(),
  location: '公共区域走廊',
  description: '合成演示：灯具损坏（本地闭环走查）',
  contactAlias: 'SYN-CONTACT-K'
})
const draft = draftResp.value?.data || {}
record('draft', draftResp.value?.code === 'OK' && Boolean(draft.draftId), `draftId=${draft.draftId} revision=${draft.revision}`, draftResp.ms)

// 4. confirm
const confirmResp = await call('POST', `/api/v1/ticket-drafts/${draft.draftId}/confirm`, {
  requestId: rid(),
  revision: draft.revision
})
const confirmation = confirmResp.value?.data || {}
record('confirm', confirmResp.value?.code === 'OK' && Boolean(confirmation.confirmationId), `confirmationId=${confirmation.confirmationId}`, confirmResp.ms)

// 5. submit with idempotency key
const submission = { requestId: rid(), draftId: draft.draftId, confirmationId: confirmation.confirmationId }
const idemKey = rid()
const submitResp = await call('POST', '/api/v1/tickets', submission, { 'Idempotency-Key': idemKey })
const ticket = submitResp.value?.data || {}
record('submit', submitResp.value?.code === 'OK' && ticket.status === 'SUBMITTED', `ticketId=${ticket.ticketId} status=${ticket.status} version=${ticket.version}`, submitResp.ms)

// 6. replay with the same key must return the same ticket and add nothing.
// The baseline is taken AFTER the first submit: comparing against a pre-submit count
// would always fail by exactly one ticket.
const countAfterSubmit = await call('GET', '/api/v1/tickets')
const before = Array.isArray(countAfterSubmit.value?.data?.items) ? countAfterSubmit.value.data.items.length : null
const replayResp = await call('POST', '/api/v1/tickets', submission, { 'Idempotency-Key': idemKey })
const countAfter = await call('GET', '/api/v1/tickets')
const after = Array.isArray(countAfter.value?.data?.items) ? countAfter.value.data.items.length : null
const sameTicket = replayResp.value?.data?.ticketId === ticket.ticketId
record('replay-idempotent', replayResp.value?.code === 'OK' && sameTicket && before === after, `sameTicketId=${sameTicket} tickets after submit/replay ${before}->${after}`, replayResp.ms)

// 7. receipt
const receiptResp = await call('GET', `/api/v1/requests/${submission.requestId}/result`)
const receipt = receiptResp.value?.data || {}
record('receipt', receipt.resultStatus === 'COMMITTED' && receipt.ticketId === ticket.ticketId, `resultStatus=${receipt.resultStatus} ticketId=${receipt.ticketId}`, receiptResp.ms)

// 8. cross-domain isolation (the community session must not see the campus ticket)
const cross = await fetch(base + `/api/v1/tickets/${ticket.ticketId}`, { headers: { 'X-Demo-Session': 'community-user' } })
const crossBody = await cross.json().catch(() => ({}))
record('cross-domain-isolation', cross.status === 403, `community-user GET campus ticket -> ${cross.status} ${crossBody.code ?? ''}`)

const failed = steps.filter((s) => s.status === 'fail')
const report = {
  generatedAt: new Date().toISOString(),
  base,
  session,
  status: failed.length ? 'failed' : 'passed',
  steps,
  counts: { total: steps.length, passed: steps.length - failed.length, failed: failed.length },
  artifacts: { ticketId: ticket.ticketId ?? null, requestId: submission.requestId ?? null },
  boundary:
    'Local demonstration over loopback with synthetic data. Not a cloud deployment, not device verification, not a real model call, not a blind evaluation.'
}

fs.mkdirSync(path.dirname(outPath), { recursive: true })
fs.writeFileSync(outPath, JSON.stringify(report, null, 2), 'utf8')

const width = Math.max(...steps.map((s) => s.name.length))
for (const s of steps) {
  const tag = s.status === 'pass' ? 'PASS' : 'FAIL'
  console.log(`  ${tag}  ${s.name.padEnd(width)}  ${s.detail}${s.ms === null ? '' : `  (${s.ms} ms)`}`)
}
console.log(`\n  ${report.counts.passed}/${report.counts.total} steps passed  ->  ${path.relative(root, outPath).replace(/\\/g, '/')}`)

process.exit(failed.length ? 1 : 0)
