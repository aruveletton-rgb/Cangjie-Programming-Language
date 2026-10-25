import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const output=process.env.ICT_TOP5_TEST_OUTPUT||path.resolve('audit/backend/retrieval-top5-counterexample.json');
const child=spawnSync(process.execPath,[path.join(here,'retrieval.development.mjs')],{
  cwd:process.cwd(),encoding:'utf8',env:{...process.env,ICT_TEST_FORCE_SIXTH_RANK_ONLY_HIT:'1',ICT_TEST_OUTPUT:output}
});
assert.equal(child.error,undefined,child.error?.message);
assert.equal(child.status,1,`rank-six-only positives must fail the quality gate; stderr: ${child.stderr}`);
const report=JSON.parse(fs.readFileSync(output,'utf8'));
assert.equal(report.executionStatus,'completed');
assert.equal(report.qualityStatus,'failed');
assert.equal(report.hitAt5,0);
assert.equal(report.recallAt5,0);
assert.ok(report.qualityFailures.some(x=>x.includes('hitAt5')));
assert.ok(report.qualityFailures.some(x=>x.includes('recallAt5')));
assert.equal(report.callFailures.length,0);
assert.equal(report.metadataFailures.length,0);
assert.equal(report.domainLeakCount,0);
assert.equal(report.deterministic,true);
assert.equal(report.results.filter(x=>x.gold.length).length,report.positiveQueryCount*report.rounds);
for(const positive of report.results.filter(x=>x.gold.length)){
  assert.equal(positive.ids.length,6);
  assert.equal(positive.ids[5],positive.gold[0]);
  assert.equal(positive.hit,false);
  assert.equal(positive.recall,0);
}
const row=report.results.find(x=>x.queryId==='K01'&&x.round===0);
assert.equal(row.ids.length,6);
assert.equal(row.ids[5],row.gold[0]);
assert.equal(row.top5Ids.length,5);
assert.equal(row.top5Ids.includes(row.gold[0]),false);
assert.equal(row.hit,false);
assert.equal(row.recall,0);
console.log(JSON.stringify({counterexampleStatus:'passed',expectedRunnerExitCode:1,actualRunnerExitCode:child.status,executionStatus:report.executionStatus,qualityStatus:report.qualityStatus,positiveResponses:report.positiveQueryCount*report.rounds,queryId:row.queryId,rankOfOnlyHit:6,top5Hit:row.hit,top5Recall:row.recall,aggregateHitAt5:report.hitAt5,aggregateRecallAt5:report.recallAt5},null,2));
