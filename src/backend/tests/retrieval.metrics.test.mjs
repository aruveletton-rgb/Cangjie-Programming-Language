import assert from 'node:assert/strict';
import {inspectGatewayMetadata, scoreAt5, summarizeGatewayExecution} from './retrieval.metrics.mjs';

// Counts are computed from what actually ran. Do not replace with literals:
// a hardcoded number would keep reporting the same value even if a case is deleted.
const executed=[];
function scenario(name,fn){ fn(); executed.push(name); }

let sixthOnly;
scenario('scoreAt5:rank-six-only',()=>{
  sixthOnly=scoreAt5(['GOLD'],[
    {evidenceId:'D1'},{evidenceId:'D2'},{evidenceId:'D3'},{evidenceId:'D4'},{evidenceId:'D5'},{evidenceId:'GOLD'}
  ]);
  assert.equal(sixthOnly.ids.length,6);
  assert.equal(sixthOnly.top5Ids.length,5);
  assert.equal(sixthOnly.hitAt5,false);
  assert.equal(sixthOnly.recallAt5,0);
});

let empty;
scenario('scoreAt5:empty-evidence',()=>{
  empty=scoreAt5(['GOLD'],[]);
  assert.equal(empty.hitAt5,false);
  assert.equal(empty.recallAt5,0);
});

let missingMode;
scenario('gatewayMetadata:missing-mode',()=>{
  missingMode=inspectGatewayMetadata({realG1Ran:false});
  assert.equal(missingMode.valid,false);
  assert.match(missingMode.error,/gatewayMode is missing/);
});

let mismatchedMode;
scenario('gatewayMetadata:contradictory-mode',()=>{
  mismatchedMode=inspectGatewayMetadata({gatewayMode:'G1',realG1Ran:false});
  assert.equal(mismatchedMode.valid,false);
  assert.match(mismatchedMode.error,/contradict/);
});

scenario('gatewayMetadata:valid-modes',()=>{
  assert.equal(inspectGatewayMetadata({gatewayMode:'G0',realG1Ran:false}).valid,true);
  assert.equal(inspectGatewayMetadata({gatewayMode:'MOCK',realG1Ran:false}).valid,true);
});

const row=(gatewayMode,realG1Ran,callStatus='succeeded')=>{
  const metadata=inspectGatewayMetadata({gatewayMode,realG1Ran});
  return {...metadata,gatewayMetadataValid:metadata.valid,callStatus};
};

// Scenario sets are declared once and reused for both execution and counting.
const notRunSets=[['G0'],[ 'MOCK']];
const observedSets=[[row('G1',true)],[row('G0',false),row('G1',true)]];
const unknownSets=[[],[row(undefined,false)],[row('G1',false)],[row('G0',false,'failed')]];

for(const modes of notRunSets)scenario('summary:not-run:'+modes.join('+'),()=>{
  const summary=summarizeGatewayExecution(modes.map(m=>row(m,false)));
  assert.equal(summary.g1.status,'not_run');
  assert.equal(summary.reportedG1CallCount,0);
  assert.equal(summary.realG1CallCount,0);
});

for(const rows of observedSets)scenario('summary:observed-unverified:'+rows.map(r=>r.gatewayMode).join('+'),()=>{
  const summary=summarizeGatewayExecution(rows);
  assert.equal(summary.g1.status,'observed_unverified');
  assert.equal(summary.reportedG1CallCount,1);
  assert.equal(summary.realG1CallCount,null);
  assert.equal(summary.g1.providerVerification,'not_performed');
});

for(const rows of unknownSets)scenario('summary:unknown:'+rows.map(r=>String(r.gatewayMode)+'/'+String(r.callStatus)).join('+'),()=>{
  const summary=summarizeGatewayExecution(rows);
  assert.equal(summary.g1.status,'unknown');
  assert.equal(summary.realG1CallCount,null);
  assert.equal(summary.g1.metadataCoverageComplete,false);
});

const summaryScenarios=notRunSets.length+observedSets.length+unknownSets.length;
if(summaryScenarios!==8)throw new Error(`expected 8 gateway summary scenarios, executed ${summaryScenarios}`);
if(executed.length!==5+summaryScenarios)throw new Error(`scenario counter mismatch: ${executed.length}`);

console.log(JSON.stringify({
  status:'passed',
  cases:executed.length,
  caseNames:executed,
  gatewaySummaryCases:summaryScenarios,
  gatewaySummaryCaseNames:executed.filter(n=>n.startsWith('summary:')),
  sixthOnly:{hitAt5:sixthOnly.hitAt5,recallAt5:sixthOnly.recallAt5},
  empty:{hitAt5:empty.hitAt5,recallAt5:empty.recallAt5},
  missingMode:missingMode.error,
  mismatchedMode:mismatchedMode.error
},null,2));
