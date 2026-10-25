import fs from 'node:fs';
import assert from 'node:assert/strict';
const report=JSON.parse(fs.readFileSync(process.env.ICT_HTTP_REPORT,'utf8'));
const server=JSON.parse(fs.readFileSync(process.env.ICT_SERVER_REPORT,'utf8'));
const fixture=report.recoveryFixture;
const before=JSON.parse(fs.readFileSync(server.runDirectory+'/store.json','utf8'));
const base=process.env.ICT_BASE_URL;
const headers={'Content-Type':'application/json','X-Demo-Session':'campus-user'};
async function call(endpoint,options={}){const r=await fetch(base+endpoint,{headers,...options});const v=await r.json();assert.equal(v.code,'OK');return v.data;}
const ticket=await call('/api/v1/tickets/'+fixture.ticketId);assert.equal(ticket.status,'RESOLVED');assert.equal(ticket.version,3);
const result=await call('/api/v1/requests/'+fixture.submission.requestId+'/result');assert.equal(result.resultStatus,'COMMITTED');assert.equal(result.ticketId,fixture.ticketId);
const replay=await call('/api/v1/tickets',{method:'POST',headers:{...headers,'Idempotency-Key':fixture.key},body:JSON.stringify(fixture.submission)});
assert.equal(replay.ticketId,fixture.ticketId);assert.equal(replay.status,'SUBMITTED');assert.equal(replay.version,1);
const after=JSON.parse(fs.readFileSync(server.runDirectory+'/store.json','utf8'));assert.deepEqual(after,before);
const signups=await call('/api/v1/activity-signups');
assert.equal(signups.items.length,1); assert.equal(signups.items[0].signupId,report.signupFixture.receipt.signupId);
const signupReplay=await call('/api/v1/activities/campus-demo-activity-001/signups',{method:'POST',headers:{...headers,'Idempotency-Key':report.signupFixture.key},body:JSON.stringify(report.signupFixture.submission)});
assert.deepEqual(signupReplay,report.signupFixture.receipt);
assert.deepEqual(JSON.parse(fs.readFileSync(server.runDirectory+'/store.json','utf8')),before);
for(const item of after.tickets){assert(after.results.some(r=>r.ticketId===item.ticketId));assert(after.idempotency.some(r=>r.receipt.ticketId===item.ticketId));}
const output={status:'passed',serverRestarted:true,signupId:signupReplay.signupId,signupQueryAfterRestart:signups.items,signupImmutableReplay:true,ticketId:ticket.ticketId,latestStatus:ticket.status,latestVersion:ticket.version,replayStatus:replay.status,tickets:after.tickets.length,idempotency:after.idempotency.length,results:after.results.length,immutableReplay:true,stateUnchangedByReplay:true,completedAt:new Date().toISOString()};
fs.writeFileSync(process.env.ICT_TEST_OUTPUT,JSON.stringify(output,null,2));console.log(JSON.stringify(output,null,2));
