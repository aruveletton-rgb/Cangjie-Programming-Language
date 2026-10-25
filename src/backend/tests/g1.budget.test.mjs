import assert from 'node:assert/strict';
import {POLICY_DEFAULTS, gateNextRun, summarizeUsage} from './g1.budget.mjs';

// Counts come from what actually ran (same rule as retrieval.metrics.test.mjs): a literal
// here would keep passing after a case was deleted.
const executed=[];
function scenario(name,fn){ fn(); executed.push(name); }
const policy={weekLimitTokens:1000,maxOutputTokensPerRequest:100,unitPricePerToken:null};
const g1=(extra={})=>({gatewayMode:'G1',realG1Ran:true,providerAuthorised:true,usage:{totalTokens:100},...extra});

scenario('empty:allow-zero',()=>{
  const s=summarizeUsage([],policy);
  assert.equal(s.effectiveTokens,0);
  assert.equal(s.decision,'allow');
  assert.equal(s.realG1Ran,false);
});

scenario('g0-only-costs-nothing',()=>{
  const s=summarizeUsage([{gatewayMode:'G0',realG1Ran:false,usage:null},{gatewayMode:'G0',realG1Ran:false}],policy);
  assert.equal(s.g0Records,2);
  assert.equal(s.g1Records,0);
  assert.equal(s.countedTokens,0);
  assert.equal(s.decision,'allow');
});

scenario('sums-real-g1-tokens',()=>{
  const s=summarizeUsage([g1(),g1({usage:{totalTokens:250}})],policy);
  assert.equal(s.g1Records,2);
  assert.equal(s.countedTokens,350);
  assert.equal(s.effectiveTokens,350);
  assert.equal(s.remainingTokens,650);
});

scenario('missing-usage-reserves-worst-case',()=>{
  const s=summarizeUsage([g1({usage:null}),g1({usage:null})],policy);
  assert.equal(s.countedTokens,0);
  assert.equal(s.unknownUsageCount,2);
  assert.equal(s.reservedTokens,200);
  assert.equal(s.effectiveTokens,200);
  assert.equal(s.unknownUsage[0].reason,'USAGE_MISSING');
});

scenario('non-integer-usage-is-unknown-not-zero',()=>{
  const s=summarizeUsage([g1({usage:{totalTokens:-5}}),g1({usage:{totalTokens:'80'}})],policy);
  assert.equal(s.countedTokens,0);
  assert.equal(s.unknownUsageCount,2);
  assert.equal(s.unknownUsage[0].reason,'USAGE_NOT_NON_NEGATIVE_INTEGER');
});

scenario('at-limit-stops',()=>{
  const s=summarizeUsage([g1({usage:{totalTokens:1000}})],policy);
  assert.equal(s.overLimit,true);
  assert.equal(s.decision,'stop');
});

scenario('over-limit-stops',()=>{
  const s=summarizeUsage([g1({usage:{totalTokens:600}}),g1({usage:{totalTokens:500}})],policy);
  assert.equal(s.overLimit,true);
  assert.equal(s.remainingTokens,0);
  assert.match(s.reason,/must fall back to G0/);
});

scenario('reserved-tokens-can-trip-limit',()=>{
  const s=summarizeUsage([g1({usage:{totalTokens:950}}),g1({usage:null})],policy);
  assert.equal(s.effectiveTokens,1050);
  assert.equal(s.decision,'stop');
});

scenario('real-g1-without-authorisation-is-flagged',()=>{
  const s=summarizeUsage([g1({providerAuthorised:false})],policy);
  assert.equal(s.invalidClaims.length,1);
  assert.equal(s.invalidClaims[0].claims[0],'REAL_G1_WITHOUT_AUTHORISATION');
  assert.equal(s.providerAuthorised,false);
});

scenario('g1-mode-without-real-flag-is-flagged',()=>{
  const s=summarizeUsage([{gatewayMode:'G1',realG1Ran:false,providerAuthorised:true}],policy);
  assert.equal(s.invalidClaims[0].claims[0],'G1_MODE_WITHOUT_REAL_FLAG');
  assert.equal(s.countedTokens,0);
});

scenario('real-flag-outside-g1-mode-is-flagged',()=>{
  const s=summarizeUsage([g1({gatewayMode:'G0'})],policy);
  assert.equal(s.invalidClaims[0].claims[0],'REAL_G1_OUTSIDE_G1_MODE');
});

scenario('cost-null-without-unit-price',()=>{
  const s=summarizeUsage([g1()],policy);
  assert.equal(s.cost,null);
  assert.equal(s.costEstimated,false);
  assert.match(s.costNote,/null, not 0/);
});

scenario('cost-estimated-with-unit-price',()=>{
  const s=summarizeUsage([g1({usage:{totalTokens:1000}})],{...policy,unitPricePerToken:0.000002});
  assert.equal(s.cost,0.002);
  assert.equal(s.costEstimated,true);
});

scenario('failed-call-recorded-but-not-billable',()=>{
  const s=summarizeUsage([g1({callStatus:'failed',usage:null})],policy);
  assert.equal(s.failedCalls,1);
  assert.equal(s.countedTokens,0);
  assert.equal(s.reservedTokens,100);
});

scenario('downgrade-counted-separately',()=>{
  const s=summarizeUsage([{gatewayMode:'G0',realG1Ran:false,downgraded:true}],policy);
  assert.equal(s.downgradedRecords,1);
  assert.equal(s.countedTokens,0);
});

scenario('per-model-split',()=>{
  const s=summarizeUsage([g1({modelVersion:'m-a',usage:{totalTokens:10}}),g1({modelVersion:'m-a',usage:{totalTokens:5}}),g1({modelVersion:'m-b',usage:{totalTokens:7}})],policy);
  assert.deepEqual(s.perModel,{'m-a':15,'m-b':7});
});

scenario('invalid-policy-throws',()=>{
  assert.throws(()=>summarizeUsage([],{weekLimitTokens:0}),RangeError);
  assert.throws(()=>summarizeUsage([],{maxOutputTokensPerRequest:-1}),RangeError);
  assert.throws(()=>summarizeUsage([],{unitPricePerToken:-0.1}),RangeError);
});

scenario('gate-allows-then-blocks',()=>{
  const first=gateNextRun([],policy);
  assert.equal(first.allow,true);
  assert.equal(first.blockedReason,null);
  const second=gateNextRun([g1({usage:{totalTokens:1000}})],policy);
  assert.equal(second.allow,false);
  assert.match(second.blockedReason,/>= limit/);
});

scenario('defaults-are-explicit',()=>{
  assert.equal(POLICY_DEFAULTS.unitPricePerToken,null);
  assert.ok(POLICY_DEFAULTS.weekLimitTokens>0);
  assert.ok(POLICY_DEFAULTS.maxOutputTokensPerRequest>0);
});

const report={
  status:'passed',
  executed:executed.length,
  scenarios:executed,
  class:'Unit test of token accounting only; no provider was contacted',
  realG1Ran:false,
  providerAuthorised:false,
  completedAt:new Date().toISOString()
};
console.log(JSON.stringify(report,null,2));
process.exit(0);
