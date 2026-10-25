package ict_backend

import std.collection.*
import std.env.*
import std.io.*
import std.sync.*
import stdx.encoding.json.*
import stdx.net.http.*

func envelope(code: String, data: JsonValue, trace: String): JsonObject {
    let r = obj(); r.put("code", s(code)); r.put("message", s(if (code == "OK") { "ok" } else { code }))
    r.put("data", data); r.put("traceId", s(trace)); return r
}
func statusFor(code: String): UInt16 {
    match (code) {
        case "OK" => 200
        case "VALIDATION_ERROR" => 400
        case "UNAUTHORIZED" => 401
        case "FORBIDDEN" => 403
        case "NOT_FOUND" => 404
        case "SERVICE_UNAVAILABLE" => 503
        case _ => 409
    }
}

class StreamCounters {
    let mutex = Mutex()
    var active: Int64 = 0
    var completed: Int64 = 0
    var cancelled: Int64 = 0
    var incomplete: Int64 = 0
    func open(): Unit { synchronized(mutex) { active++ } }
    func finish(terminal: Bool, interrupted: Bool): Unit {
        synchronized(mutex) {
            active--
            if (terminal) { completed++ } else if (interrupted) { cancelled++ } else { incomplete++ }
        }
    }
    func snapshot(): JsonObject {
        synchronized(mutex) {
            let r = obj(); r.put("active", n(active)); r.put("completed", n(completed)); r.put("cancelled", n(cancelled)); r.put("incomplete", n(incomplete)); return marked(r)
        }
    }
}

func event(name: String, payload: JsonObject): Array<Byte> { ("event: " + name + "\ndata: " + marked(payload).toString() + "\n\n").toArray() }

class EventStream <: InputStream & Resource {
    let events = ArrayList<Array<Byte>>()
    let ctx: HttpContext
    let counters: StreamCounters
    let delay: Int64
    let complete: Bool
    var cursor: Int64 = 0
    var offset: Int64 = 0
    var closed = false
    let streamGate = Mutex()

    init(answer: JsonObject, trace: String, fault: String, ctx: HttpContext, counters: StreamCounters) {
        this.ctx = ctx; this.counters = counters
        delay = if (fault == "slow") { 80 } else { 20 }
        complete = fault != "disconnect"
        let meta = obj()
        for (key in ["requestId", "conversationId", "evidenceRefs"]) { meta.put(key, answer[key]) }
        meta.put("traceId", s(trace)); events.add(event("meta", meta))
        if (!str(answer, "fallbackReason").isEmpty()) {
            let err = obj(); err.put("code", s(str(answer, "fallbackReason"))); err.put("message", s("已使用确定性检索回答")); err.put("canFallback", flag(true))
            events.add(event("error", err))
        }
        let runes = str(answer, "answer").toRuneArray()
        var i: Int64 = 0
        while (i < runes.size) {
            let delta = obj(); delta.put("text", s(String(runes[i..min(i + 24, runes.size)])))
            events.add(event("delta", delta)); i += 24
            if (!complete) { break }
        }
        if (complete) {
            let done = obj(); done.put("status", s("COMPLETED"))
            if (!str(answer, "fallbackReason").isEmpty()) { done.put("fallbackReason", s(str(answer, "fallbackReason"))) }
            events.add(event("done", done))
        }
        counters.open()
    }

    public func read(buffer: Array<Byte>): Int64 {
        synchronized(streamGate) {
            if (buffer.isEmpty()) { return 0 }
            if (closed) { return 0 }
            if (ctx.isClosed()) { close(); return 0 }
            if (cursor >= events.size) {
                closed = true; counters.finish(complete, false); return 0
            }
            if (offset == 0 && cursor > 0) { sleep(Duration.millisecond * delay) }
            if (ctx.isClosed()) { close(); return 0 }
            let bytes = events[cursor]
            let size = min(buffer.size, bytes.size - offset)
            for (i in 0..size) { buffer[i] = bytes[offset + i] }
            offset += size
            if (offset == bytes.size) { cursor++; offset = 0 }
            return size
        }
    }

    public func close(): Unit {
        if (!closed) { closed = true; counters.finish(false, true) }
    }
    public func isClosed(): Bool { closed }
}

class ApiHandler <: HttpRequestHandler {
    let business: Business
    let auth: Auth
    let counters = StreamCounters()
    let cors: Array<String>
    let traceGate = Mutex()
    var sequence: Int64 = 0

    init(business: Business, auth: Auth, cors: Array<String>) {
        this.business = business; this.auth = auth; this.cors = cors
    }
    func traceId(): String { synchronized(traceGate) { sequence++; return "trace-${getProcessId()}-${sequence}" } }

    func readBody(ctx: HttpContext): JsonObject {
        let chunks = ArrayList<Byte>()
        let buffer = Array<Byte>(4096, repeat: 0)
        while (true) {
            let count = ctx.request.body.read(buffer)
            if (count == 0) { break }
            if (chunks.size + count > 32768) { fail("VALIDATION_ERROR") }
            for (i in 0..count) { chunks.add(buffer[i]) }
        }
        if (chunks.isEmpty()) { return obj() }
        if (!(ctx.request.headers.getFirst("Content-Type") ?? "").toAsciiLower().startsWith("application/json")) { fail("VALIDATION_ERROR") }
        try { return JsonValue.fromStr(String.fromUtf8(chunks.toArray())).asObject() }
        catch (_: Exception) { fail("VALIDATION_ERROR") }
    }

    // Authentication endpoints live in the transport layer, not in Business: they mint and
    // revoke sessions, and they must not pass through the business permission checks that
    // assume an identity already exists.
    func authRoute(method: String, path: String, body: JsonObject, session: String): JsonObject {
        if (path == "/api/v1/auth/login" && method == "POST") {
            let username = required(body, "username", limit: 64)
            let password = required(body, "password", limit: 128)
            return auth.login(username, password)
        }
        if (path == "/api/v1/auth/logout" && method == "POST") { return auth.logout(session) }
        if (path == "/api/v1/auth/me" && method == "GET") {
            let who = auth.resolve(session)
            let r = obj()
            r.put("userId", s(who.user)); r.put("domain", s(who.domain))
            r.put("role", s(who.role)); r.put("area", s(who.area))
            r.put("authMode", s(auth.mode))
            return r
        }
        if (path == "/api/v1/auth/stats" && method == "GET") {
            if (auth.resolve(session).role != "staff") { fail("FORBIDDEN") }
            return auth.stats()
        }
        fail("NOT_FOUND")
    }

    public func handle(ctx: HttpContext): Unit {
        let trace = traceId()
        try {
            let origin = ctx.request.headers.getFirst("Origin") ?? ""
            if (!origin.isEmpty()) {
                var allowed = false
                for (source in cors) { if (source == origin) { allowed = true } }
                if (!allowed) { fail("FORBIDDEN") }
                ctx.responseBuilder.header("Access-Control-Allow-Origin", origin).header("Vary", "Origin")
                    .header("Access-Control-Allow-Methods", "GET,POST,PATCH,OPTIONS")
                    .header("Access-Control-Allow-Headers", "Content-Type,Authorization,X-Demo-Session,Idempotency-Key,X-Demo-Fault")
            }
            ctx.responseBuilder.header("Cache-Control", "no-store").header("X-Content-Type-Options", "nosniff")
            let method = ctx.request.method
            if (method == "OPTIONS") { ctx.responseBuilder.status(204).body(""); return }
            let path = ctx.request.url.path
            let query = obj()
            for (key in ["date", "kind", "domainId", "userId", "roles", "campus"]) {
                if (let Some(value) <- ctx.request.url.queryForm.get(key)) { query.put(key, s(value)) }
            }
            let body = readBody(ctx)
            // A session may arrive as X-Demo-Session (existing clients) or as a Bearer
            // token (anything that speaks normal HTTP auth). Both are opaque strings here;
            // Auth decides whether the value is an issued token or a static demo name.
            var session = ctx.request.headers.getFirst("X-Demo-Session") ?? ""
            let authorization = ctx.request.headers.getFirst("Authorization") ?? ""
            if (session.isEmpty() && authorization.startsWith("Bearer ")) {
                session = String(authorization.toRuneArray()[7..])
            }
            let key = ctx.request.headers.getFirst("Idempotency-Key") ?? ""
            if (path.startsWith("/api/v1/auth/")) {
                let result = authRoute(method, path, body, session)
                ctx.responseBuilder.status(200).header("Content-Type", "application/json; charset=utf-8")
                    .body(envelope("OK", result, trace).toString())
                return
            }
            if (path == "/api/v1/debug/streams" && method == "GET") {
                if ((getVariable("ICT_ENABLE_TEST_FAULTS") ?? "") != "1" || auth.resolve(session).role != "staff") { fail("FORBIDDEN") }
                ctx.responseBuilder.header("Content-Type", "application/json; charset=utf-8").body(envelope("OK", counters.snapshot(), trace).toString()); return
            }
            let fault = ctx.request.headers.getFirst("X-Demo-Fault") ?? ""
            let testFaults = (getVariable("ICT_ENABLE_TEST_FAULTS") ?? "") == "1"
            if (!fault.isEmpty() && !testFaults) { fail("VALIDATION_ERROR") }
            let answer = business.execute(method, path, query, body, session, key, failSave: testFaults && fault == "save-failure")
            if ((ctx.request.headers.getFirst("X-Demo-Fault") ?? "") == "response-loss" &&
                (getVariable("ICT_ENABLE_TEST_FAULTS") ?? "") == "1" && method == "POST" && !key.isEmpty()) { fail("SERVICE_UNAVAILABLE") }
            if (path == "/api/v1/chat/stream" && method == "POST") {
                ctx.responseBuilder.header("Content-Type", "text/event-stream; charset=utf-8")
                    .header("Transfer-Encoding", "chunked")
                let stream = EventStream(answer, trace, str(body, "mockFault"), ctx, counters)
                let writer = HttpResponseWriter(ctx)
                let bytes = Array<Byte>(4096, repeat: 0)
                try {
                    while (true) {
                        let count = stream.read(bytes)
                        if (count == 0) { break }
                        writer.write(bytes[0..count])
                    }
                } catch (_: Exception) {
                    println("stream-cancelled trace=${trace}")
                } finally { stream.close() }
            } else {
                ctx.responseBuilder.status(200).header("Content-Type", "application/json; charset=utf-8").body(envelope("OK", answer, trace).toString())
            }
        } catch (e: BusinessError) {
            ctx.responseBuilder.status(statusFor(e.code)).header("Content-Type", "application/json; charset=utf-8").body(envelope(e.code, marked(obj()), trace).toString())
        } catch (_: Exception) {
            ctx.responseBuilder.status(503).header("Content-Type", "application/json; charset=utf-8").body(envelope("SERVICE_UNAVAILABLE", marked(obj()), trace).toString())
            println("request-failed trace=${trace}")
        }
    }
}

class ApiDistributor <: HttpRequestDistributor {
    let handler: HttpRequestHandler
    init(handler: HttpRequestHandler) { this.handler = handler }
    public func register(_: String, _: HttpRequestHandler): Unit { throw Exception("register is unsupported") }
    public func distribute(_: String): HttpRequestHandler { handler }
}
