package ict_backend

import std.collection.*
import std.env.*
import std.fs.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*

class Business {
    let knowledge: Knowledge
    let storePath: String
    let clock: () -> DateTime
    let ttl: Int64
    let auth: Auth
    let gate = Mutex()
    var state = obj()
    var dirty = false

    init(knowledge: Knowledge, storePath: String, clock!: () -> DateTime = { => utcNow() }, ttl!: Int64 = 300,
         auth!: Auth = Auth("demo", SessionStore(3600))) {
        this.knowledge = knowledge; this.storePath = storePath; this.clock = clock; this.ttl = ttl; this.auth = auth
        let pendingPath = storePath + ".pending"
        if (exists(storePath)) {
            state = JsonValue.fromStr(String.fromUtf8(File.readFrom(storePath))).asObject()
            if (str(state, "schemaVersion") != "synthetic-store-0.1") { fail("VALIDATION_ERROR") }
        } else {
            state.put("schemaVersion", s("synthetic-store-0.1"))
            state.put("counter", n(0))
            for (name in ["drafts", "confirmations", "tickets", "lostItems", "signups", "idempotency", "results"]) { state.put(name, JsonArray()) }
            save()
        }
        // Crash recovery for the commit path. save() writes a sibling .pending file and
        // renames it over the store, so a leftover .pending means a process died between
        // the write and the rename. The store file is still the last complete snapshot,
        // so the partial file is discarded and the event is counted rather than loaded.
        // Without this, an interrupted commit left a stale .pending file that nothing
        // ever cleaned up and nothing ever reported.
        if (exists(pendingPath)) {
            remove(pendingPath)
            let prior = if (state.containsKey("interruptedCommits")) { integer(state, "interruptedCommits") } else { 0 }
            state.put("interruptedCommits", n(prior + 1))
            save()
        }
    }

    func save(): Unit {
        let temporary = storePath + ".pending"
        File.writeTo(temporary, state.toString().toArray())
        rename(temporary, to: storePath, overwrite: true)
    }

    func id(prefix: String): String {
        let next = integer(state, "counter") + 1
        state.put("counter", n(next)); dirty = true
        return "${prefix}-${getProcessId()}-${next}"
    }

    func lookup(collection: String, key: String, value: String): JsonObject {
        for (v in array(state, collection).getItems()) {
            let r = v.asObject()
            if (str(r, key) == value) { return r }
        }
        fail("NOT_FOUND")
    }

    // One process owns a store. The mutex covers validation, capacity checks and snapshot replacement.
    func execute(method: String, path: String, query: JsonObject, body: JsonObject, session: String, key: String, failSave!: Bool = false): JsonObject {
        if (method == "POST" && (path == "/api/v1/chat" || path == "/api/v1/chat/stream")) {
            let who = auth.resolve(session); checkContext(body, who); checkContext(query, who)
            return chat(body, who, knowledge, clock())
        }
        synchronized(gate) {
            let before = copyObject(state)
            dirty = false
            try {
                let result = route(method, path, query, body, session, key)
                if (dirty) {
                    if (failSave) { throw Exception("Injected failure before snapshot commit") }
                    save()
                }
                return marked(result)
            } catch (e: Exception) {
                state = before
                throw e
            }
        }
    }

    func fields(body: JsonObject, kind: String, who: Identity): JsonObject {
        if (who.role == "staff") { fail("FORBIDDEN") }
        let f = obj()
        if (kind == "repair") {
            f.put("location", s(required(body, "location", limit: 200)))
            f.put("description", s(required(body, "description", limit: 2000)))
        } else if (kind == "lost") {
            campusOnly(who)
            let k = required(body, "kind").toAsciiLower()
            if (k != "lost" && k != "found") { fail("VALIDATION_ERROR") }
            f.put("kind", s(k)); f.put("itemDescription", s(required(body, "itemDescription", limit: 500)))
            f.put("location", s(required(body, "location", limit: 200)))
            let date = required(body, "occurredOn", limit: 10)
            if (date.size != 10) { fail("VALIDATION_ERROR") }
            let day = DateTime.tryParse(date + "T00:00:00Z")
            if (let Some(d) <- day) {
                if (iso(d)[0..10] != date || d > clock()) { fail("VALIDATION_ERROR") }
            } else { fail("VALIDATION_ERROR") }
            f.put("occurredOn", s(date))
        } else {
            campusOnly(who)
            let activityId = identifier(required(body, "activityId", limit: 100))
            let activity = activityById(activityId, who)
            let slot = required(body, "session", limit: 100)
            if (slot != str(activity, "session")) { fail("VALIDATION_ERROR") }
            checkActivity(activity, who)
            f.put("activityId", s(activityId)); f.put("session", s(slot))
        }
        f.put("contactAlias", s(alias(body)))
        return f
    }

    func campusOnly(who: Identity): Unit { if (who.domain != "campus-demo") { fail("FORBIDDEN") } }

    func draftFields(body: JsonObject, kind: String, revise: Bool): Unit {
        let keys = ArrayList<String>(["requestId", "contactAlias"])
        if (revise) { keys.add("expectedRevision") }
        if (kind == "repair") { keys.add("location"); keys.add("description") }
        else if (kind == "lost") { for (key in ["kind", "itemDescription", "location", "occurredOn"]) { keys.add(key) } }
        else { keys.add("activityId"); keys.add("session") }
        allowedFields(body, keys.toArray())
    }

    func activityById(activityId: String, who: Identity): JsonObject {
        for (v in array(knowledge.dataset, "activities").getItems()) {
            let r = v.asObject()
            if (str(r, "activityId") == activityId) {
                if (str(r, "domainId") != who.domain) { fail("FORBIDDEN") }
                return r
            }
        }
        fail("NOT_FOUND")
    }

    func signupCount(activityId: String): Int64 {
        var count: Int64 = 0
        for (v in array(state, "signups").getItems()) { if (str(v.asObject(), "activityId") == activityId) { count++ } }
        return count
    }

    func checkActivity(activity: JsonObject, who: Identity): Unit {
        if (str(activity, "status") != "OPEN" || DateTime.parse(str(activity, "deadlineAt")) <= clock()) { fail("ACTIVITY_CLOSED") }
        for (v in array(state, "signups").getItems()) {
            let r = v.asObject()
            if (str(r, "activityId") == str(activity, "activityId") && str(r, "userId") == who.user) { fail("ALREADY_SIGNED_UP") }
        }
        if (signupCount(str(activity, "activityId")) >= integer(activity, "capacity")) { fail("CAPACITY_EXCEEDED") }
    }

    func makeDraft(body: JsonObject, who: Identity, kind: String): JsonObject {
        draftFields(body, kind, false)
        requestId(body)
        let f = fields(body, kind, who)
        let evidence = knowledge.evidence(who, clock(), kind)
        let draft = marked(obj())
        draft.put("draftId", s(id("draft"))); draft.put("revision", n(1)); draft.put("kind", s(kind))
        draft.put("userId", s(who.user)); draft.put("domainId", s(who.domain))
        draft.put("requestId", s(str(body, "requestId"))); draft.put("status", s("AWAITING_CONFIRMATION"))
        draft.put("displayFields", f); draft.put("evidenceRefs", evidence)
        draft.put("expiresAt", s(iso(clock().addSeconds(ttl))))
        array(state, "drafts").add(draft); dirty = true
        return copyObject(draft)
    }

    func draftFor(draftId: String, who: Identity, kind: String): JsonObject {
        let d = lookup("drafts", "draftId", draftId)
        owner(d, who)
        if (str(d, "kind") != kind) { fail("VALIDATION_ERROR") }
        return d
    }

    func validateDraft(d: JsonObject, who: Identity): Unit {
        if (str(d, "status") == "SUBMITTED" || DateTime.parse(str(d, "expiresAt")) <= clock()) { fail("RECONFIRM_REQUIRED") }
        if (!knowledge.snapshotCurrent(array(d, "evidenceRefs"), who, clock(), str(d, "kind"))) { fail("RECONFIRM_REQUIRED") }
        fields(d["displayFields"].asObject(), str(d, "kind"), who)
    }

    func binding(d: JsonObject): String {
        let f = d["displayFields"].asObject()
        let a = JsonArray()
        for (key in ["draftId", "userId", "domainId", "kind"]) { a.add(s(str(d, key))) }
        a.add(n(integer(d, "revision")))
        for (key in ["location", "description", "kind", "itemDescription", "occurredOn", "activityId", "session", "contactAlias"]) {
            a.add(s(str(f, key)))
        }
        for (v in array(d, "evidenceRefs").getItems()) {
            let ref = v.asObject()
            for (key in ["evidenceId", "version", "sourceId", "contentHash"]) { a.add(s(str(ref, key))) }
        }
        return a.toString()
    }

    func confirm(draftId: String, body: JsonObject, who: Identity, kind: String): JsonObject {
        allowedFields(body, ["requestId", "revision"])
        requestId(body)
        let d = draftFor(draftId, who, kind)
        if (integer(body, "revision") != integer(d, "revision")) { fail("RECONFIRM_REQUIRED") }
        validateDraft(d, who)
        let c = marked(obj())
        c.put("confirmationId", s(id("confirm"))); c.put("draftId", s(draftId))
        c.put("revision", n(integer(d, "revision"))); c.put("userId", s(who.user)); c.put("domainId", s(who.domain))
        c.put("binding", s(binding(d))); c.put("consumed", flag(false))
        c.put("expiresAt", s(iso(clock().addSeconds(min(ttl, 120)))))
        array(state, "confirmations").add(c); d.put("status", s("CONFIRMED")); dirty = true
        let response = obj()
        for (key in ["confirmationId", "draftId", "revision", "expiresAt"]) { response.put(key, c[key]) }
        return response
    }

    func revise(draftId: String, body: JsonObject, who: Identity, kind: String): JsonObject {
        draftFields(body, kind, true)
        requestId(body)
        let d = draftFor(draftId, who, kind)
        if (str(d, "status") == "SUBMITTED" || integer(body, "expectedRevision") != integer(d, "revision")) { fail("VERSION_CONFLICT") }
        let f = fields(body, kind, who)
        d.put("displayFields", f); d.put("evidenceRefs", knowledge.evidence(who, clock(), kind))
        d.put("revision", n(integer(d, "revision") + 1)); d.put("status", s("AWAITING_CONFIRMATION"))
        d.put("expiresAt", s(iso(clock().addSeconds(ttl)))); dirty = true
        return copyObject(d)
    }

    func submit(body: JsonObject, who: Identity, key: String, kind: String, activityId: String): JsonObject {
        let rid = requestId(body)
        if (key.isEmpty() || !body.containsKey("draftId") || !body.containsKey("confirmationId")) { fail("CONFIRMATION_REQUIRED") }
        allowedFields(body, ["requestId", "draftId", "confirmationId"])
        identifier(key)
        let did = identifier(required(body, "draftId", limit: 100))
        let cid = identifier(required(body, "confirmationId", limit: 100))
        let fingerprint = JsonArray([s(rid), s(did), s(cid), s(kind), s(activityId)]).toString()
        for (v in array(state, "idempotency").getItems()) {
            let previous = v.asObject()
            if (str(previous, "key") == key && str(previous, "userId") == who.user && str(previous, "domainId") == who.domain) {
                if (str(previous, "fingerprint") != fingerprint) { fail("IDEMPOTENCY_CONFLICT") }
                return copyObject(previous["receipt"].asObject())
            }
        }
        for (v in array(state, "results").getItems()) {
            let r = v.asObject()
            if (str(r, "requestId") == rid && str(r, "userId") == who.user && str(r, "domainId") == who.domain) { fail("IDEMPOTENCY_CONFLICT") }
        }
        let d = draftFor(did, who, kind)
        let c = lookup("confirmations", "confirmationId", cid)
        owner(c, who)
        if (str(c, "draftId") != did || integer(c, "revision") != integer(d, "revision") ||
            str(c, "binding") != binding(d) || c["consumed"].asBool().getValue() ||
            DateTime.parse(str(c, "expiresAt")) <= clock()) { fail("RECONFIRM_REQUIRED") }
        validateDraft(d, who)
        let f = d["displayFields"].asObject()
        if (kind == "activity" && str(f, "activityId") != activityId) { fail("VALIDATION_ERROR") }
        let record = marked(obj())
        let idKey = if (kind == "repair") { "ticketId" } else if (kind == "lost") { "lostItemId" } else { "signupId" }
        let recordId = id(kind)
        record.put(idKey, s(recordId)); record.put("requestId", s(rid)); record.put("userId", s(who.user)); record.put("domainId", s(who.domain))
        record.put("version", n(1)); record.put("displayFields", copyObject(f)); record.put("evidenceRefs", array(d, "evidenceRefs"))
        record.put("createdAt", s(iso(clock())))
        record.put("status", s(if (kind == "lost") { "PENDING_REVIEW" } else { "SUBMITTED" }))
        if (kind == "activity") { record.put("activityId", s(activityId)) }
        if (kind == "lost") { for ((k, v) in f.getFields()) { record.put(k, v) } }
        let collection = if (kind == "repair") { "tickets" } else if (kind == "lost") { "lostItems" } else { "signups" }
        array(state, collection).add(record)
        d.put("status", s("SUBMITTED")); c.put("consumed", flag(true))
        let receipt = copyObject(record)
        let idem = obj()
        idem.put("key", s(key)); idem.put("fingerprint", s(fingerprint)); idem.put("userId", s(who.user)); idem.put("domainId", s(who.domain)); idem.put("receipt", receipt)
        array(state, "idempotency").add(idem)
        let result = obj()
        result.put("requestId", s(rid)); result.put("userId", s(who.user)); result.put("domainId", s(who.domain))
        result.put("resultStatus", s("COMMITTED")); result.put(idKey, s(recordId)); result.put("receipt", receipt)
        array(state, "results").add(result); dirty = true
        return copyObject(receipt)
    }

    func listTickets(who: Identity): JsonObject {
        let response = obj(); let items = JsonArray()
        for (v in array(state, "tickets").getItems()) {
            let r = v.asObject()
            if (str(r, "domainId") == who.domain && (str(r, "userId") == who.user || who.role == "staff")) { items.add(copyObject(r)) }
        }
        response.put("items", items); return response
    }

    func result(rid: String, who: Identity): JsonObject {
        identifier(rid)
        for (v in array(state, "results").getItems()) {
            let r = v.asObject()
            if (str(r, "requestId") == rid && str(r, "domainId") == who.domain && str(r, "userId") == who.user) { return copyObject(r) }
        }
        let r = obj(); r.put("requestId", s(rid)); r.put("resultStatus", s("NOT_FOUND")); return r
    }

    func listSignups(who: Identity): JsonObject {
        let rows = ArrayList<JsonObject>()
        for (v in array(state, "signups").getItems()) {
            let r = v.asObject()
            if (str(r, "domainId") == who.domain && str(r, "userId") == who.user) {
                let item = copyObject(r)
                item.put("session", s(str(r["displayFields"].asObject(), "session")))
                item.put("submittedAt", s(str(r, "createdAt")))
                rows.add(item)
            }
        }
        // Project old stored receipts without modifying them; order newest first, then ID descending.
        for (i in 0..rows.size) {
            for (j in i + 1..rows.size) {
                if (str(rows[j], "submittedAt") > str(rows[i], "submittedAt") ||
                    (str(rows[j], "submittedAt") == str(rows[i], "submittedAt") && str(rows[j], "signupId") > str(rows[i], "signupId"))) {
                    let previous = rows[i]; rows[i] = rows[j]; rows[j] = previous
                }
            }
        }
        let items = JsonArray()
        for (r in rows) { items.add(r) }
        let response = obj(); response.put("items", items); return response
    }

    func transition(ticketId: String, body: JsonObject, who: Identity): JsonObject {
        allowedFields(body, ["status", "expectedVersion", "requestId"])
        if (who.role != "staff") { fail("FORBIDDEN") }
        let r = lookup("tickets", "ticketId", ticketId); owner(r, who, staff: true)
        if (integer(body, "expectedVersion") != integer(r, "version")) { fail("VERSION_CONFLICT") }
        let status = required(body, "status")
        let before = str(r, "status")
        if (!((before == "SUBMITTED" && status == "PROCESSING") || (before == "PROCESSING" && status == "RESOLVED"))) { fail("VALIDATION_ERROR") }
        r.put("status", s(status)); r.put("version", n(integer(r, "version") + 1)); r.put("updatedAt", s(iso(clock())))
        dirty = true; return copyObject(r)
    }

    func listings(kind: String, who: Identity, query: JsonObject): JsonObject {
        let items = JsonArray()
        if (kind == "notices") {
            for (r in knowledge.applicable(who, clock())) {
                if (str(r, "kind") == "notice") {
                    let item = copyObject(r); item.put("noticeId", s(str(r, "evidenceId"))); items.add(item)
                }
            }
        } else if (kind == "schedule") {
            campusOnly(who)
            let date = str(query, "date"); let filter = str(query, "kind")
            if (!filter.isEmpty() && filter != "course" && filter != "exam") { fail("VALIDATION_ERROR") }
            if (!date.isEmpty()) {
                if (date.size != 10 || DateTime.tryParse(date + "T00:00:00Z").isNone()) { fail("VALIDATION_ERROR") }
            }
            for (v in array(knowledge.dataset, "schedule").getItems()) {
                let r = v.asObject()
                if (str(r, "domainId") == who.domain && str(r, "userId") == who.user &&
                    (filter.isEmpty() || filter == str(r, "kind")) && (date.isEmpty() || str(r, "startsAt").startsWith(date))) { items.add(marked(copyObject(r))) }
            }
        } else if (kind == "activities") {
            for (v in array(knowledge.dataset, "activities").getItems()) {
                let r = v.asObject()
                if (str(r, "domainId") == who.domain) {
                    let item = marked(copyObject(r)); let remaining = max(0, integer(r, "capacity") - signupCount(str(r, "activityId")))
                    item.put("remainingCapacity", n(remaining))
                    if (DateTime.parse(str(r, "deadlineAt")) <= clock()) { item.put("status", s("CLOSED")) }
                    items.add(item)
                }
            }
        } else {
            for (v in array(knowledge.dataset, "lostItems").getItems()) {
                let r = v.asObject()
                if (str(r, "domainId") == who.domain && str(r, "status") == "APPROVED") { items.add(marked(copyObject(r))) }
            }
            for (v in array(state, "lostItems").getItems()) {
                let r = v.asObject()
                if (str(r, "domainId") == who.domain && (str(r, "userId") == who.user || who.role == "staff")) { items.add(copyObject(r)) }
            }
        }
        let response = obj(); response.put("items", items); return response
    }

    func route(method: String, path: String, query: JsonObject, body: JsonObject, session: String, key: String): JsonObject {
        if (method == "GET" && path == "/health") {
            let r = obj(); r.put("status", s("ok")); r.put("version", s("0.1.0")); r.put("contractVersion", s("0.1.0"))
            r.put("datasetVersion", s(str(knowledge.dataset, "version"))); r.put("authentication", s(auth.describe()))
            r.put("authMode", s(auth.mode))
            r.put("gateway", s("G0")); r.put("realG1Ran", flag(false)); return r
        }
        let who = auth.resolve(session); checkContext(body, who); checkContext(query, who)
        if (method == "POST" && (path == "/api/v1/chat" || path == "/api/v1/chat/stream")) {
            return chat(body, who, knowledge, clock())
        }
        for (kind in ["notices", "schedule", "activities", "lost-items"]) {
            if (method == "GET" && path == "/api/v1/" + kind) { return listings(kind, who, query) }
        }
        if (method == "GET" && path == "/api/v1/tickets") { return listTickets(who) }
        if (method == "GET" && path == "/api/v1/activity-signups") { return listSignups(who) }
        let pieces = path.split("/", removeEmpty: true)
        if (pieces.size < 3 || pieces[0] != "api" || pieces[1] != "v1") { fail("NOT_FOUND") }
        let resource = pieces[2]
        let kind = if (resource == "ticket-drafts") { "repair" } else if (resource == "lost-item-drafts") { "lost" } else { "activity" }
        if (resource == "ticket-drafts" || resource == "lost-item-drafts" || resource == "activity-signup-drafts") {
            if (method == "POST" && pieces.size == 3) { return makeDraft(body, who, kind) }
            if (pieces.size >= 4) {
                identifier(pieces[3])
                if (method == "POST" && pieces.size == 5 && pieces[4] == "confirm") { return confirm(pieces[3], body, who, kind) }
                if (method == "PATCH" && pieces.size == 4) { return revise(pieces[3], body, who, kind) }
                if (method == "GET" && pieces.size == 4) { return copyObject(draftFor(pieces[3], who, kind)) }
            }
        }
        if (method == "POST" && pieces.size == 3 && resource == "tickets") { return submit(body, who, key, "repair", "") }
        if (method == "POST" && pieces.size == 3 && resource == "lost-items") { return submit(body, who, key, "lost", "") }
        if (resource == "activities" && method == "POST" && pieces.size == 5 && pieces[4] == "signups") { return submit(body, who, key, "activity", identifier(pieces[3])) }
        if (resource == "requests" && method == "GET" && pieces.size == 5 && pieces[4] == "result") { return result(pieces[3], who) }
        if (resource == "tickets" && pieces.size >= 4) {
            identifier(pieces[3])
            if (method == "GET" && pieces.size == 4) {
                let r = lookup("tickets", "ticketId", pieces[3]); owner(r, who, staff: true); return copyObject(r)
            }
            if (method == "PATCH" && pieces.size == 5 && pieces[4] == "status") { return transition(pieces[3], body, who) }
        }
        fail("NOT_FOUND")
    }
}
