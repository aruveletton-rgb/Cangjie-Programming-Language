package ict_backend

// Tests for the week-9 identity layer and the store commit path.
//
// These are deliberately written against the failure modes that matter, not against
// happy paths only: a token that outlives its TTL, a revoked token that still works,
// a static staff token accepted in session mode, and a half-written store file being
// loaded as if it were committed.

import std.env.*
import std.fs.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json.*

func authSpec(): String {
    let digest = sha256Hex("s1pass1")
    let head = "{\"users\":[{\"username\":\"worker1\",\"salt\":\"s1\",\"passwordHash\":\"" + digest
    let mid = "\",\"userId\":\"worker-syn-campus-001\",\"domain\":\"campus-demo\",\"role\":\"staff\",\"area\":\"SYN_CAMPUS_A\"},"
    let tail = "{\"username\":\"student1\",\"salt\":\"s2\",\"passwordHash\":\"" + sha256Hex("s2pass2")
    let end = "\",\"userId\":\"user-syn-campus-001\",\"domain\":\"campus-demo\",\"role\":\"student\",\"area\":\"SYN_CAMPUS_A\"}]}"
    return head + mid + tail + end
}

// Returns the role the token resolves to, or the failure code. Keeps every assertion a
// plain string comparison, so a wrong branch cannot pass by accident.
func roleFor(auth: Auth, token: String): String {
    try { return auth.resolve(token).role } catch (e: BusinessError) { return e.code }
    return "NO-RESULT"
}

func loginOutcome(auth: Auth, username: String, password: String): String {
    try { return "OK:" + str(auth.login(username, password), "role") } catch (e: BusinessError) { return e.code }
    return "NO-RESULT"
}

@Test
class AuthTests {
    @TestCase
    func loginIssuesOpaqueTokenBoundToTheRightIdentity() {
        let tick = TestClock(DateTime.parse("2026-10-24T00:00:00Z"))
        let auth = Auth("session", SessionStore(600, clock: { => tick.time }), credentials: Credentials(authSpec()))
        let reply = auth.login("worker1", "pass1")
        let token = str(reply, "token")
        @Expect(token.startsWith("sess-"), true)
        @Expect(token.size > 40, true)
        @Expect(str(reply, "role"), "staff")
        @Expect(str(reply, "userId"), "worker-syn-campus-001")
        @Expect(integer(reply, "ttlSeconds"), 600)
        // The reply must never echo a credential back to the caller.
        @Expect(reply.containsKey("password"), false)
        @Expect(reply.containsKey("passwordHash"), false)
        let who = auth.resolve(token)
        @Expect(who.user, "worker-syn-campus-001")
        @Expect(who.domain, "campus-demo")
        @Expect(who.role, "staff")
        @Expect(who.area, "SYN_CAMPUS_A")
    }

    @TestCase
    func tokensAreUnpredictableAndDistinctPerLogin() {
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()))
        let first = str(auth.login("worker1", "pass1"), "token")
        let second = str(auth.login("worker1", "pass1"), "token")
        @Expect(first == second, false)
        @Expect(first.size > 40, true)
        // A token must not encode the user name it belongs to.
        @Expect(first.contains("worker1"), false)
    }

    @TestCase
    func wrongPasswordAndUnknownUserShareOneFailureCode() {
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()))
        @Expect(loginOutcome(auth, "worker1", "wrong"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "ghost", "pass1"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "worker1", ""), "UNAUTHORIZED")
        // The distinction between the two cases must not be observable from the code alone.
        @Expect(loginOutcome(auth, "worker1", "wrong") == loginOutcome(auth, "ghost", "wrong"), true)
    }

    @TestCase
    func sessionExpiresExactlyAtItsTtl() {
        let tick = TestClock(DateTime.parse("2026-10-24T00:00:00Z"))
        let store = SessionStore(60, clock: { => tick.time })
        let auth = Auth("session", store, credentials: Credentials(authSpec()))
        let token = str(auth.login("worker1", "pass1"), "token")
        tick.time = DateTime.parse("2026-10-24T00:00:59Z")
        @Expect(roleFor(auth, token), "staff")
        tick.time = DateTime.parse("2026-10-24T00:01:00Z")
        @Expect(roleFor(auth, token), "UNAUTHORIZED")
        @Expect(integer(store.stats(), "expiredTotal"), 1)
    }

    @TestCase
    func logoutRevokesImmediately() {
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()))
        let token = str(auth.login("worker1", "pass1"), "token")
        @Expect(roleFor(auth, token), "staff")
        let receipt = auth.logout(token)
        @Expect(receipt["revoked"].asBool().getValue(), true)
        @Expect(roleFor(auth, token), "UNAUTHORIZED")
        // Logging out twice is not an error, but it must not resurrect the session.
        @Expect(roleFor(auth, token), "UNAUTHORIZED")
    }

    @TestCase
    func sessionModeRejectsEveryStaticToken() {
        let strict = Auth("session", SessionStore(600), credentials: Credentials(authSpec()))
        for (name in ["campus-user", "campus-worker", "community-user", "community-worker", "campus-test-peer"]) {
            @Expect(roleFor(strict, name), "UNAUTHORIZED")
        }
        @Expect(roleFor(strict, ""), "UNAUTHORIZED")
        // An unknown issued-looking token must not fall through to the static table either.
        @Expect(roleFor(strict, "sess-forged"), "UNAUTHORIZED")
    }

    @TestCase
    func demoModeStillAcceptsStaticTokensForLocalDevelopment() {
        let demo = Auth("demo", SessionStore(600))
        @Expect(roleFor(demo, "campus-user"), "student")
        @Expect(roleFor(demo, "campus-worker"), "staff")
        @Expect(roleFor(demo, "unknown-name"), "UNAUTHORIZED")
    }

    @TestCase
    func loginWithoutConfiguredCredentialsIsUnavailableNotSilent() {
        let bare = Auth("session", SessionStore(600))
        @Expect(loginOutcome(bare, "worker1", "pass1"), "SERVICE_UNAVAILABLE")
        @Expect(bare.describe(), "issued-server-side-sessions-no-credentials")
    }

    @TestCase
    func countersProveExpiryAndRevocationWereExercised() {
        let tick = TestClock(DateTime.parse("2026-10-24T00:00:00Z"))
        let store = SessionStore(60, clock: { => tick.time })
        let auth = Auth("session", store, credentials: Credentials(authSpec()))
        let shortLived = str(auth.login("worker1", "pass1"), "token")
        let revoked = str(auth.login("worker1", "pass1"), "token")
        auth.logout(revoked)
        tick.time = DateTime.parse("2026-10-24T00:02:00Z")
        @Expect(roleFor(auth, shortLived), "UNAUTHORIZED")
        @Expect(roleFor(auth, "sess-never-issued"), "UNAUTHORIZED")
        let stats = store.stats()
        @Expect(integer(stats, "issuedTotal"), 2)
        @Expect(integer(stats, "revokedTotal"), 1)
        @Expect(integer(stats, "expiredTotal"), 1)
        @Expect(integer(stats, "rejectedTotal"), 1)
        @Expect(integer(stats, "activeSessions"), 0)
    }

    @TestCase
    func credentialsRejectMalformedOrUnknownRoles() {
        let badHead = "{\"users\":[{\"username\":\"u\",\"salt\":\"s\",\"passwordHash\":\"" + sha256Hex("sp")
        let badRole = badHead + "\",\"userId\":\"x\",\"domain\":\"campus-demo\",\"role\":\"admin\",\"area\":\"A\"}]}"
        var code = ""
        try { Credentials(badRole) } catch (e: BusinessError) { code = e.code }
        @Expect(code, "VALIDATION_ERROR")
        // An empty spec is legal and means "no users configured"; it must not throw.
        @Expect(Credentials("").configured(), false)
        @Expect(Credentials(authSpec()).size(), 2)
    }

    @TestCase
    func constantTimeComparisonBehavesLikeEquality() {
        @Expect(constantTimeEquals("abc", "abc"), true)
        @Expect(constantTimeEquals("abc", "abd"), false)
        @Expect(constantTimeEquals("abc", "ab"), false)
        @Expect(constantTimeEquals("ab", "abc"), false)
        @Expect(constantTimeEquals("", ""), true)
        @Expect(constantTimeEquals("", "a"), false)
        // Real digests: equal content equal, one-byte difference unequal.
        @Expect(constantTimeEquals(sha256Hex("same"), sha256Hex("same")), true)
        @Expect(constantTimeEquals(sha256Hex("same"), sha256Hex("other")), false)
    }

    @TestCase
    func repeatedFailuresLockTheUsernameEvenWithTheCorrectPassword() {
        let tick = TestClock(DateTime.parse("2026-10-24T00:00:00Z"))
        let throttle = LoginGuard(maxFailures: 2, windowSeconds: 300, lockoutSeconds: 600, clock: { => tick.time })
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()), throttle: throttle)
        @Expect(loginOutcome(auth, "worker1", "nope"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "worker1", "nope"), "UNAUTHORIZED")
        // Threshold reached: the CORRECT password is now rejected with the same code.
        @Expect(loginOutcome(auth, "worker1", "pass1"), "UNAUTHORIZED")
        @Expect(integer(throttle.stats(), "lockEventsTotal"), 1)
        @Expect(integer(throttle.stats(), "lockRejectsTotal"), 1)
        // A different username is unaffected by worker1's lock.
        @Expect(loginOutcome(auth, "student1", "pass2"), "OK:student")
        // After the lockout passes, the correct password works again.
        tick.time = DateTime.parse("2026-10-24T00:10:01Z")
        @Expect(loginOutcome(auth, "worker1", "pass1"), "OK:staff")
    }

    @TestCase
    func unknownUserFailuresAlsoCountTowardLockout() {
        let tick = TestClock(DateTime.parse("2026-10-24T00:00:00Z"))
        let throttle = LoginGuard(maxFailures: 2, windowSeconds: 300, lockoutSeconds: 600, clock: { => tick.time })
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()), throttle: throttle)
        // Guessing a non-existent name is the same attack as guessing a password.
        @Expect(loginOutcome(auth, "ghost", "whatever"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "ghost", "whatever"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "ghost", "whatever"), "UNAUTHORIZED")
        @Expect(integer(throttle.stats(), "lockEventsTotal"), 1)
        @Expect(integer(throttle.stats(), "lockRejectsTotal"), 1)
    }

    @TestCase
    func failuresOutsideTheWindowDoNotAccumulate() {
        let tick = TestClock(DateTime.parse("2026-10-24T00:00:00Z"))
        let throttle = LoginGuard(maxFailures: 2, windowSeconds: 300, lockoutSeconds: 600, clock: { => tick.time })
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()), throttle: throttle)
        @Expect(loginOutcome(auth, "worker1", "nope"), "UNAUTHORIZED")
        tick.time = DateTime.parse("2026-10-24T00:06:00Z")
        // The first failure left the 300s window, so this starts a fresh one.
        @Expect(loginOutcome(auth, "worker1", "nope"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "worker1", "pass1"), "OK:staff")
        @Expect(integer(throttle.stats(), "lockEventsTotal"), 0)
    }

    @TestCase
    func aSuccessfulLoginResetsTheFailureCounter() {
        let tick = TestClock(DateTime.parse("2026-10-24T00:00:00Z"))
        let throttle = LoginGuard(maxFailures: 2, windowSeconds: 300, lockoutSeconds: 600, clock: { => tick.time })
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()), throttle: throttle)
        @Expect(loginOutcome(auth, "worker1", "nope"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "worker1", "pass1"), "OK:staff")
        @Expect(loginOutcome(auth, "worker1", "nope"), "UNAUTHORIZED")
        @Expect(loginOutcome(auth, "worker1", "pass1"), "OK:staff")
        // Two failures, but never two in a row inside one window: no lock.
        @Expect(integer(throttle.stats(), "lockEventsTotal"), 0)
        @Expect(integer(throttle.stats(), "trackedUsernames"), 0)
    }

    @TestCase
    func guardRejectsAbsurdConfigurationInsteadOfSilentlyDisabling() {
        var code = ""
        try { LoginGuard(maxFailures: 0) } catch (e: BusinessError) { code = e.code }
        @Expect(code, "VALIDATION_ERROR")
        code = ""
        try { LoginGuard(lockoutSeconds: 0) } catch (e: BusinessError) { code = e.code }
        @Expect(code, "VALIDATION_ERROR")
    }

    @TestCase
    func authStatsMergeSessionAndGuardCounters() {
        let auth = Auth("session", SessionStore(600), credentials: Credentials(authSpec()))
        let merged = auth.stats()
        @Expect(merged.containsKey("activeSessions"), true)
        @Expect(merged.containsKey("loginGuard"), true)
        // Guard defaults must be visible in the merged stats, not guessed.
        @Expect(integer(merged["loginGuard"].asObject(), "maxFailures"), 10)
        @Expect(integer(merged["loginGuard"].asObject(), "windowSeconds"), 300)
        @Expect(integer(merged["loginGuard"].asObject(), "lockoutSeconds"), 600)
    }
}

@Test
class StoreCommitTests {
    @TestCase
    func interruptedCommitIsDiscardedCountedAndNotLoaded() {
        let knowledge = Knowledge(getVariable("ICT_DATA") ?? "synthetic.runtime.json")
        let tick = TestClock(DateTime.parse(str(knowledge.dataset, "generatedAt")))
        let store = "unit-pending-${getProcessId()}.json"
        let pending = store + ".pending"
        if (exists(store)) { remove(store) }
        if (exists(pending)) { remove(pending) }
        let first = Business(knowledge, store, clock: { => tick.time })
        @Expect(exists(store), true)
        @Expect(integer(first.state, "counter"), 0)
        // Simulate a process dying between writing .pending and renaming it into place.
        File.writeTo(pending, "{\"schemaVersion\":\"synthetic-store-0.1\",\"counter\":99".toArray())
        @Expect(exists(pending), true)
        let second = Business(knowledge, store, clock: { => tick.time })
        // The partial file is gone, the committed snapshot survived, and the event is counted.
        @Expect(exists(pending), false)
        @Expect(integer(second.state, "interruptedCommits"), 1)
        @Expect(integer(second.state, "counter"), 0)
        @Expect(array(second.state, "tickets").size(), 0)
        // A second restart must not double-count or resurrect the pending file.
        let third = Business(knowledge, store, clock: { => tick.time })
        @Expect(integer(third.state, "interruptedCommits"), 1)
        @Expect(exists(pending), false)
        remove(store)
    }

    @TestCase
    func failedSaveLeavesTheCommittedSnapshotIntact() {
        let knowledge = Knowledge(getVariable("ICT_DATA") ?? "synthetic.runtime.json")
        let tick = TestClock(DateTime.parse(str(knowledge.dataset, "generatedAt")))
        let store = "unit-failsave-${getProcessId()}.json"
        if (exists(store)) { remove(store) }
        let service = Business(knowledge, store, clock: { => tick.time })
        let before = String.fromUtf8(File.readFrom(store))
        let body = JsonValue.fromStr(##"{"requestId":"atomic-1","location":"公共区域","description":"合成报修","contactAlias":"SYN-CONTACT-K"}"##).asObject()
        var code = ""
        try {
            service.execute("POST", "/api/v1/ticket-drafts", obj(), body, "campus-user", "", failSave: true)
        } catch (_: Exception) { code = "THREW" }
        @Expect(code, "THREW")
        // Injected failure must not reach the store file, and the in-memory state rolls back.
        @Expect(String.fromUtf8(File.readFrom(store)), before)
        @Expect(array(service.state, "drafts").size(), 0)
        remove(store)
    }
}
