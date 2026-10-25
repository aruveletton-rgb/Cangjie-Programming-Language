import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../..');
const read=file=>JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
const base=read(path.join(root,'docs/backend/week7_readiness.json'));
const stamp=new Date().toLocaleString('sv-SE',{timeZone:'Asia/Shanghai'}).replace(/[-: ]/g,'')+'_'+process.pid;
const fixture=path.join(root,'temp/backend',`week7_c_validation_${stamp}`);
const audit=path.join(root,'audit/backend',`week7_c_validation_${stamp}`);
fs.mkdirSync(fixture,{recursive:true});fs.mkdirSync(audit,{recursive:true});
function alterProof(ledger,id,name,mutate){
  const entry=ledger.evidence.find(e=>e.id===id);
  const originalPath=path.resolve(root,entry.path),proof=read(originalPath);
  if(id==='C-PLATFORM')proof.screenshot=path.relative(fixture,path.join(path.dirname(originalPath),proof.screenshot));
  mutate(proof);
  const file=path.join(fixture,name+'-proof.json');fs.writeFileSync(file,JSON.stringify(proof,null,2));
  entry.path=path.relative(root,file);entry.sha256=createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}
const changeA=(name,mutate)=>l=>alterProof(l,'A-FOLLOWUP',name,mutate);
const changeC=(name,mutate)=>l=>alterProof(l,'C-PLATFORM',name,mutate);
const cases=[
  ['actual-ledger',()=>{},0,null],
  ['schedule-not-an-acceptance-condition',l=>{l.resources[0].resolutionDueDate='unconfirmed fixture';l.tasks[0].targetReviewDate='ignored fixture';},0,null],
  ['wrong-outer-hash',l=>l.evidence[0].sha256='0'.repeat(64),1,'Evidence hash mismatch'],
  ['stale-a-source-manifest',changeA('stale-a-source-manifest',p=>p.sourceManifest[0].sha256='0'.repeat(64)),1,'sourceManifest'],
  ['stale-a-evidence-manifest',changeA('stale-a-evidence-manifest',p=>p.evidenceManifest[0].sha256='0'.repeat(64)),1,'evidenceManifest'],
  ['missing-a-source-file',changeA('missing-a-source-file',p=>p.sourceManifest[0].file='temp/backend/does-not-exist-week7.cj'),1,'missing/outside workspace'],
  ['source-outside-workspace',changeA('source-outside-workspace',p=>p.sourceManifest[0].file='../outside-week7.cj'),1,'missing/outside workspace'],
  ['empty-a-source-manifest',changeA('empty-a-source-manifest',p=>p.sourceManifest=[]),1,'nonempty manifest'],
  ['empty-a-evidence-manifest',changeA('empty-a-evidence-manifest',p=>p.evidenceManifest=[]),1,'nonempty manifest'],
  ['failed-a-report',changeA('failed-a-report',p=>p.status='failed'),1,'Backend verification not passed'],
  ['failed-a-step',changeA('failed-a-step',p=>p.steps[0].exitCode=1),1,'Backend verification not passed'],
  ['unverified-a-finding',changeA('unverified-a-finding',p=>p.findings[0].status='open'),1,'corresponding verified finding'],
  ['a-without-backend-proof',l=>l.tasks.find(t=>t.id==='A-01').evidenceIds=['AUDIT'],1,'backend_verification'],
  ['mismatched-codearts-task',changeC('mismatched-codearts-task',p=>{p.platformTaskId='00000000';p.platformStatus='New';}),1,'CodeArts task/project ID mismatch'],
  ['task-id-only-mismatch',changeC('task-id-only-mismatch',p=>{p.platformTaskId='00000000';p.url=p.url.replace('71191393','00000000');}),1,'CodeArts task/project ID mismatch'],
  ['project-id-only-mismatch',changeC('project-id-only-mismatch',p=>{p.url=p.url.replace(p.projectId,'other-project');p.projectId='other-project';}),1,'CodeArts task/project ID mismatch'],
  ['new-platform-status',changeC('new-platform-status',p=>p.platformStatus='New'),1,'not resolved/closed'],
  ['wrong-platform-url',changeC('wrong-platform-url',p=>p.url='https://example.invalid/task/71191393'),1,'URL does not match'],
  ['wrong-screenshot-hash',l=>l.evidence.find(e=>e.id==='C-PLATFORM').screenshotSha256='0'.repeat(64),1,'screenshot'],
  ['missing-screenshot-hash',l=>delete l.evidence.find(e=>e.id==='C-PLATFORM').screenshotSha256,1,'Invalid file/hash binding'],
  ['missing-screenshot',changeC('missing-screenshot',p=>p.screenshot='missing-week7-proof.png'),1,'screenshot'],
  ['missing-platform-task-id',l=>delete l.tasks.find(t=>t.id==='C-CODEARTS').platformTaskId,1,'real platform task ID'],
  ['missing-platform-proof',l=>l.tasks.find(t=>t.id==='C-CODEARTS').evidenceIds=['B-ENV'],1,'real platform task ID'],
  ['fake-device-completion',l=>l.tasks.find(t=>t.id==='B-DEVICE').status='complete',1,'device_validation'],
  ['unconfirmed-resources-ready',l=>l.resources.forEach(r=>r.status='ready'),1,'confirmed owner']
];
const runs=[];
// One batch directory for all child verifications instead of one audit folder per case.
const readinessAudit=path.join(audit,'readiness');
const childEnv={...process.env,ICT_READINESS_AUDIT_DIR:path.relative(root,readinessAudit)};
for(const [name,mutate,expectedExitCode,error] of cases){
  const ledger=structuredClone(base);mutate(ledger);
  const file=path.join(fixture,name+'.json');fs.writeFileSync(file,JSON.stringify(ledger,null,2));
  const startedAt=new Date().toISOString();
  const child=spawnSync(process.execPath,[path.join(root,'src/backend/verify-week7-readiness.mjs'),file],{cwd:fixture,windowsHide:true,encoding:'utf8',env:childEnv});
  fs.writeFileSync(path.join(audit,name+'.log'),child.stdout+'\n'+child.stderr);
  assert.equal(child.error,undefined,child.error?.message);
  assert.equal(child.status,expectedExitCode,`${name}: expected ${expectedExitCode}; ${child.stdout}\n${child.stderr}`);
  const report=JSON.parse(child.stdout);
  if(error)assert(report.failures.some(f=>f.includes(error)),`${name}: expected ${error}`);
  runs.push({name,command:`node src/backend/verify-week7-readiness.mjs ${file}`,startedAt,completedAt:new Date().toISOString(),expectedExitCode,actualExitCode:child.status,assertion:'passed',expectedError:error,failures:report.failures,receipt:report.auditDirectory});
}
const result={generatedAt:new Date().toISOString(),status:'passed',cases:runs.length,positiveCases:runs.filter(r=>r.expectedExitCode===0).length,negativeCases:runs.filter(r=>r.expectedExitCode===1).length,class:'Local copied ledger/proof fixtures; no real source, platform, device or model mutations.',fixtureDirectory:fixture,auditDirectory:audit,runs};
fs.writeFileSync(path.join(audit,'result.json'),JSON.stringify(result,null,2));
fs.writeFileSync(path.join(audit,'result.md'),`# C线程证据校验回归\n\n状态：${result.status}；${result.cases}项通过（${result.positiveCases}正例，${result.negativeCases}反例）。\n\n所有调用从工作区外的任务临时目录启动。\n\n| 用例 | 预期退出码 | 实际退出码 |\n|---|---:|---:|\n${runs.map(r=>`| ${r.name} | ${r.expectedExitCode} | ${r.actualExitCode} |`).join('\n')}\n`);
console.log(JSON.stringify(result,null,2));
