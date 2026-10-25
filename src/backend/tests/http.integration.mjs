import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';
import { performance } from 'node:perf_hooks';

const base = process.env.ICT_BASE_URL || 'http://127.0.0.1:38082';
const output = process.env.ICT_TEST_OUTPUT || path.resolve('audit/backend/http-result.json');
const records = [];
const run = Date.now().toString(36);
let counter = 0;
const rid = () => `test-${run}-${++counter}`;
let ticket;
let submission;
let submissionKey;
let draft;
let confirmation;
let signupFixture;
const requests = [];

async function api(method, endpoint, body, session = 'campus-user', extra = {}) {
  const headers = { 'Content-Type': 'application/json', ...extra };
  if (session) headers['X-Demo-Session'] = session;
  const start = performance.now();
  const response = await fetch(base + endpoint, {method, headers, body: body === undefined ? undefined : JSON.stringify(body)});
  const value = await response.json();
  requests.push({method,endpoint,session,status:response.status,traceId:value.traceId,code:value.code});
  assert.equal(typeof value.traceId, 'string');
  assert.equal(value.data.synthetic, true);
  assert.equal(value.data.realBusinessWrite, false);
  return { status: response.status, value, ms: performance.now() - start, headers: Object.fromEntries(response.headers) };
}
const ok = response => { assert.equal(response.value.code, 'OK', JSON.stringify(response.value)); assert.equal(response.status, 200); return response.value.data; };
const error = (response, code, status) => { assert.equal(response.value.code, code, JSON.stringify(response.value)); if (status) assert.equal(response.status, status); };
async function test(name, fn) {
  const start = performance.now();
  try { const detail = await fn(); records.push({name, passed:true, ms:performance.now()-start, detail}); console.log(`PASS ${name}`); }
  catch (e) { records.push({name,passed:false,ms:performance.now()-start,error:e.stack}); console.log(`FAIL ${name}: ${e.message}`); }
  fs.mkdirSync(path.dirname(output),{recursive:true});
  fs.writeFileSync(output,JSON.stringify({status:'running',base,records},null,2));
}
async function make(kind = 'ticket', fields = {}, session = 'campus-user') {
  const p = kind === 'ticket' ? 'ticket-drafts' : kind === 'lost' ? 'lost-item-drafts' : 'activity-signup-drafts';
  const defaults = kind === 'ticket' ? {location:'公共区域走廊',description:'合成灯具损坏',contactAlias:'SYN-CONTACT-K'} :
    kind === 'lost' ? {kind:'lost',itemDescription:'合成水杯',location:'图书馆',occurredOn:'2026-10-12',contactAlias:'SYN-CONTACT-K'} :
    {activityId:'campus-demo-activity-001',session:'morning',contactAlias:'SYN-CONTACT-K'};
  const d = ok(await api('POST',`/api/v1/${p}`,{requestId:rid(),...defaults,...fields},session));
  const c = ok(await api('POST',`/api/v1/${p}/${d.draftId}/confirm`,{requestId:rid(),revision:d.revision},session));
  return {d,c,body:{requestId:rid(),draftId:d.draftId,confirmationId:c.confirmationId},key:rid()};
}

await test('health / static demo identity / flags', async()=>ok(await api('GET','/health',undefined,'')));
await test('missing and unknown sessions rejected',async()=>{
  error(await api('GET','/api/v1/notices',undefined,''),'UNAUTHORIZED',401);
  error(await api('GET','/api/v1/notices',undefined,'not-a-session'),'UNAUTHORIZED',401);
});
await test('JSON / fields / text bounds / content type / body forgery',async()=>{
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:42}),'VALIDATION_ERROR',400);
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:' '}),'VALIDATION_ERROR',400);
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:'x'.repeat(8001)}),'VALIDATION_ERROR',400);
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:'x'.repeat(33000)}),'VALIDATION_ERROR',400);
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:'报修',domainId:'community-demo'}),'FORBIDDEN',403);
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:'报修',userId:'worker-syn-campus-001'}),'FORBIDDEN',403);
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:'报修',roles:['staff']}),'FORBIDDEN',403);
  error(await api('GET','/api/v1/notices?domainId=community-demo'),'FORBIDDEN',403);
  const r = await fetch(base+'/api/v1/chat',{method:'POST',headers:{'X-Demo-Session':'campus-user','Content-Type':'application/json'},body:'{"'});
  assert.equal((await r.json()).code,'VALIDATION_ERROR');
  error(await api('POST','/api/v1/chat',{requestId:rid(),text:'报修'},'campus-user',{'Content-Type':'text/plain'}),'VALIDATION_ERROR',400);
});
await test('notice and schedule isolation / empty and illegal filters',async()=>{
  const k=ok(await api('GET','/api/v1/notices'));
  const m=ok(await api('GET','/api/v1/notices',undefined,'community-user'));
  assert(k.items.every(x=>x.domainId==='campus-demo')); assert(m.items.every(x=>x.domainId==='community-demo'));
  assert.equal(ok(await api('GET','/api/v1/schedule')).items.length,2);
  assert.equal(ok(await api('GET','/api/v1/schedule?kind=exam')).items.length,1);
  assert.equal(ok(await api('GET','/api/v1/schedule?date=2000-01-01')).items.length,0);
  error(await api('GET','/api/v1/schedule?kind=bad'),'VALIDATION_ERROR',400);
  error(await api('GET','/api/v1/schedule?date=invalid'),'VALIDATION_ERROR',400);
  error(await api('GET','/api/v1/schedule',undefined,'community-user'),'FORBIDDEN',403);
});
await test('pre-retrieval role / area / expired / unknown filter',async()=>{
  const user=ok(await api('POST','/api/v1/chat',{requestId:rid(),text:'龙舟秘笈'}));
  assert.equal(user.evidenceRefs.length,0); assert.equal(user.answerStatus,'CLARIFICATION_REQUIRED');
  const weak=ok(await api('POST','/api/v1/chat',{requestId:rid(),text:'银河穿越许可证'}));
  assert.equal(weak.evidenceRefs.length,0);assert.equal(weak.answerStatus,'CLARIFICATION_REQUIRED');
  const staff=ok(await api('POST','/api/v1/chat',{requestId:rid(),text:'龙舟秘笈'},'campus-worker'));
  assert.equal(staff.evidenceRefs.length,1); assert.equal(staff.evidenceRefs[0].evidenceId,'K_GUARD_staff');
  return {userRefs:user.evidenceRefs, staffIds:staff.evidenceRefs.map(x=>x.evidenceId)};
});
await test('campus five scenarios / community six intents / chat no business writes',async()=>{
  const before=ok(await api('GET','/api/v1/tickets')).items.length;
  for (const [q,intent] of [['报修维修','repair'],['供水通知','notice'],['课程考试','schedule'],['失物拾物','lost'],['活动报名','activity']]) {
    const r=ok(await api('POST','/api/v1/chat',{requestId:rid(),text:q})); assert.equal(r.intent,intent); assert(r.evidenceRefs.length>0);
    assert(r.evidenceRefs.every(x=>x.domainId==='campus-demo'));
  }
  for (const [q,intent] of [['办事材料','service'],['物业维修','repair'],['养老服务','eldercare'],['社区活动','activity'],['失物认领','lost'],['你好','general']]) {
    const r=ok(await api('POST','/api/v1/chat',{requestId:rid(),text:q},'community-user')); assert.equal(r.intent,intent);
    assert(r.evidenceRefs.every(x=>x.domainId==='community-demo'));
  }
  assert.equal(ok(await api('GET','/api/v1/tickets')).items.length,before);
});
await test('ticket requires confirmation / alias and fields validation / staff cannot impersonate owner',async()=>{
  error(await api('POST','/api/v1/tickets',{requestId:rid(),location:'楼梯'}),'CONFIRMATION_REQUIRED',409);
  error(await api('POST','/api/v1/ticket-drafts',{requestId:rid(),description:'坏了',contactAlias:'SYN-CONTACT-K'}),'VALIDATION_ERROR',400);
  error(await api('POST','/api/v1/ticket-drafts',{requestId:rid(),location:'公共区域',description:'坏了',contactAlias:'13800000000'}),'VALIDATION_ERROR',400);
  error(await api('POST','/api/v1/ticket-drafts',{requestId:rid(),location:'公共区域',description:'坏了',contactAlias:'SYN-CONTACT-K'},'campus-worker'),'FORBIDDEN',403);
});
await test('draft -> confirm -> commit / receipt / one atomic idempotent result',async()=>{
  const ready=await make(); draft=ready.d; confirmation=ready.c; submission=ready.body; submissionKey=ready.key;
  ticket=ok(await api('POST','/api/v1/tickets',submission,'campus-user',{'Idempotency-Key':submissionKey}));
  assert.equal(ticket.status,'SUBMITTED'); assert.equal(ticket.version,1);
  const replay=ok(await api('POST','/api/v1/tickets',submission,'campus-user',{'Idempotency-Key':submissionKey}));
  assert.deepEqual(replay,ticket);
  const result=ok(await api('GET',`/api/v1/requests/${submission.requestId}/result`));
  assert.equal(result.resultStatus,'COMMITTED'); assert.equal(result.ticketId,ticket.ticketId);
  assert.equal(ok(await api('GET',`/api/v1/tickets/${ticket.ticketId}`)).ticketId,ticket.ticketId);
  return {ticketId:ticket.ticketId,requestId:submission.requestId};
});
await test('same key changed content / consumed confirmation / reused request id',async()=>{
  error(await api('POST','/api/v1/tickets',{...submission,requestId:rid()},'campus-user',{'Idempotency-Key':submissionKey}),'IDEMPOTENCY_CONFLICT',409);
  error(await api('POST','/api/v1/tickets',{...submission,requestId:rid()},'campus-user',{'Idempotency-Key':rid()}),'RECONFIRM_REQUIRED',409);
  const next=await make();
  error(await api('POST','/api/v1/tickets',{...next.body,requestId:submission.requestId},'campus-user',{'Idempotency-Key':next.key}),'IDEMPOTENCY_CONFLICT',409);
});
await test('cross-domain drafts / confirmations / tickets / results are isolated',async()=>{
  error(await api('POST',`/api/v1/ticket-drafts/${draft.draftId}/confirm`,{requestId:rid(),revision:1},'community-user'),'FORBIDDEN',403);
  error(await api('GET',`/api/v1/tickets/${ticket.ticketId}`,undefined,'community-user'),'FORBIDDEN',403);
  error(await api('GET',`/api/v1/tickets/${ticket.ticketId}`,undefined,'community-worker'),'FORBIDDEN',403);
  const own=ok(await api('GET','/api/v1/tickets',undefined,'community-user')); assert(own.items.every(x=>x.domainId==='community-demo'));
  assert.equal(ok(await api('GET',`/api/v1/requests/${submission.requestId}/result`,undefined,'community-user')).resultStatus,'NOT_FOUND');
});
await test('revision changed -> old confirmation rejected -> fresh confirmation succeeds',async()=>{
  const ready=await make();
  const revised=ok(await api('PATCH',`/api/v1/ticket-drafts/${ready.d.draftId}`,{requestId:rid(),expectedRevision:1,location:'公共走廊',description:'合成问题修订',contactAlias:'SYN-CONTACT-K'}));
  assert.equal(revised.revision,2);
  error(await api('POST','/api/v1/tickets',ready.body,'campus-user',{'Idempotency-Key':ready.key}),'RECONFIRM_REQUIRED',409);
  error(await api('POST',`/api/v1/ticket-drafts/${ready.d.draftId}/confirm`,{requestId:rid(),revision:1}),'RECONFIRM_REQUIRED',409);
  const fresh=ok(await api('POST',`/api/v1/ticket-drafts/${ready.d.draftId}/confirm`,{requestId:rid(),revision:2}));
  ok(await api('POST','/api/v1/tickets',{...ready.body,confirmationId:fresh.confirmationId},'campus-user',{'Idempotency-Key':ready.key}));
});
await test('staff role / transition graph / optimistic version / concurrent updates',async()=>{
  error(await api('PATCH',`/api/v1/tickets/${ticket.ticketId}/status`,{status:'PROCESSING',expectedVersion:1}),'FORBIDDEN',403);
  error(await api('PATCH',`/api/v1/tickets/${ticket.ticketId}/status`,{status:'RESOLVED',expectedVersion:1},'campus-worker'),'VALIDATION_ERROR',400);
  const responses=await Promise.all(Array.from({length:8},()=>api('PATCH',`/api/v1/tickets/${ticket.ticketId}/status`,{status:'PROCESSING',expectedVersion:1},'campus-worker')));
  assert.equal(responses.filter(x=>x.value.code==='OK').length,1);
  assert.equal(responses.filter(x=>x.value.code==='VERSION_CONFLICT').length,7);
  const done=ok(await api('PATCH',`/api/v1/tickets/${ticket.ticketId}/status`,{status:'RESOLVED',expectedVersion:2},'campus-worker')); assert.equal(done.version,3);
  // Replay preserves the original immutable receipt after a later status update.
  assert.deepEqual(ok(await api('POST','/api/v1/tickets',submission,'campus-user',{'Idempotency-Key':submissionKey})),ticket);
});
await test('16 concurrent submissions with one key produce one ticket',async()=>{
  const ready=await make(); const before=ok(await api('GET','/api/v1/tickets')).items.length;
  const responses=await Promise.all(Array.from({length:16},()=>api('POST','/api/v1/tickets',ready.body,'campus-user',{'Idempotency-Key':ready.key})));
  const ids=responses.map(r=>ok(r).ticketId); assert.equal(new Set(ids).size,1);
  assert.equal(ok(await api('GET','/api/v1/tickets')).items.length,before+1);
  return {requests:16,uniqueTickets:new Set(ids).size};
});
await test('committed response failure -> original request lookup -> replay',async()=>{
  const ready=await make();
  error(await api('POST','/api/v1/tickets',ready.body,'campus-user',{'Idempotency-Key':ready.key,'X-Demo-Fault':'response-loss'}),'SERVICE_UNAVAILABLE',503);
  const result=ok(await api('GET',`/api/v1/requests/${ready.body.requestId}/result`)); assert.equal(result.resultStatus,'COMMITTED');
  assert.equal(ok(await api('POST','/api/v1/tickets',ready.body,'campus-user',{'Idempotency-Key':ready.key})).ticketId,result.ticketId);
  assert.equal(ok(await api('GET',`/api/v1/requests/${rid()}/result`)).resultStatus,'NOT_FOUND');
});
await test('community repair / separate business store',async()=>{
  const ready=await make('ticket',{},'community-user');
  const result=ok(await api('POST','/api/v1/tickets',ready.body,'community-user',{'Idempotency-Key':ready.key})); assert.equal(result.domainId,'community-demo');
});
await test('save failure rolls back ticket / idempotency / confirmation then original retry commits',async()=>{
  const ready=await make(); const before=ok(await api('GET','/api/v1/tickets')).items.length;
  error(await api('POST','/api/v1/tickets',ready.body,'campus-user',{'Idempotency-Key':ready.key,'X-Demo-Fault':'save-failure'}),'SERVICE_UNAVAILABLE',503);
  assert.equal(ok(await api('GET','/api/v1/tickets')).items.length,before);
  assert.equal(ok(await api('GET',`/api/v1/requests/${ready.body.requestId}/result`)).resultStatus,'NOT_FOUND');
  ok(await api('POST','/api/v1/tickets',ready.body,'campus-user',{'Idempotency-Key':ready.key}));
  assert.equal(ok(await api('GET','/api/v1/tickets')).items.length,before+1);
});
await test('lost publication confirmation / pending review / idempotency / campus restriction',async()=>{
  const ready=await make('lost');
  const result=ok(await api('POST','/api/v1/lost-items',ready.body,'campus-user',{'Idempotency-Key':ready.key})); assert.equal(result.status,'PENDING_REVIEW');
  assert.equal(ok(await api('POST','/api/v1/lost-items',ready.body,'campus-user',{'Idempotency-Key':ready.key})).lostItemId,result.lostItemId);
  assert(ok(await api('GET','/api/v1/lost-items')).items.some(x=>x.lostItemId===result.lostItemId));
  error(await api('POST','/api/v1/lost-item-drafts',{requestId:rid(),kind:'lost',itemDescription:'物品',location:'公共区域',occurredOn:'2026-10-12',contactAlias:'SYN-CONTACT-M'},'community-user'),'FORBIDDEN',403);
});
await test('activity deadline / capacity / session / cross-domain / duplicate / confirmed signup',async()=>{
  assert.deepEqual(ok(await api('GET','/api/v1/activity-signups')).items,[]);
  assert.equal(ok(await api('GET','/api/v1/activities')).items.length,3);
  for (const [activityId,code] of [['campus-demo-closed','ACTIVITY_CLOSED'],['campus-demo-full','CAPACITY_EXCEEDED'],['community-demo-activity-001','FORBIDDEN']]) {
    error(await api('POST','/api/v1/activity-signup-drafts',{requestId:rid(),activityId,session:'morning',contactAlias:'SYN-CONTACT-K'}),code);
  }
  error(await api('POST','/api/v1/activity-signup-drafts',{requestId:rid(),activityId:'campus-demo-activity-001',session:'evening',contactAlias:'SYN-CONTACT-K'}),'VALIDATION_ERROR',400);
  const ready=await make('activity');
  const replies=await Promise.all(Array.from({length:16},()=>api('POST','/api/v1/activities/campus-demo-activity-001/signups',ready.body,'campus-user',{'Idempotency-Key':ready.key})));
  const result=ok(replies[0]); assert.equal(result.status,'SUBMITTED');
  signupFixture={receipt:result,submission:ready.body,key:ready.key};
  assert.equal(new Set(replies.map(x=>ok(x).signupId)).size,1);
  assert.equal(ok(await api('GET','/api/v1/activities')).items.find(x=>x.activityId==='campus-demo-activity-001').remainingCapacity,1);
  assert.equal(ok(await api('POST','/api/v1/activities/campus-demo-activity-001/signups',ready.body,'campus-user',{'Idempotency-Key':ready.key})).signupId,result.signupId);
  error(await api('POST','/api/v1/activity-signup-drafts',{requestId:rid(),activityId:'campus-demo-activity-001',session:'morning',contactAlias:'SYN-CONTACT-K'}),'ALREADY_SIGNED_UP',409);
  return result;
});
await test('signup query exact owner / projected fields / auth and context guards',async()=>{
  const mine=ok(await api('GET','/api/v1/activity-signups')).items;
  assert.equal(mine.length,1);
  const {session,submittedAt,...receipt}=mine[0];
  assert.deepEqual(receipt,signupFixture.receipt);
  assert.equal(session,'morning'); assert.equal(submittedAt,receipt.createdAt);
  for(const account of ['community-user','campus-worker','campus-test-peer']) {
    assert.deepEqual(ok(await api('GET','/api/v1/activity-signups',undefined,account)).items,[]);
    assert.equal(ok(await api('GET',`/api/v1/requests/${signupFixture.submission.requestId}/result`,undefined,account)).resultStatus,'NOT_FOUND');
  }
  for(const account of ['', 'invalid-session']) error(await api('GET','/api/v1/activity-signups',undefined,account),'UNAUTHORIZED',401);
  for(const query of ['domainId=community-demo','userId=user-syn-campus-002','roles=staff','campus=SYN_OTHER_AREA']) error(await api('GET','/api/v1/activity-signups?'+query),'FORBIDDEN',403);
  return mine;
});
await test('signup committed response loss / result recovery / replay without duplicate',async()=>{
  const peer=await make('activity',{},'campus-test-peer');
  const endpoint='/api/v1/activities/campus-demo-activity-001/signups';
  error(await api('POST',endpoint,peer.body,'campus-test-peer',{'Idempotency-Key':peer.key,'X-Demo-Fault':'response-loss'}),'SERVICE_UNAVAILABLE',503);
  const recovered=ok(await api('GET',`/api/v1/requests/${peer.body.requestId}/result`,undefined,'campus-test-peer'));
  assert.equal(recovered.resultStatus,'COMMITTED');
  assert.deepEqual(ok(await api('POST',endpoint,peer.body,'campus-test-peer',{'Idempotency-Key':peer.key})),recovered.receipt);
  const list=ok(await api('GET','/api/v1/activity-signups',undefined,'campus-test-peer')).items;
  assert.equal(list.length,1); assert.equal(list[0].signupId,recovered.receipt.signupId);
  assert.equal(ok(await api('GET','/api/v1/activity-signups')).items[0].signupId,signupFixture.receipt.signupId);
  assert.equal(ok(await api('GET','/api/v1/activities')).items.find(x=>x.activityId==='campus-demo-activity-001').remainingCapacity,0);
  return {requestId:peer.body.requestId,receipt:recovered.receipt};
});
await test('Mock bounded failures / fallback / retry / no real G1',async()=>{
  const outcomes=[];
  for (const [fault,reason,attempts] of [['auth','MOCK_AUTH_FAILED',1],['timeout','MOCK_TIMEOUT',1],['rate-limit','MOCK_RATE_LIMIT',2],['invalid-output','MOCK_INVALID_CITATION',1],['rate-limit-once',undefined,2]]) {
    const response=await api('POST','/api/v1/chat',{requestId:rid(),text:'报修',mockFault:fault}); const r=ok(response);
    assert.equal(r.fallbackReason,reason); assert.equal(r.attempts,attempts); assert.equal(r.realG1Ran,false); assert(response.ms<3000);
    outcomes.push({fault,fallbackReason:r.fallbackReason,attempts,ms:response.ms});
  }
  return outcomes;
});
await test('Mock concurrent generation bounded to four active attempts with deterministic fallback',async()=>{
  const responses=await Promise.all(Array.from({length:16},()=>api('POST','/api/v1/chat',{requestId:rid(),text:'报修',mockFault:'timeout'})));
  const answers=responses.map(ok);
  assert(answers.some(x=>x.fallbackReason==='MOCK_CONCURRENCY_LIMIT'));
  assert(answers.every(x=>['MOCK_TIMEOUT','MOCK_CONCURRENCY_LIMIT'].includes(x.fallbackReason)));
  return {requests:16,timeout:answers.filter(x=>x.fallbackReason==='MOCK_TIMEOUT').length,limited:answers.filter(x=>x.fallbackReason==='MOCK_CONCURRENCY_LIMIT').length};
});

async function stream(fault, cancel=false) {
  const body=JSON.stringify({requestId:rid(),text:'报修维修需要什么材料',...(fault?{mockFault:fault}:{})});
  return new Promise((resolve,reject)=>{
    const start=performance.now(); let text=''; let firstMs; let completed=false;
    const request=http.request(new URL('/api/v1/chat/stream',base),{method:'POST',headers:{'X-Demo-Session':'campus-user','Content-Type':'application/json','Content-Length':Buffer.byteLength(body)}},res=>{
      if (!/^text\/event-stream/.test(res.headers['content-type'] || '')) { res.resume(); reject(new Error(`SSE ${res.statusCode} ${res.headers['content-type']}`)); return; }
      res.setEncoding('utf8');
      res.on('data',chunk=>{
        if (firstMs===undefined) firstMs=performance.now()-start;
        text+=chunk;
        if (cancel && text.includes('event: meta')) { completed=true; request.destroy(); res.destroy(); resolve({text,firstMs,ms:performance.now()-start,cancelled:true}); }
      });
      res.on('end',()=>{completed=true;resolve({text,firstMs,ms:performance.now()-start});});
      res.on('error',e=>{if (!completed) reject(e);});
    });
    request.setTimeout(5000,()=>request.destroy(new Error('stream timeout')));
    request.on('error',e=>{if(!completed) reject(e);}); request.end(body);
  });
}
function parseEvents(text) { return text.split('\n\n').filter(Boolean).map(block=>({event:block.match(/^event: (.+)$/m)?.[1],data:JSON.parse(block.match(/^data: (.+)$/m)[1])})); }
await test('real SSE UTF-8 meta/delta/done and terminal semantics',async()=>{
  const r=await stream(); const events=parseEvents(r.text); assert.equal(events[0].event,'meta');
  assert.equal(events.filter(x=>x.event==='done').length,1); assert.equal(events.at(-1).event,'done');
  assert(events.some(x=>x.event==='delta'&&x.data.text.includes('合成'))); assert(r.ms>r.firstMs+50);
  for(const e of events){assert.equal(e.data.synthetic,true);assert.equal(e.data.realBusinessWrite,false);}
  return {events:events.map(x=>x.event),firstMs:r.firstMs,completeMs:r.ms};
});
await test('SSE fault fallback / incomplete stream lacks done',async()=>{
  const fallback=parseEvents((await stream('timeout')).text); assert(fallback.some(e=>e.event==='error')); assert.equal(fallback.at(-1).event,'done');
  const incomplete=parseEvents((await stream('disconnect')).text); assert(!incomplete.some(e=>e.event==='done')); return {incompleteEvents:incomplete.map(e=>e.event)};
});
await test('SSE cancel ends stream generation and releases active count',async()=>{
  const before=ok(await api('GET','/api/v1/debug/streams',undefined,'campus-worker'));
  const r=await stream('slow',true); assert(!r.text.includes('event: done'));
  let after;
  for(let i=0;i<20;i++){ await new Promise(r=>setTimeout(r,100)); after=ok(await api('GET','/api/v1/debug/streams',undefined,'campus-worker')); if(after.active===0&&after.cancelled>before.cancelled)break; }
  assert.equal(after.active,0); assert(after.cancelled>before.cancelled); return {before,after};
});
await test('exact local CORS allowed / other origins rejected',async()=>{
  const r=await api('GET','/api/v1/notices',undefined,'campus-user',{Origin:'http://127.0.0.1:5173'}); ok(r); assert.equal(r.headers['access-control-allow-origin'],'http://127.0.0.1:5173');
  error(await api('GET','/api/v1/notices',undefined,'campus-user',{Origin:'https://example.com'}),'FORBIDDEN',403);
  const pre=await fetch(base+'/api/v1/tickets',{method:'OPTIONS',headers:{Origin:'http://127.0.0.1:5173','Access-Control-Request-Method':'POST'}}); assert.equal(pre.status,204);
});

const failed=records.filter(x=>!x.passed);
const report={status:failed.length?'failed':'passed',base,completedAt:new Date().toISOString(),synthetic:true,realBusinessWrite:false,realG1Ran:false,claimBoundary:'Development verification, not blind evaluation or AI gain',total:records.length,passed:records.length-failed.length,failed:failed.length,records,requests,signupFixture,recoveryFixture:{ticketId:ticket?.ticketId,submission,key:submissionKey}};
fs.mkdirSync(path.dirname(output),{recursive:true});fs.writeFileSync(output,JSON.stringify(report,null,2));
console.log(`HTTP integration: ${report.passed}/${report.total}; report=${output}`);
process.exitCode=failed.length?1:0;
