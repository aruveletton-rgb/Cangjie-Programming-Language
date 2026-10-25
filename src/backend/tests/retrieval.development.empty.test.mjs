import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const runner=path.join(here,'retrieval.development.mjs');
const output=process.env.ICT_EMPTY_TEST_OUTPUT||process.env.ICT_TEST_OUTPUT||path.resolve('audit/backend/retrieval-empty-result.json');
const child=spawnSync(process.execPath,[runner],{
  cwd:process.cwd(),
  encoding:'utf8',
  env:{...process.env,ICT_TEST_FORCE_EMPTY_POSITIVE:'1',ICT_TEST_OUTPUT:output}
});
assert.equal(child.error,undefined,child.error?.message);
assert.equal(child.status,1,`expected quality-gate failure (exit 1), got ${child.status}; stderr: ${child.stderr}`);
const report=JSON.parse((await import('node:fs')).readFileSync(output,'utf8'));
assert.equal(report.executionStatus,'completed');
assert.equal(report.qualityStatus,'failed');
assert.equal(report.hitAt5,0);
assert.equal(report.recallAt5,0);
assert.ok(report.qualityFailures.some(x=>x.includes('hitAt5')));
console.log(JSON.stringify({counterexampleStatus:'passed',expectedRunnerExitCode:1,actualRunnerExitCode:child.status,executionStatus:report.executionStatus,qualityStatus:report.qualityStatus,hitAt5:report.hitAt5,recallAt5:report.recallAt5,queryCount:report.queryCount,rounds:report.rounds},null,2));
