// Apply the token-accounting policy to a finished retrieval run.
//
// Why this is a separate script instead of a patch to tests/retrieval.development.mjs:
// that harness is one of the 11 files bound by the week-7 A-FOLLOWUP evidence manifest.
// Editing it silently invalidates a bound hash and the week-7 validator then fails with
// "Bound file hash mismatch" — which has already happened once in this project. So the
// accounting reads the harness output instead of changing the harness. Extending the
// harness itself is scheduled for week 10, together with the planned evidence rebind.
//
// Usage:
//   node src/backend/tests/g1.accounting.mjs --input <retrieval-result.json>
//   ICT_WEEK_TOKEN_LIMIT=200000 ICT_MAX_OUTPUT_TOKENS=1024 node src/backend/tests/g1.accounting.mjs --input ...
//
// Exit codes: 0 = accounting produced a decision, 1 = records contain an invalid G1 claim.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { summarizeUsage } from './g1.budget.mjs'

const here = path.dirname(fileURLToPath(import.meta.url))
const root = path.resolve(here, '../../..')

const argv = process.argv.slice(2)
const argValue = (name) => {
  const i = argv.indexOf(name)
  return i >= 0 ? argv[i + 1] : undefined
}
const input = path.resolve(root, argValue('--input') || '')
if (!argValue('--input') || !fs.existsSync(input)) {
  console.error('usage: node src/backend/tests/g1.accounting.mjs --input <retrieval-result.json>')
  process.exit(2)
}

const payload = JSON.parse(fs.readFileSync(input, 'utf8'))
const records = Array.isArray(payload.results) ? payload.results : []
if (records.length === 0) {
  console.error('no results[] in ' + input)
  process.exit(2)
}

const limit = Number(process.env.ICT_WEEK_TOKEN_LIMIT || 1_000_000)
const maxOut = Number(process.env.ICT_MAX_OUTPUT_TOKENS || 2048)
const summary = summarizeUsage(records, {
  weekLimitTokens: limit,
  maxOutputTokensPerRequest: maxOut,
  unitPricePerToken: process.env.ICT_UNIT_PRICE_PER_TOKEN ? Number(process.env.ICT_UNIT_PRICE_PER_TOKEN) : null
})

// The source gap is reported, not hidden: this harness does not record `usage`, so a real
// G1 run through it would arrive here with no token counts at all.
const usageFieldPresent = records.some((r) => r.usage !== undefined)
const sourceGap = usageFieldPresent
  ? null
  : {
      field: 'usage',
      present: false,
      impact:
        'the retrieval harness does not record provider usage; a real G1 run through it would count 0 known tokens and reserve the worst case for every call',
      plannedFix: 'week 10: record usage.totalTokens in tests/retrieval.development.mjs and rebind week-7 evidence in the same batch'
    }

const report = {
  generatedAt: new Date().toISOString(),
  input: path.relative(root, input).replace(/\\/g, '/'),
  sourceResponses: records.length,
  observedGatewayModes: [...new Set(records.map((r) => r.gatewayMode).filter(Boolean))].sort(),
  usageFieldPresent,
  sourceGap,
  accounting: summary,
  boundary: 'Arithmetic over recorded responses. No provider was contacted; no cost figure is a bill.',
  status: summary.invalidClaims.length ? 'invalid_claim' : 'accounted'
}

console.log(JSON.stringify(report, null, 2))
process.exit(summary.invalidClaims.length ? 1 : 0)
