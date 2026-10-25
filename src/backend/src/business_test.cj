package ict_backend

import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json.*

class TestClock {
    var time: DateTime
    init(time: DateTime) { this.time = time }
}

class Fixture {
    let knowledge: Knowledge
    let time: TestClock
    let service: Business
    let store: String
    init() {
        knowledge = Knowledge(getVariable("ICT_DATA") ?? "synthetic.runtime.json")
        let tick = TestClock(DateTime.parse(str(knowledge.dataset, "generatedAt")))
        time = tick
        store = "unit-${getProcessId()}-${DateTime.nowUTC().nanosecond}.json"
        service = Business(knowledge, store, clock: { => tick.time })
    }
    func call(method: String, path: String, body: JsonObject, key!: String = "", session!: String = "campus-user"): JsonObject {
        service.execute(method, path, obj(), body, session, key)
    }
    func draft(): JsonObject {
        call("POST", "/api/v1/ticket-drafts", JsonValue.fromStr(##"{"requestId":"unit-draft","location":"公共区域","description":"合成报修","contactAlias":"SYN-CONTACT-K"}"##).asObject())
    }
    func confirmation(d: JsonObject): JsonObject {
        let body = obj(); body.put("requestId", s("unit-confirm")); body.put("revision", d["revision"])
        call("POST", "/api/v1/ticket-drafts/" + str(d, "draftId") + "/confirm", body)
    }
    func submission(d: JsonObject, c: JsonObject): JsonObject {
        let body = obj(); body.put("requestId", s("unit-submit")); body.put("draftId", d["draftId"]); body.put("confirmationId", c["confirmationId"]); return body
    }
}

func rejected(action: () -> Unit, code: String): Bool {
    try { action() } catch (e: BusinessError) { return e.code == code }
    return false
}

@Test
class BusinessTests {
    @TestCase
    func importRejectsTamperDuplicateAndRealData() {
        let f = Fixture()
        let path = f.store + ".dataset.json"
        var data = copyObject(f.knowledge.dataset)
        array(data,"records")[0].asObject().put("contentHash",s("sha256:invalid"))
        File.writeTo(path,data.toString().toArray())
        @Expect(rejected({ => Knowledge(path) },"VALIDATION_ERROR"),true)
        data = copyObject(f.knowledge.dataset)
        array(data,"records").add(array(data,"records")[0])
        File.writeTo(path,data.toString().toArray())
        @Expect(rejected({ => Knowledge(path) },"VALIDATION_ERROR"),true)
        data = copyObject(f.knowledge.dataset); data.put("synthetic",flag(false))
        File.writeTo(path,data.toString().toArray())
        @Expect(rejected({ => Knowledge(path) },"FORBIDDEN"),true)
        data = copyObject(f.knowledge.dataset)
        array(data,"records")[0].asObject().put("sourceId",s("SRC_SYN_M_LOCAL"))
        File.writeTo(path,data.toString().toArray())
        @Expect(rejected({ => Knowledge(path) },"VALIDATION_ERROR"),true)
    }

    @TestCase
    func expiryAndClock() {
        let f = Fixture(); let d = f.draft(); let c = f.confirmation(d)
        f.time.time = f.time.time.addSeconds(121)
        @Expect(rejected({ => f.call("POST", "/api/v1/tickets", f.submission(d,c), key: "unit-key") }, "RECONFIRM_REQUIRED"), true)
        @Expect(array(f.service.state,"tickets").size(), 0)
        f.time.time = f.time.time.addSeconds(180)
        @Expect(rejected({ => f.confirmation(d) }, "RECONFIRM_REQUIRED"), true)
        @Expect(DateTime.tryParse(str(d,"expiresAt")).isSome(), true)
    }

    @TestCase
    func evidenceChangeRevocationConflictAndUnknown() {
        let f = Fixture(); let d = f.draft(); let c = f.confirmation(d)
        let current = f.knowledge.evidence(identity("campus-user"),f.time.time,"repair")[0].asObject()
        var actual: JsonObject = obj()
        for (v in array(f.knowledge.dataset,"records").getItems()) {
            if (str(v.asObject(),"evidenceId") == "K_REPAIR") { actual = v.asObject() }
        }
        actual.put("version",s("1.1.0"))
        @Expect(rejected({ => f.call("POST","/api/v1/tickets",f.submission(d,c),key:"unit-key") },"RECONFIRM_REQUIRED"),true)
        actual.put("version",s("1.0.0")); actual.put("revoked",flag(true))
        @Expect(rejected({ => f.draft() },"EVIDENCE_NOT_APPLICABLE"),true)
        actual.put("revoked",flag(false)); actual.put("effectiveTo",JsonNull())
        @Expect(rejected({ => f.draft() },"EVIDENCE_NOT_APPLICABLE"),true)
        actual.put("effectiveTo",current["effectiveTo"])
        let conflict = copyObject(actual); conflict.put("evidenceId",s("K_REPAIR_CONFLICT"))
        array(f.knowledge.dataset,"records").add(conflict)
        @Expect(rejected({ => f.draft() },"EVIDENCE_NOT_APPLICABLE"),true)
        @Expect(array(f.service.state,"tickets").size(),0)
    }

    @TestCase
    func bindingAndPersistentAtomicSnapshot() {
        let f=Fixture(); let d=f.draft(); let c=f.confirmation(d)
        var actual=f.service.lookup("drafts","draftId",str(d,"draftId"))
        actual["displayFields"].asObject().put("description",s("修改参数"))
        @Expect(rejected({ => f.call("POST","/api/v1/tickets",f.submission(d,c),key:"unit-key") },"RECONFIRM_REQUIRED"),true)
        actual=f.service.lookup("drafts","draftId",str(d,"draftId"))
        actual["displayFields"].asObject().put("description",s("合成报修"))
        let receipt=f.call("POST","/api/v1/tickets",f.submission(d,c),key:"unit-key")
        // An incomplete next snapshot must not replace the last committed file on restart.
        File.writeTo(f.store + ".pending","{".toArray())
        let restarted=Business(f.knowledge,f.store,clock:{ => f.time.time })
        let replay=restarted.execute("POST","/api/v1/tickets",obj(),f.submission(d,c),"campus-user","unit-key")
        @Expect(str(replay,"ticketId"),str(receipt,"ticketId"))
        @Expect(array(restarted.state,"tickets").size(),1)
        @Expect(array(restarted.state,"idempotency").size(),1)
        @Expect(array(restarted.state,"results").size(),1)
        @Expect(str(restarted.result("unit-submit",identity("campus-user")),"resultStatus"),"COMMITTED")
    }

    @TestCase
    func activityCapacityAndDeadlineAtCommit() {
        let f=Fixture(); let who=identity("campus-user")
        let fields=JsonValue.fromStr(##"{"requestId":"unit-act","activityId":"campus-demo-activity-001","session":"morning","contactAlias":"SYN-CONTACT-K"}"##).asObject()
        let d=f.call("POST","/api/v1/activity-signup-drafts",fields)
        let cb=obj(); cb.put("requestId",s("unit-confirm")); cb.put("revision",n(1))
        let c=f.call("POST","/api/v1/activity-signup-drafts/"+str(d,"draftId")+"/confirm",cb)
        let activity=f.service.activityById("campus-demo-activity-001",who)
        activity.put("capacity",n(0))
        @Expect(rejected({ => f.call("POST","/api/v1/activities/campus-demo-activity-001/signups",f.submission(d,c),key:"act-key") },"CAPACITY_EXCEEDED"),true)
        activity.put("capacity",n(2)); activity.put("deadlineAt",s(iso(f.time.time)))
        @Expect(rejected({ => f.call("POST","/api/v1/activities/campus-demo-activity-001/signups",f.submission(d,c),key:"act-key") },"ACTIVITY_CLOSED"),true)
        @Expect(array(f.service.state,"signups").size(),0)
    }

    @TestCase
    func sameDomainDifferentOwnerCannotReadOrConfirm() {
        let f=Fixture(); let d=f.draft()
        let other=Identity("user-syn-campus-002","campus-demo","student","SYN_CAMPUS_A")
        let cb=obj(); cb.put("requestId",s("other-confirm")); cb.put("revision",n(1))
        @Expect(rejected({ => f.service.confirm(str(d,"draftId"),cb,other,"repair") },"FORBIDDEN"),true)
        let c=f.confirmation(d)
        let t=f.call("POST","/api/v1/tickets",f.submission(d,c),key:"unit-key")
        @Expect(rejected({ => owner(t,other) },"FORBIDDEN"),true)
        @Expect(array(f.service.listTickets(other),"items").size(),0)
    }

    @TestCase
    func signupProjectionOrderAndOwnerPreserveStoredReceipts() {
        let f = Fixture()
        for ((sid, user, time) in [("a", "user-syn-campus-001", "2026-10-12T00:00:00Z"),
            ("b", "user-syn-campus-001", "2026-10-13T00:00:00Z"),
            ("c", "user-syn-campus-001", "2026-10-13T00:00:00Z"),
            ("foreign", "user-syn-campus-002", "2026-10-14T00:00:00Z")]) {
            let r = marked(obj()); r.put("signupId", s(sid)); r.put("userId", s(user)); r.put("domainId", s("campus-demo"))
            r.put("createdAt", s(time)); let fields = obj(); fields.put("session", s("morning")); r.put("displayFields", fields)
            array(f.service.state, "signups").add(r)
        }
        let before = f.service.state.toString()
        let list = array(f.service.listSignups(identity("campus-user")), "items")
        @Expect(list.size(), 3)
        @Expect(str(list[0].asObject(), "signupId"), "c")
        @Expect(str(list[1].asObject(), "signupId"), "b")
        @Expect(str(list[2].asObject(), "signupId"), "a")
        @Expect(str(list[0].asObject(), "session"), "morning")
        @Expect(str(list[0].asObject(), "submittedAt"), "2026-10-13T00:00:00Z")
        @Expect(array(f.service.listSignups(identity("campus-worker")), "items").size(), 0)
        @Expect(array(f.service.listSignups(identity("community-user")), "items").size(), 0)
        @Expect(f.service.state.toString(), before)
    }
}
