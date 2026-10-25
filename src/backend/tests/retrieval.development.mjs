import fs from 'node:fs';
import path from 'node:path';
import {performance} from 'node:perf_hooks';
import {inspectGatewayMetadata, scoreAt5, summarizeGatewayExecution} from './retrieval.metrics.mjs';
const base=process.env.ICT_BASE_URL||'http://127.0.0.1:38082';
const forceEmptyPositive=process.env.ICT_TEST_FORCE_EMPTY_POSITIVE==='1';
const forceSixthRankOnlyHit=process.env.ICT_TEST_FORCE_SIXTH_RANK_ONLY_HIT==='1';
const gatewayMetadataFault=process.env.ICT_TEST_GATEWAY_METADATA_FAULT||'';
const input=new URL('../../data/queries.development.json',import.meta.url);
const bytes=fs.readFileSync(input),queries=JSON.parse(bytes).queries;
const output=process.env.ICT_TEST_OUTPUT||path.resolve('audit/backend/retrieval-result.json');
const results=[];
const callFailures=[];
const metadataFailures=[];
for(let round=0;round<3;round++)for(const q of queries){
  const start=performance.now();
  let r,value;
  try {
    r=await fetch(base+'/api/v1/chat',{method:'POST',headers:{'Content-Type':'application/json','X-Demo-Session':q.session},body:JSON.stringify({requestId:`dev-${Date.now()}-${round}-${q.id}`,text:q.text})});
    value=await r.json();
  } catch (error) {
    callFailures.push(`${q.id} round ${round+1}: ${error.message}`);
    value={};
  }
  const data=value?.data;
  const callStatus=r&&r.ok&&value?.code==='OK'?'succeeded':'failed';
  if(callStatus==='failed')callFailures.push(`${q.id} round ${round+1}: HTTP ${r?.status??'unavailable'}, code ${value?.code??'unavailable'}`);
  // These test-only response mutations exercise evaluator counterexamples; production calls are read as returned.
  let refs=Array.isArray(data?.evidenceRefs)?data.evidenceRefs:[];
  if(forceEmptyPositive&&q.gold.length)refs=[];
  if(forceSixthRankOnlyHit&&q.gold.length)refs=[...Array.from({length:5},(_,i)=>({evidenceId:`DISTRACTOR_${i+1}`,domainId:q.session==='campus-user'?'campus-demo':'community-demo'})),{evidenceId:q.gold[0],domainId:q.session==='campus-user'?'campus-demo':'community-demo'}];
  const score=scoreAt5(q.gold,refs);
  let metadataData=data;
  if(data&&gatewayMetadataFault==='missing')metadataData={...data,gatewayMode:undefined};
  if(data&&gatewayMetadataFault==='mismatch')metadataData={...data,gatewayMode:'G1',realG1Ran:false};
  const mode=inspectGatewayMetadata(metadataData);
  if(!mode.valid)metadataFailures.push(`${q.id} round ${round+1}: ${mode.error}`);
  const domain=q.session==='campus-user'?'campus-demo':'community-demo';
  results.push({queryId:q.id,round,session:q.session,text:q.text,gold:q.gold,ids:score.ids,top5Ids:score.top5Ids,recall:score.recallAt5,hit:score.hitAt5,correctNoEvidence:score.correctNoEvidence,domainLeak:refs.some(x=>x.domainId!==domain),ms:performance.now()-start,httpStatus:r?.status??null,apiCode:value?.code??null,callStatus,gatewayMode:mode.gatewayMode,realG1Ran:mode.realG1Ran,providerAuthorised:data?.providerAuthorised===true,usage:data?.usage??null,gatewayMetadataValid:mode.valid,gatewayMetadataError:mode.error,answerStatus:data?.answerStatus??null,datasetVersion:data?.datasetVersion??null});
}
const positive=results.filter(x=>x.recall!==null),negative=results.filter(x=>x.recall===null);
const times=results.map(x=>x.ms).sort((a,b)=>a-b),quantile=p=>times[Math.ceil(times.length*p)-1];
const deterministic=queries.every(q=>new Set(results.filter(x=>x.queryId===q.id).map(x=>JSON.stringify(x.ids))).size===1);
const recallAt5=positive.length?positive.reduce((a,x)=>a+x.recall,0)/positive.length:0;
const hitAt5=positive.length?positive.filter(x=>x.hit).length/positive.length:0;
const noEvidenceCorrect=negative.length?negative.filter(x=>x.correctNoEvidence).length/negative.length:0;
const qualityFailures=[];
if(positive.length===0)qualityFailures.push('No positive development queries were evaluated');
if(callFailures.length)qualityFailures.push('One or more API calls failed');
if(metadataFailures.length)qualityFailures.push('One or more responses have missing or contradictory gateway metadata');
if(hitAt5<0.8)qualityFailures.push('hitAt5 is below the predeclared 0.80 minimum');
if(recallAt5<0.8)qualityFailures.push('recallAt5 is below the predeclared 0.80 minimum');
if(negative.length&&noEvidenceCorrect<0.75)qualityFailures.push('noEvidenceCorrect is below the predeclared 0.75 minimum');
if(results.some(x=>x.domainLeak))qualityFailures.push('Evidence crossed a data-domain boundary');
if(!deterministic)qualityFailures.push('Repeated query results were not deterministic');
const observedModes=[...new Set(results.map(x=>x.gatewayMode).filter(x=>x!==null))].sort();
const answerStatuses=Object.fromEntries([...new Set(results.map(x=>x.answerStatus).filter(x=>x!==null))].sort().map(status=>[status,results.filter(x=>x.answerStatus===status).length]));
// usage is recorded per response so tests/g1.accounting.mjs can bill a real G1 run.
// G0 returns a usage object with all-zero counters (not null) — the field is present but
// contributes nothing to billing. usageFieldMissing catches the real defect: a record
// whose usage is neither null nor a numeric totalTokens.
const usageRecorded=results.filter(x=>x.usage!==null).length;
const usageFieldMissing=results.filter(x=>!(x.usage===null||(x.usage&&typeof x.usage.totalTokens==='number'))).length;
const report={status:qualityFailures.length?'failed':'passed',executionStatus:callFailures.length?'failed':'completed',qualityStatus:qualityFailures.length?'failed':'passed',qualityFailures,callFailures,metadataFailures,qualityGate:{positiveHitAt5Minimum:0.8,positiveRecallAt5Minimum:0.8,noEvidenceCorrectMinimum:0.75,domainLeakMaximum:0,deterministicRequired:true},class:'Development benchmark; self-authored labels; not blind evaluation; no AI gain',queryCount:queries.length,positiveQueryCount:queries.filter(q=>q.gold.length>0).length,negativeQueryCount:queries.filter(q=>q.gold.length===0).length,rounds:3,responseCount:results.length,recallAt5,hitAt5,noEvidenceCorrect,domainLeakCount:results.filter(x=>x.domainLeak).length,deterministic,observedGatewayModes:observedModes,...summarizeGatewayExecution(results),usageRecorded,usageFieldMissing,answerStatuses,callStatusCounts:{succeeded:results.filter(x=>x.callStatus==='succeeded').length,failed:results.filter(x=>x.callStatus==='failed').length},p50Ms:quantile(.5),p95Ms:quantile(.95),answerQuality:{status:'not_independently_assessed',reason:'Deterministic evidence excerpts are checked structurally; no human quality score claimed'},results,completedAt:new Date().toISOString()};
fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2));console.log(JSON.stringify({...report,results:undefined},null,2));
process.exitCode=report.status==='passed'?0:1;
