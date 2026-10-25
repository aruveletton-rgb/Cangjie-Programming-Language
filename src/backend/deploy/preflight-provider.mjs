// Provider configuration preflight.
//
// Answers one question before any money or data moves: "is this host configured well
// enough to attempt a real provider call?" It performs NO network request by default.
//
// Usage:
//   node src/backend/deploy/preflight-provider.mjs            config check only
//   node src/backend/deploy/preflight-provider.mjs --live     one minimal call, only when
//                                                             ICT_PROVIDER_REAL=1 is set
//
// Exit codes: 0 = ready, 1 = not ready, 2 = live call refused or failed.
//
// The API key is never printed. Only its length and last 4 characters are reported.

const REQUIRED = ['ICT_PROVIDER_ENDPOINT', 'ICT_PROVIDER_API_KEY', 'ICT_PROVIDER_MODEL']
const live = process.argv.includes('--live')

const mask = (value) => {
  if (!value) return null
  if (value.length <= 4) return '*'.repeat(value.length)
  return '*'.repeat(Math.max(0, value.length - 4)) + value.slice(-4)
}

const env = process.env
const findings = []
const facts = {}

for (const name of REQUIRED) {
  const value = (env[name] || '').trim()
  if (!value) findings.push({ level: 'error', code: 'MISSING', variable: name })
  else facts[name === 'ICT_PROVIDER_API_KEY' ? 'apiKey' : name] = name === 'ICT_PROVIDER_API_KEY' ? mask(value) : value
}

const endpoint = (env.ICT_PROVIDER_ENDPOINT || '').trim()
if (endpoint) {
  let url
  try {
    url = new URL(endpoint)
  } catch {
    findings.push({ level: 'error', code: 'ENDPOINT_NOT_URL', value: endpoint })
  }
  if (url) {
    if (url.protocol !== 'https:') findings.push({ level: 'error', code: 'ENDPOINT_NOT_HTTPS', value: url.protocol })
    if (/\/chat\/completions\/?$/.test(url.pathname)) {
      findings.push({ level: 'error', code: 'ENDPOINT_HAS_CHAT_PATH', hint: 'use the base URL ending in /v1' })
    }
    facts.endpointHost = url.host
    facts.endpointPath = url.pathname
    if (!/modelarts-maas\.com$/.test(url.hostname)) {
      findings.push({ level: 'warn', code: 'ENDPOINT_NOT_MAAS', hint: 'expected api.modelarts-maas.com for the chosen option A' })
    }
  }
}

const timeout = Number(env.ICT_PROVIDER_TIMEOUT_MS || 15000)
facts.timeoutMs = timeout
if (!Number.isFinite(timeout) || timeout < 1000 || timeout > 120000) {
  findings.push({ level: 'warn', code: 'TIMEOUT_OUT_OF_RANGE', value: env.ICT_PROVIDER_TIMEOUT_MS })
}

const authorised = env.ICT_PROVIDER_REAL === '1'
facts.providerAuthorised = authorised
if (!authorised) {
  findings.push({ level: 'info', code: 'NOT_AUTHORISED', hint: 'ICT_PROVIDER_REAL is not "1"; realG1Ran will stay false even if a call succeeds' })
}

facts.providerName = env.ICT_PROVIDER_NAME || 'openai-compatible'
facts.model = (env.ICT_PROVIDER_MODEL || '').trim() || null

const errors = findings.filter((item) => item.level === 'error')
const ready = errors.length === 0

const report = { ready, mode: live ? 'live' : 'config-only', facts, findings }

if (!live) {
  console.log(JSON.stringify(report, null, 2))
  process.exit(ready ? 0 : 1)
}

if (!ready) {
  console.log(JSON.stringify({ ...report, liveRefused: 'configuration has errors' }, null, 2))
  process.exit(2)
}
if (!authorised) {
  console.log(JSON.stringify({ ...report, liveRefused: 'ICT_PROVIDER_REAL is not "1"; refusing to send a real request' }, null, 2))
  process.exit(2)
}

const body = {
  model: facts.model,
  messages: [
    { role: 'system', content: 'Reply with the single word OK. Do not add anything else.' },
    { role: 'user', content: 'ping' }
  ],
  max_tokens: 8,
  temperature: 0
}

const started = Date.now()
try {
  const response = await fetch(endpoint.replace(/\/$/, '') + '/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${env.ICT_PROVIDER_API_KEY.trim()}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(timeout)
  })
  const text = await response.text()
  let parsed = null
  try {
    parsed = JSON.parse(text)
  } catch {
    parsed = null
  }
  const usage = parsed?.usage || null
  console.log(
    JSON.stringify(
      {
        ...report,
        live: {
          status: response.status,
          latencyMs: Date.now() - started,
          model: parsed?.model ?? null,
          usage,
          replyHead: (parsed?.choices?.[0]?.message?.content ?? '').slice(0, 40),
          bodyHead: parsed ? undefined : text.slice(0, 200)
        }
      },
      null,
      2
    )
  )
  process.exit(response.ok ? 0 : 2)
} catch (error) {
  console.log(JSON.stringify({ ...report, live: { error: error.name, message: error.message, latencyMs: Date.now() - started } }, null, 2))
  process.exit(2)
}
