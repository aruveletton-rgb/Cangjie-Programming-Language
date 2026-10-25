package ict_backend

// Server-side identity and permission layer.
//
// Why this exists (plan week 9: "先补服务端身份与权限，不公开静态工作人员会话"):
// the previous build authenticated by mapping a literal header value to an identity
// (`X-Demo-Session: campus-worker` -> staff). Anyone who guessed the string became
// staff, and the string was printed in the startup banner and in the docs. That is
// fine for a loopback demo and unacceptable once the service is reachable from a
// test terminal.
//
// This module adds:
//   - Credentials: operator-supplied users with salted SHA-256 password digests.
//     Plaintext passwords are never stored and never logged.
//   - SessionStore: opaque random tokens issued by the server, with server-side
//     expiry, revocation and counters. Tokens are not derived from the user name,
//     so a token cannot be guessed from an identity.
//   - Auth: one place that decides whether a request may use a static demo token.
//     In "session" mode static tokens are rejected outright; in "demo" mode they
//     keep working so local development and the existing regression suite stay
//     runnable. main.cj additionally refuses to start with demo mode when a public
//     origin is configured, so the relaxed mode cannot reach the internet by
//     accident.
//
// Limitations, stated rather than hidden:
//   - Password and token comparisons go through constantTimeEquals, so they no longer
//     early-exit on the first differing byte. This is a timing-hardening measure, not a
//     formal cryptographic primitive; digests remain a single SHA-256 over salt +
//     password, and the username lookup still early-exits because a user name is not
//     secret. An unknown user burns the same one SHA-256 as a wrong password, so the
//     endpoint does not answer "no such user" measurably faster than "wrong password".
//   - Login throttling is per-username (LoginGuard). It stops unlimited online guessing,
//     but an attacker who knows a victim's user name can keep that name locked; the
//     alternative (per-source limits) is meaningless behind the TLS proxy, where every
//     request shares one source. Tunables are env vars; counters are in
//     /api/v1/auth/stats (staff only).
//   - Sessions live in process memory only; a restart invalidates every token.
//     That is intentional for a demo (fail closed) and is recorded in the week-9
//     ledger as a known limitation, not as a defect.

import std.collection.*
import std.env.*
import std.random.*
import std.sync.*
import std.time.*
import stdx.crypto.digest.*
import stdx.encoding.hex.*
import stdx.encoding.json.*

func sha256Hex(text: String): String {
    let md = SHA256()
    md.write(text.toArray())
    return toHexString(md.finish())
}

// Byte-wise comparison that never returns early on content: it walks the longer
// operand, folds every position into one accumulator, and reports the folded result.
// Length mismatch is handled by treating the missing tail as zeros, so unequal lengths
// compare unequal without revealing how much of the shorter operand matched. The final
// `diff == 0` branch is inherent to any boolean comparison API; what this removes is the
// data-dependent early exit inside the loop.
func constantTimeEquals(a: String, b: String): Bool {
    let x = a.toArray()
    let y = b.toArray()
    let zero: UInt8 = 0
    var diff: UInt8 = 0
    let n = if (x.size > y.size) { x.size } else { y.size }
    var i = 0
    while (i < n) {
        let cv = if (i < x.size) { x[i] } else { zero }
        let cw = if (i < y.size) { y[i] } else { zero }
        diff = diff | (cv ^ cw)
        i++
    }
    return diff == 0
}

struct AuthUser {
    AuthUser(let username: String, let salt: String, let passwordHash: String,
             let userId: String, let domain: String, let role: String, let area: String) {}
}

// Operator-supplied user table.
//
// Spec shape (inline JSON or a file with the same content):
//   { "users": [ { "username": "...", "salt": "...", "passwordHash": "<sha256 hex>",
//                  "userId": "...", "domain": "campus-demo", "role": "staff",
//                  "area": "SYN_CAMPUS_A" } ] }
//
// passwordHash must be sha256Hex(salt + password). The generator script
// (src/backend/deploy/make-auth-users.mjs) produces this shape so nobody has to
// compute a digest by hand.
class Credentials {
    let users = ArrayList<AuthUser>()

    init(spec: String) {
        if (!spec.trimAscii().isEmpty()) {
            let parsed = JsonValue.fromStr(spec).asObject()
            for (item in array(parsed, "users").getItems()) {
                let u = item.asObject()
                let role = required(u, "role", limit: 16)
                if (role != "student" && role != "resident" && role != "staff") { fail("VALIDATION_ERROR") }
                users.add(AuthUser(
                    required(u, "username", limit: 64),
                    required(u, "salt", limit: 128),
                    required(u, "passwordHash", limit: 128),
                    required(u, "userId", limit: 100),
                    required(u, "domain", limit: 64),
                    role,
                    required(u, "area", limit: 64)))
            }
            if (users.isEmpty()) { fail("VALIDATION_ERROR") }
        }
    }

    func configured(): Bool { return !users.isEmpty() }

    func size(): Int64 { return users.size }    // Returns the bound identity, or UNAUTHORIZED. Unknown user and wrong password
    // deliberately produce the same code so the response does not enumerate accounts.
    //
    // They also deliberately cost the same work: exactly one SHA-256 and one
    // constant-time compare each. Without the dummy computation below, "unknown user"
    // would skip the digest and return measurably earlier than "wrong password", which
    // turns this endpoint into a username oracle even with the shared failure code.
    func authenticate(username: String, password: String): Identity {
        var index = -1
        for (i in 0..users.size) {
            if (users[i].username == username) { index = i; break }
        }
        var digest = ""
        var stored = ""
        if (index >= 0) {
            digest = sha256Hex(users[index].salt + password)
            stored = users[index].passwordHash
        } else {
            digest = sha256Hex("ict-unknown-user-salt" + password)
            stored = "0000000000000000000000000000000000000000000000000000000000000000"
        }
        if (!constantTimeEquals(digest, stored)) { fail("UNAUTHORIZED") }
        let u = users[index]
        return Identity(u.userId, u.domain, u.role, u.area)
    }
}

// Per-username login throttle.
//
// Why per-username and not per-source: behind the TLS proxy every request arrives from
// 127.0.0.1, so a source limit would either lock out everyone or no one. A username
// limit stops unlimited online password guessing; its cost is that an attacker who
// knows a victim's user name can keep that name locked. That trade-off is documented in
// the module header rather than hidden.
//
// Semantics:
//   - maxFailures failures of ONE username inside windowSeconds lock that username for
//     lockoutSeconds. The clock is injectable (same pattern as SessionStore) so tests
//     are deterministic.
//   - A locked username is rejected with the same UNAUTHORIZED code as a wrong password;
//     the guard must not create a new observable difference. Counter lockRejects keeps
//     the behaviour visible to the operator via stats().
//   - Failures outside the window do not accumulate; a successful login clears the
//     counter; hammering during an active lock does not extend the lock.
class LoginGuard {
    let gate = Mutex()
    let maxFailures: Int64
    let windowSeconds: Int64
    let lockoutSeconds: Int64
    let clock: () -> DateTime
    var states = HashMap<String, LoginFailState>()
    var lockRejects: Int64 = 0
    var lockEvents: Int64 = 0

    init(maxFailures!: Int64 = 10, windowSeconds!: Int64 = 300, lockoutSeconds!: Int64 = 600,
         clock!: () -> DateTime = { => utcNow() }) {
        if (maxFailures < 1 || windowSeconds < 1 || lockoutSeconds < 1) { fail("VALIDATION_ERROR") }
        this.maxFailures = maxFailures
        this.windowSeconds = windowSeconds
        this.lockoutSeconds = lockoutSeconds
        this.clock = clock
    }

    func check(username: String): Unit {
        synchronized(gate) {
            let s = states.get(username)
            if (s.isSome()) {
                let lockedUntil = s.getOrThrow().lockedUntil
                if (lockedUntil.isSome() && clock() < lockedUntil.getOrThrow()) {
                    lockRejects++
                    fail("UNAUTHORIZED")
                }
            }
        }
    }

    func recordFailure(username: String): Unit {
        synchronized(gate) {
            let now = clock()
            let prev = states.get(username)
            if (prev.isSome()) {
                let state = prev.getOrThrow()
                if (state.lockedUntil.isSome() && now < state.lockedUntil.getOrThrow()) {
                    // Already locked: keep the lock as-is. Hammering must not extend it.
                    return
                }
            }
            var failures: Int64 = 1
            var windowStart = now
            if (prev.isSome()) {
                let state = prev.getOrThrow()
                if (now - state.windowStart <= Duration.second * windowSeconds) {
                    failures = state.failures + 1
                    windowStart = state.windowStart
                }
            }
            if (failures >= maxFailures) {
                lockEvents++
                states[username] = LoginFailState(0, now, Some(now + Duration.second * lockoutSeconds))
            } else {
                states[username] = LoginFailState(failures, windowStart, None)
            }
        }
    }

    func recordSuccess(username: String): Unit {
        synchronized(gate) {
            let s = states.get(username)
            if (s.isSome()) {
                let lockedUntil = s.getOrThrow().lockedUntil
                if (lockedUntil.isSome() && clock() < lockedUntil.getOrThrow()) {
                    // Defensive: a correct password during an active lock must not clear
                    // it. Unreachable while callers go through check() first, and this
                    // keeps that invariant true even if a caller forgets.
                    return
                }
            }
            let _ = states.remove(username)
        }
    }

    func stats(): JsonObject {
        var tracked: Int64 = 0
        var locked: Int64 = 0
        synchronized(gate) {
            let now = clock()
            for ((name, state) in states) {
                tracked++
                let lockedUntil = state.lockedUntil
                if (lockedUntil.isSome() && now < lockedUntil.getOrThrow()) { locked++ }
            }
        }
        let r = obj()
        r.put("trackedUsernames", n(tracked))
        r.put("lockedUsernames", n(locked))
        r.put("lockRejectsTotal", n(lockRejects))
        r.put("lockEventsTotal", n(lockEvents))
        r.put("maxFailures", n(maxFailures))
        r.put("windowSeconds", n(windowSeconds))
        r.put("lockoutSeconds", n(lockoutSeconds))
        return r
    }
}

struct LoginFailState {
    LoginFailState(let failures: Int64, let windowStart: DateTime, let lockedUntil: Option<DateTime>) {}
}

class SessionStore {
    let gate = Mutex()
    let ttl: Int64
    let clock: () -> DateTime
    let maxSessions: Int64
    let random = Random()
    var sessions = ArrayList<JsonObject>()
    var issuedCount: Int64 = 0
    var expiredCount: Int64 = 0
    var revokedCount: Int64 = 0
    var rejectedCount: Int64 = 0

    init(ttl: Int64, clock!: () -> DateTime = { => utcNow() }, maxSessions!: Int64 = 256) {
        this.ttl = ttl; this.clock = clock; this.maxSessions = maxSessions
    }

    // 4 x 64 random bits rendered as decimal. The token carries no user information,
    // so knowing a user name tells an attacker nothing about the token.
    func newToken(): String {
        let head = "sess-" + random.nextUInt64().toString() + "-" + random.nextUInt64().toString()
        return head + "-" + random.nextUInt64().toString() + "-" + random.nextUInt64().toString()
    }

    // Drop revoked and expired records so the table does not grow without bound.
    func prune(now: DateTime): Unit {
        let kept = ArrayList<JsonObject>()
        for (i in 0..sessions.size) {
            let item = sessions[i]
            if (item["revoked"].asBool().getValue()) { continue }
            if (now >= DateTime.parse(item["expiresAt"].asString().getValue())) { continue }
            kept.add(item)
        }
        sessions = kept
    }

    func issue(who: Identity): JsonObject {
        var reply = obj()
        synchronized(gate) {
            let now = clock()
            prune(now)
            if (sessions.size >= maxSessions) { fail("SERVICE_UNAVAILABLE") }
            let token = newToken()
            let expires = iso(now + Duration.second * ttl)
            let record = obj()
            record.put("token", s(token))
            record.put("userId", s(who.user))
            record.put("domain", s(who.domain))
            record.put("role", s(who.role))
            record.put("area", s(who.area))
            record.put("issuedAt", s(iso(now)))
            record.put("expiresAt", s(expires))
            record.put("revoked", flag(false))
            sessions.add(record)
            issuedCount++
            reply.put("token", s(token))
            reply.put("userId", s(who.user))
            reply.put("domain", s(who.domain))
            reply.put("role", s(who.role))
            reply.put("area", s(who.area))
            reply.put("issuedAt", s(iso(now)))
            reply.put("expiresAt", s(expires))
            reply.put("ttlSeconds", n(ttl))
        }
        return reply
    }

    func resolve(token: String): Identity {
        if (token.isEmpty()) { fail("UNAUTHORIZED") }
        var index: Int64 = -1
        synchronized(gate) {
            let now = clock()
            for (i in 0..sessions.size) {
                if (constantTimeEquals(sessions[i]["token"].asString().getValue(), token)) { index = i; break }
            }
            if (index >= 0) {
                if (sessions[index]["revoked"].asBool().getValue()) { revokedCount++; index = -1 }
                else if (now >= DateTime.parse(sessions[index]["expiresAt"].asString().getValue())) { expiredCount++; index = -1 }
            } else {
                rejectedCount++
            }
        }
        if (index < 0) { fail("UNAUTHORIZED") }
        let item = sessions[index]
        return Identity(item["userId"].asString().getValue(), item["domain"].asString().getValue(),
                        item["role"].asString().getValue(), item["area"].asString().getValue())
    }

    func revoke(token: String): Bool {
        var done = false
        synchronized(gate) {
            for (i in 0..sessions.size) {
                if (constantTimeEquals(sessions[i]["token"].asString().getValue(), token)) {
                    if (!sessions[i]["revoked"].asBool().getValue()) {
                        sessions[i].put("revoked", flag(true)); revokedCount++; done = true
                    }
                    break
                }
            }
        }
        return done
    }

    // Counters are part of the evidence: they show that expiry and revocation were
    // actually exercised, rather than only implemented.
    func stats(): JsonObject {
        var active: Int64 = 0
        synchronized(gate) {
            let now = clock()
            for (i in 0..sessions.size) {
                let item = sessions[i]
                if (item["revoked"].asBool().getValue()) { continue }
                if (now >= DateTime.parse(item["expiresAt"].asString().getValue())) { continue }
                active++
            }
        }
        let r = obj()
        r.put("activeSessions", n(active))
        r.put("issuedTotal", n(issuedCount))
        r.put("expiredTotal", n(expiredCount))
        r.put("revokedTotal", n(revokedCount))
        r.put("rejectedTotal", n(rejectedCount))
        r.put("ttlSeconds", n(ttl))
        r.put("maxSessions", n(maxSessions))
        return r
    }
}

class Auth {
    let mode: String
    let sessions: SessionStore
    let credentials: Credentials
    let throttle: LoginGuard

    init(mode: String, sessions: SessionStore, credentials!: Credentials = Credentials(""),
         throttle!: LoginGuard = LoginGuard()) {
        this.mode = mode; this.sessions = sessions; this.credentials = credentials; this.throttle = throttle
    }

    func demoMode(): Bool { return mode == "demo" }

    // Single decision point for "may this header value act as an identity?".
    // Issued tokens are always accepted; static tokens only in demo mode.
    func resolve(session: String): Identity {
        if (session.startsWith("sess-")) { return sessions.resolve(session) }
        if (demoMode()) { return identity(session) }
        fail("UNAUTHORIZED")
    }

    func login(username: String, password: String): JsonObject {
        if (!credentials.configured()) { fail("SERVICE_UNAVAILABLE") }
        // The guard runs before the digest: a locked username costs no SHA-256 at all.
        throttle.check(username)
        var who: Identity
        try {
            who = credentials.authenticate(username, password)
        } catch (e: BusinessError) {
            throttle.recordFailure(username)
            throw e
        }
        // Only a real credential success clears the counter; a failure of the session
        // store below (e.g. the table is full) is not the user's fault and must not
        // count toward lockout.
        throttle.recordSuccess(username)
        return sessions.issue(who)
    }

    func logout(session: String): JsonObject {
        let who = resolve(session)
        let done = sessions.revoke(session)
        let r = obj()
        r.put("revoked", flag(done))
        r.put("userId", s(who.user))
        return r
    }

    // Reported by /health so a reader never has to guess which mode is active.
    func describe(): String {
        if (demoMode()) { return "static-demo-sessions-not-for-public-exposure" }
        if (credentials.configured()) { return "issued-server-side-sessions" }
        return "issued-server-side-sessions-no-credentials"
    }

    // Staff-visible aggregate. Merged here so the transport layer does not need to know
    // the internal shape of the session store and the login guard.
    func stats(): JsonObject {
        let r = sessions.stats()
        r.put("loginGuard", throttle.stats())
        return r
    }
}
