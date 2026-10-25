package ict_backend

import std.time.*
import std.env.*
import stdx.encoding.json.*

class BusinessError <: Exception {
    let code: String
    init(code: String) { super(code); this.code = code }
}

func fail(code: String): Nothing { throw BusinessError(code) }
func obj(): JsonObject { JsonObject() }
func copyObject(value: JsonObject): JsonObject { JsonValue.fromStr(value.toString()).asObject() }
func s(value: String): JsonString { JsonString(value) }
func n(value: Int64): JsonInt { JsonInt(value) }
func flag(value: Bool): JsonBool { JsonBool(value) }
func str(value: JsonObject, key: String): String {
    if (let Some(v) <- value.get(key)) {
        if (!(v is JsonString)) { fail("VALIDATION_ERROR") }
        return v.asString().getValue()
    }
    return ""
}
func integer(value: JsonObject, key: String): Int64 {
    if (let Some(v) <- value.get(key)) {
        if (!(v is JsonInt)) { fail("VALIDATION_ERROR") }
        return v.asInt().getValue()
    }
    fail("VALIDATION_ERROR")
}
func array(value: JsonObject, key: String): JsonArray { value[key].asArray() }
func marked(value: JsonObject): JsonObject {
    value.put("synthetic", flag(true)); value.put("realBusinessWrite", flag(false)); return value
}
func required(value: JsonObject, key: String, limit!: Int64 = 500): String {
    let text = str(value, key).trimAscii()
    if (text.isEmpty() || text.size > limit) { fail("VALIDATION_ERROR") }
    for (r in text.runes()) { if (UInt32(r) < 32 || UInt32(r) == 127) { fail("VALIDATION_ERROR") } }
    return text
}
func identifier(value: String): String {
    if (value.isEmpty() || value.size > 100) { fail("VALIDATION_ERROR") }
    for (r in value.runes()) {
        let c = UInt32(r)
        if (!((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 95)) {
            fail("VALIDATION_ERROR")
        }
    }
    return value
}
func requestId(body: JsonObject): String { identifier(required(body, "requestId", limit: 100)) }
func allowedFields(body: JsonObject, keys: Array<String>): Unit {
    for ((key, _) in body.getFields()) {
        var accepted = key == "domainId" || key == "userId"
        for (candidate in keys) { if (key == candidate) { accepted = true } }
        if (!accepted) { fail("VALIDATION_ERROR") }
    }
}
func alias(body: JsonObject): String {
    let value = required(body, "contactAlias", limit: 64)
    if (!value.startsWith("SYN-CONTACT-")) { fail("VALIDATION_ERROR") }
    return identifier(value)
}
func utcNow(): DateTime { DateTime.nowUTC() }
func iso(time: DateTime): String { time.inUTC().format("yyyy-MM-ddTHH:mm:ss") + "Z" }
func validAt(record: JsonObject, now: DateTime): Bool {
    if (str(record, "temporalStatus") != "known_current" || record["revoked"].asBool().getValue()) { return false }
    if (!(record["effectiveFrom"] is JsonString) || !(record["effectiveTo"] is JsonString)) { return false }
    let begin = DateTime.tryParse(str(record, "effectiveFrom"))
    let end = DateTime.tryParse(str(record, "effectiveTo"))
    if (let Some(a) <- begin) { if (let Some(b) <- end) { return a <= now && now < b } }
    return false
}
func has(values: JsonArray, value: String): Bool {
    for (v in values.getItems()) { if (v.asString().getValue() == value) { return true } }
    return false
}

struct Identity {
    Identity(let user: String, let domain: String, let role: String, let area: String) {}
}
func identity(session: String): Identity {
    match (session) {
        case "campus-user" => Identity("user-syn-campus-001", "campus-demo", "student", "SYN_CAMPUS_A")
        case "community-user" => Identity("user-syn-community-001", "community-demo", "resident", "SYN_COMMUNITY_A")
        case "campus-worker" => Identity("worker-syn-campus-001", "campus-demo", "staff", "SYN_CAMPUS_A")
        case "community-worker" => Identity("worker-syn-community-001", "community-demo", "staff", "SYN_COMMUNITY_A")
        case "campus-test-peer" => testPeerIdentity()
        case _ => fail("UNAUTHORIZED")
    }
}
func testPeerIdentity(): Identity {
    if ((getVariable("ICT_ENABLE_TEST_FAULTS") ?? "") != "1") { fail("UNAUTHORIZED") }
    return Identity("user-syn-campus-002", "campus-demo", "student", "SYN_CAMPUS_A")
}
func checkContext(body: JsonObject, who: Identity): Unit {
    if ((body.containsKey("domainId") && str(body, "domainId") != who.domain) ||
        (body.containsKey("userId") && str(body, "userId") != who.user) ||
        body.containsKey("roles") || body.containsKey("authContext") || body.containsKey("campus")) { fail("FORBIDDEN") }
}
func owner(record: JsonObject, who: Identity, staff!: Bool = false): Unit {
    if (str(record, "domainId") != who.domain || (str(record, "userId") != who.user && !(staff && who.role == "staff"))) {
        fail("FORBIDDEN")
    }
}
