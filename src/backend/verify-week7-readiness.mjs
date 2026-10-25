import fs from 'node:fs';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';

// Resolve against this script, so running outside the workspace cannot validate another tree accidentally.
const workspace=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const ledgerPath=path.resolve(process.argv[2]||path.join(workspace,'docs/backend/week7_readiness.json'));
const stamp=new Date().toLocaleString('sv-SE',{timeZone:'Asia/Shanghai'}).replace(/[-: ]/g,'');
// Batch callers (for example the 25-case regression) set ICT_READINESS_AUDIT_DIR so a whole
// batch writes into one directory instead of creating one audit folder per invocation.
const auditOverride=process.env.ICT_READINESS_AUDIT_DIR;
const audit=auditOverride?path.resolve(workspace,auditOverride):path.join(workspace,'audit/backend',`week7_readiness_${stamp}_${process.pid}`);
if(!audit.startsWith(workspace+path.sep)){throw new Error(`ICT_READINESS_AUDIT_DIR must stay inside the workspace: ${auditOverride}`);}
fs.mkdirSync(audit,{recursive:true});
const failures=[];
const sha=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
function boundFile(relative,expectedHash,label,base=workspace){
  if(typeof relative!=='string'||!relative||! /^[a-f0-9]{64}$/i.test(expectedHash||'')){failures.push(`Invalid file/hash binding: ${label}`);return null;}
  const file=path.resolve(base,relative);
  if(!file.startsWith(workspace+path.sep)||!fs.existsSync(file)||!fs.statSync(file).isFile()){failures.push(`Bound file missing/outside workspace: ${label}`);return null;}
  if(sha(file).toLowerCase()!==expectedHash.toLowerCase())failures.push(`Bound file hash mismatch: ${label}`);
  return file;
}
function verifyManifest(entries,label){
  if(!Array.isArray(entries)||!entries.length){failures.push(`Missing nonempty manifest: ${label}`);return;}
  for(const entry of entries)boundFile(entry?.file,entry?.sha256,`${label}: ${entry?.file}`);
}
let ledger;
try{ledger=JSON.parse(fs.readFileSync(ledgerPath,'utf8').replace(/^\uFEFF/,''));}catch(e){failures.push(`Ledger unreadable: ${e.message}`);}
const evidence=new Map();
const reports=new Map();
for(const item of ledger?.evidence||[]){
  if(evidence.has(item.id))failures.push(`Duplicate evidence: ${item.id}`);
  evidence.set(item.id,item);
  const file=path.resolve(workspace,item.path);
  if(!file.startsWith(workspace+path.sep)||!fs.existsSync(file)){failures.push(`Evidence missing/outside workspace: ${item.id}`);continue;}
  if(sha(file)!==item.sha256)failures.push(`Evidence hash mismatch: ${item.id}`);
  if(['backend_verification','codearts_platform'].includes(item.kind)){
    let report;
    try{report=JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));}catch(error){failures.push(`Evidence JSON unreadable: ${item.id}: ${error.message}`);continue;}
    if(!report||typeof report!=='object'||Array.isArray(report)){failures.push(`Evidence report must be an object: ${item.id}`);continue;}
    reports.set(item.id,report);
    if(item.kind==='backend_verification'){
      if(report.status!=='passed_local_a_followup'||report.exitCode!==0||!Array.isArray(report.steps)||!report.steps.length||report.steps.some(s=>s.exitCode!==0))failures.push(`Backend verification not passed: ${item.id}`);
      verifyManifest(report.sourceManifest,`${item.id} sourceManifest`);
      verifyManifest(report.evidenceManifest,`${item.id} evidenceManifest`);
    }else{
      if(!['Resolved','Closed'].includes(report.platformStatus))failures.push(`CodeArts task is not resolved/closed: ${item.id}`);
      if(!report.platformTaskId||!report.projectId)failures.push(`CodeArts task/project ID missing: ${item.id}`);
      const expectedUrl=`https://devcloud.cn-north-4.huaweicloud.com/projectman/scrum/${report.projectId}/task/detail/${report.platformTaskId}`;
      if(report.url!==expectedUrl)failures.push(`CodeArts task URL does not match task/project ID: ${item.id}`);
      boundFile(report.screenshot,item.screenshotSha256,`${item.id} screenshot`,path.dirname(file));
    }
  }
  if(item.kind==='environment'){
    const report=JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
    if(report.executionStatus!=='completed'||!report.configurationUnchanged||report.steps.some(s=>s.exitCode!==0))failures.push(`Environment inspection not successfully executed: ${item.id}`);
    if(sha(path.join(workspace,'src/mobile/inspect-environment.ps1')).toUpperCase()!==report.scriptSha256.toUpperCase())failures.push('Environment report does not bind current inspector source');
  }
  if(item.kind==='native_build'){
    const report=JSON.parse(fs.readFileSync(file,'utf8').replace(/^\uFEFF/,''));
    if(report.status!=='passed'||report.steps.length!==3||report.steps.some(s=>s.exitCode!==0))failures.push(`Native build not successful: ${item.id}`);
    for(const ext of ['.hap','.app'])if(!report.products.some(p=>p.path.endsWith(ext)&&p.size>0))failures.push(`Native build missing ${ext}`);
    for(const product of report.products){if(!fs.existsSync(product.path)||sha(product.path).toUpperCase()!==product.sha256.toUpperCase())failures.push(`Build product changed/missing: ${product.path}`);}
    const manifest=JSON.parse(fs.readFileSync(path.join(path.dirname(file),'source-copy.json'),'utf8').replace(/^\uFEFF/,''));
    for(const entry of manifest){const source=path.join(workspace,'src/mobile',entry.path);if(!fs.existsSync(source)||sha(source).toUpperCase()!==entry.sha256.toUpperCase())failures.push(`Build does not bind current source: ${entry.path}`);}
  }
}
for(const task of ledger?.tasks||[]){
  if(!['complete','blocked','needs_fix'].includes(task.status))failures.push(`Invalid task status: ${task.id}`);
  if(!task.ownerRole||!task.nextAction)failures.push(`Missing task responsibility/next action: ${task.id}`);
  if(task.status==='complete'&&!task.evidenceIds?.length)failures.push(`Completed task has no evidence: ${task.id}`);
  for(const id of task.evidenceIds||[])if(!evidence.has(id))failures.push(`Unknown evidence ${id} for ${task.id}`);
  if(task.status==='blocked'&&!task.blocker)failures.push(`Blocked task has no blocker: ${task.id}`);
  if(task.id==='C-CODEARTS'&&task.status==='complete'){
    if(!task.platformTaskId||!task.evidenceIds?.some(id=>evidence.get(id)?.kind==='codearts_platform'))failures.push('CodeArts completion requires a real platform task ID and platform evidence');
    for(const id of (task.evidenceIds||[]).filter(id=>evidence.get(id)?.kind==='codearts_platform')){
      const report=reports.get(id);
      if(!report||report.platformTaskId!==task.platformTaskId||!task.platformProjectId||report.projectId!==task.platformProjectId)failures.push(`CodeArts task/project ID mismatch with ledger: ${task.id}`);
    }
  }
  if(['A-01','A-02'].includes(task.id)&&task.status==='complete'&&!task.evidenceIds?.some(id=>evidence.get(id)?.kind==='backend_verification'&&reports.get(id)?.findings?.some(f=>f.id===task.id&&f.status==='fixed_verified')))failures.push(`A completion lacks corresponding verified finding: ${task.id}`);
  const requiredKind={'A-01':'backend_verification','A-02':'backend_verification','B-ENV':'environment','B-BUILD':'native_build','B-DEVICE':'device_validation'}[task.id];
  if(task.status==='complete'&&requiredKind&&!task.evidenceIds?.some(id=>evidence.get(id)?.kind===requiredKind))failures.push(`Task lacks ${requiredKind} evidence: ${task.id}`);
}
for(const resource of ledger?.resources||[]){
  if(!resource.ownerRole||!resource.nextAction)failures.push(`Resource lacks coordination owner/action: ${resource.id}`);
  if(resource.status==='ready'&&(!resource.ownerConfirmed||!resource.actualOwner||!resource.evidenceIds?.some(id=>['resource_authorization','device_validation','codearts_platform'].includes(evidence.get(id)?.kind))))failures.push(`Ready resource lacks confirmed owner and authorization/device/platform evidence: ${resource.id}`);
}
if(!ledger?.tasks?.length||!ledger?.resources?.length||!ledger?.evidence?.length)failures.push('Tasks, resources and evidence must be nonempty');
const pendingTasks=(ledger?.tasks||[]).filter(t=>t.status!=='complete').map(t=>t.id);
const pendingResources=(ledger?.resources||[]).filter(r=>r.status!=='ready').map(r=>r.id);
const result={generatedAt:new Date().toISOString(),acceptanceScope:'A/B/C execution and recorded evidence only; schedule dates and review milestones excluded. Offline platform evidence does not replace live website verification.',command:`node src/backend/verify-week7-readiness.mjs ${path.relative(workspace,ledgerPath)}`,ledgerPath,ledgerSha256:fs.existsSync(ledgerPath)?sha(ledgerPath):null,verificationStatus:failures.length?'failed':'passed',week7Acceptance:failures.length?'invalid_evidence':pendingTasks.length||pendingResources.length?'partial_with_blockers':'complete',pendingTasks,pendingResources,failures,exitCode:failures.length?1:0,auditDirectory:audit};
fs.writeFileSync(path.join(audit,'result.json'),JSON.stringify(result,null,2));
fs.writeFileSync(path.join(audit,'result.md'),`# 第7周任务与资源证据校验\n\n证据校验：${result.verificationStatus}；第7周验收：${result.week7Acceptance}。\n\n命令：\`${result.command}\`；退出码：${result.exitCode}。\n\n时间：${result.generatedAt}\n\n待关闭任务：${pendingTasks.join(', ')}\n\n待落实资源：${pendingResources.join(', ')}\n\n${failures.map(f=>'- '+f).join('\n')}\n`);
console.log(JSON.stringify(result,null,2));process.exitCode=result.exitCode;
