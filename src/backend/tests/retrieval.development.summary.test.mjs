import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const here=path.dirname(fileURLToPath(import.meta.url));
const queries=JSON.parse(fs.readFileSync(new URL('../../data/queries.development.json',import.meta.url),'utf8')).queries;
const outputBase=process.env.ICT_TEST_OUTPUT||path.resolve('audit/backend/retrieval-summary-fixtures.json');
fs.mkdirSync(path.dirname(outputBase),{recursive:true});
let scenario='G0',calls=0;
const server=http.createServer(async(req,res)=>{
  let body='';for await(const chunk of req)body+=chunk;
  const q=queries.find(q=>q.text===JSON.parse(body).text&&q.session===req.headers['x-demo-session']);
  const mode=scenario==='mixed'?(calls++%2?'G1':'G0'):scenario==='G1'?'G1':scenario==='MOCK'?'MOCK':'G0';
  const data={evidenceRefs:q.gold.map(evidenceId=>({evidenceId,domainId:q.session==='campus-user'?'campus-demo':'community-demo'})),gatewayMode:mode,realG1Ran:mode==='G1',answerStatus:'FIXTURE_ONLY',datasetVersion:'local-summary-fixture-only'};
  if(scenario==='missing')delete data.gatewayMode;
  if(scenario==='mismatch'){data.gatewayMode='G1';data.realG1Ran=false;}
  res.writeHead(scenario==='http-failed'?503:200,{'Content-Type':'application/json'}).end(JSON.stringify({code:scenario==='http-failed'?'FIXTURE_FAILURE':'OK',data,traceId:'local-fixture'}));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const runs=[];
try{
  for(scenario of ['G0','MOCK','G1','mixed','missing','mismatch','http-failed']){
    calls=0;
    const output=path.join(path.dirname(outputBase),`retrieval.summary-${scenario}.json`);
    const child=spawn(process.execPath,[path.join(here,'retrieval.development.mjs')],{windowsHide:true,env:{...process.env,ICT_BASE_URL:`http://127.0.0.1:${server.address().port}`,ICT_TEST_FORCE_EMPTY_POSITIVE:'0',ICT_TEST_FORCE_SIXTH_RANK_ONLY_HIT:'0',ICT_TEST_GATEWAY_METADATA_FAULT:'',ICT_TEST_OUTPUT:output}});
    let stdout='',stderr='';child.stdout.on('data',x=>stdout+=x);child.stderr.on('data',x=>stderr+=x);
    const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',resolve);});
    fs.writeFileSync(output+'.log',stdout+'\n'+stderr);
    const report=JSON.parse(fs.readFileSync(output,'utf8'));
    const invalid=['missing','mismatch','http-failed'].includes(scenario);
    assert.equal(code,invalid?1:0,stderr);
    assert.equal(report.responseCount,queries.length*3);
    const reported=scenario==='G1'?report.responseCount:scenario==='mixed'?report.responseCount/2:0;
    assert.equal(report.reportedG1CallCount,reported);
    assert.equal(report.g1.status,invalid?'unknown':reported?'observed_unverified':'not_run');
    assert.equal(report.realG1CallCount,invalid||reported?null:0);
    assert.equal(report.g1.providerVerification,'not_performed');
    assert.equal(report.g1.metadataCoverageComplete,!invalid);
    runs.push({scenario,runnerExitCode:code,expectedRunnerExitCode:invalid?1:0,g1:report.g1,reportedG1CallCount:reported,realG1CallCount:report.realG1CallCount,output});
  }
}finally{await new Promise(resolve=>server.close(resolve));}
const summary={status:'passed',class:'Local HTTP fixtures only; G1 labels are simulated, no provider/model call.',runs,completedAt:new Date().toISOString()};
fs.writeFileSync(outputBase,JSON.stringify(summary,null,2));
console.log(JSON.stringify(summary,null,2));
