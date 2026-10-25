import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const runner=path.join(here,'retrieval.development.mjs');
const outputBase=process.env.ICT_TEST_OUTPUT||path.resolve('audit/backend/retrieval-gateway-metadata-counterexample.json');
for(const fault of ['missing','mismatch']){
  const output=path.join(path.dirname(outputBase),`retrieval.gateway-${fault}-counterexample.json`);
  const child=spawnSync(process.execPath,[runner],{
    cwd:process.cwd(),encoding:'utf8',env:{...process.env,ICT_TEST_GATEWAY_METADATA_FAULT:fault,ICT_TEST_OUTPUT:output}
  });
  assert.equal(child.error,undefined,child.error?.message);
  assert.equal(child.status,1,`${fault} metadata should fail the quality gate; stderr: ${child.stderr}`);
  const report=JSON.parse(fs.readFileSync(output,'utf8'));
  assert.equal(report.qualityStatus,'failed');
  assert.ok(report.metadataFailures.length>0);
  assert.ok(report.qualityFailures.some(x=>x.includes('gateway metadata')));
  if(fault==='missing'){
    assert.equal(report.results[0].gatewayMode,null);
    assert.equal(report.results[0].gatewayMetadataValid,false);
  }else{
    assert.equal(report.results[0].gatewayMode,'G1');
    assert.equal(report.results[0].realG1Ran,false);
    assert.equal(report.results[0].gatewayMetadataValid,false);
  }
  console.log(JSON.stringify({counterexampleStatus:'passed',fault,runnerExitCode:child.status,qualityStatus:report.qualityStatus,metadataFailureCount:report.metadataFailures.length,firstGatewayMode:report.results[0].gatewayMode,firstRealG1Ran:report.results[0].realG1Ran},null,2));
}
