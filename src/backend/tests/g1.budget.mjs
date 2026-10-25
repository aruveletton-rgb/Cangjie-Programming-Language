// Token accounting for G0/G1 comparison runs.
//
// docs/backend/usage_policy.md v1.0 was confirmed on 2026-10-24 but nothing enforced it:
// tests/retrieval.development.mjs records gatewayMode and realG1Ran, and throws away
// usage. This module is the missing half — it takes the records a run produced and answers
// the two questions the policy asks:
//
//   how many tokens does this week count?   (only realG1Ran=true counts)
//   may the next request be sent at all?    (no, once the weekly token limit is reached)
//
// The policy's harder cases are the ones that matter here, because they are the ones a
// naive sum gets wrong:
//   - usage missing        -> count it as unknown and reserve the worst case, not as 0;
//   - downgraded to G0     -> 0 tokens, but the record still exists (no record != no event);
//   - no unit price        -> cost is null, never 0 (0 would read as "free");
//   - failed call          -> usage null, and the failure is not evidence of zero cost.
//
// Nothing in here performs a network call. It is arithmetic plus claim checking, so it can
// be fully tested before a provider exists.

export const POLICY_DEFAULTS = {
  weekLimitTokens: 1_000_000,
  maxOutputTokensPerRequest: 2048,
  unitPricePerToken: null,
  currency: 'CNY'
}

const isPositiveInt = (value) => Number.isInteger(value) && value > 0
const isNonNegativeInt = (value) => Number.isInteger(value) && value >= 0

// Records that claim a real provider call but cannot substantiate it are not counted as
// billable, and are surfaced instead of being quietly dropped.
function inspectClaims(record) {
  const claims = []
  if (record.realG1Ran === true && record.providerAuthorised !== true) {
    claims.push('REAL_G1_WITHOUT_AUTHORISATION')
  }
  if (record.gatewayMode === 'G1' && record.realG1Ran !== true) {
    claims.push('G1_MODE_WITHOUT_REAL_FLAG')
  }
  if (record.realG1Ran === true && record.gatewayMode !== undefined && record.gatewayMode !== 'G1') {
    claims.push('REAL_G1_OUTSIDE_G1_MODE')
  }
  return claims
}

export function summarizeUsage(records, policy = {}) {
  if (!Array.isArray(records)) throw new TypeError('records must be an array')
  const effective = { ...POLICY_DEFAULTS, ...policy }
  if (!isPositiveInt(effective.weekLimitTokens)) throw new RangeError('weekLimitTokens must be a positive integer')
  if (!isPositiveInt(effective.maxOutputTokensPerRequest)) {
    throw new RangeError('maxOutputTokensPerRequest must be a positive integer')
  }
  if (effective.unitPricePerToken !== null && !(typeof effective.unitPricePerToken === 'number' && effective.unitPricePerToken >= 0)) {
    throw new RangeError('unitPricePerToken must be null or a non-negative number')
  }

  const invalidClaims = []
  const unknownUsage = []
  let g1Records = 0
  let g0Records = 0
  let countedTokens = 0
  let failedCalls = 0
  let downgraded = 0
  const perModel = {}

  records.forEach((record, index) => {
    const claims = inspectClaims(record)
    if (claims.length) invalidClaims.push({ index, claims, queryId: record.queryId ?? null })

    if (record.gatewayMode === 'G0') g0Records++
    if (record.callStatus === 'failed') failedCalls++
    if (record.downgraded === true) downgraded++

    if (record.realG1Ran !== true) return
    g1Records++

    const total = record.usage?.totalTokens
    if (!isNonNegativeInt(total)) {
      unknownUsage.push({
        index,
        queryId: record.queryId ?? null,
        reason: total === undefined || total === null ? 'USAGE_MISSING' : 'USAGE_NOT_NON_NEGATIVE_INTEGER',
        value: total ?? null
      })
      return
    }
    countedTokens += total
    const model = record.modelVersion || record.provider || 'unknown'
    perModel[model] = (perModel[model] || 0) + total
  })

  const reservedTokens = unknownUsage.length * effective.maxOutputTokensPerRequest
  const effectiveTokens = countedTokens + reservedTokens
  const overLimit = effectiveTokens >= effective.weekLimitTokens
  const decision = overLimit ? 'stop' : 'allow'

  // Integer micro-units keep repeated additions from drifting; the value is still an
  // estimate until a provider bill exists, which is why `costEstimated` is always true.
  let cost = null
  if (effective.unitPricePerToken !== null) {
    const micros = Math.round(effectiveTokens * effective.unitPricePerToken * 1_000_000)
    cost = micros / 1_000_000
  }

  return {
    policy: {
      weekLimitTokens: effective.weekLimitTokens,
      maxOutputTokensPerRequest: effective.maxOutputTokensPerRequest,
      unitPricePerToken: effective.unitPricePerToken,
      currency: effective.currency
    },
    records: records.length,
    g1Records,
    g0Records,
    downgradedRecords: downgraded,
    failedCalls,
    countedTokens,
    unknownUsageCount: unknownUsage.length,
    reservedTokens,
    effectiveTokens,
    remainingTokens: Math.max(0, effective.weekLimitTokens - effectiveTokens),
    overLimit,
    decision,
    reason: overLimit
      ? `effective ${effectiveTokens} >= limit ${effective.weekLimitTokens}; G1 must fall back to G0 for the rest of the week`
      : `effective ${effectiveTokens} < limit ${effective.weekLimitTokens}`,
    cost,
    costEstimated: cost !== null,
    costNote: cost === null ? 'unit price unknown; cost recorded as null, not 0' : 'estimate from provider-reported tokens; not a bill',
    perModel,
    unknownUsage,
    invalidClaims,
    realG1Ran: g1Records > 0,
    providerAuthorised: g1Records > 0 && invalidClaims.every((c) => !c.claims.includes('REAL_G1_WITHOUT_AUTHORISATION'))
  }
}

// A run is only allowed to start when the weekly budget still has room. This is the gate
// the comparison harness will call before its first request.
export function gateNextRun(records, policy = {}) {
  const summary = summarizeUsage(records, policy)
  return {
    allow: summary.decision === 'allow',
    summary,
    blockedReason: summary.decision === 'allow' ? null : summary.reason
  }
}
