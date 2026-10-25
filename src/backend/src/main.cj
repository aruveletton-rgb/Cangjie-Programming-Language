package ict_backend

import std.env.*
import std.convert.*
import std.fs.*
import std.time.*
import stdx.net.http.*

main() {
    let port = UInt16.parse(getVariable("ICT_PORT") ?? "38082")
    let dataPath = getVariable("ICT_DATA") ?? "synthetic.runtime.json"
    let storePath = getVariable("ICT_STORE") ?? "store.json"
    let now = getVariable("ICT_TEST_NOW") ?? ""
    var clock: () -> DateTime = { => utcNow() }
    if (!now.isEmpty()) { let fixed = DateTime.parse(now); clock = { => fixed } }
    let ttl = Int64.parse(getVariable("ICT_CONFIRM_TTL") ?? "300")
    if (ttl < 1 || ttl > 3600) { fail("VALIDATION_ERROR") }
    let knowledge = Knowledge(dataPath)
    // Public HTTPS origin (cloud demo). Off by default: the demo stays loopback-only
    // unless an operator names exactly one origin. https only, no wildcard, no path.
    // This is the only relaxation of the loopback allowlist; everything else keeps the
    // original guard, so a typo cannot widen the surface silently.
    let publicOrigin = (getVariable("ICT_PUBLIC_ORIGIN") ?? "").trimAscii()
    if (!publicOrigin.isEmpty()) {
        if (!publicOrigin.startsWith("https://")) { fail("VALIDATION_ERROR") }
        let parts = publicOrigin.split("/", removeEmpty: true)
        if (parts.size != 2 || parts[1] == "*") { fail("VALIDATION_ERROR") }
    }
    // Identity mode. "demo" keeps the old static header tokens so local development and
    // the existing regression suite keep working; "session" accepts only server-issued
    // tokens. The default follows the exposure: loopback stays "demo", a configured public
    // origin forces "session". Asking for "demo" *and* a public origin is a startup error
    // rather than a warning, because that combination is exactly the failure the plan
    // tells us to close (a guessable staff token reachable from the internet).
    let requestedMode = (getVariable("ICT_AUTH_MODE") ?? "").trimAscii()
    var authMode = requestedMode
    if (authMode.isEmpty()) { authMode = if (publicOrigin.isEmpty()) { "demo" } else { "session" } }
    if (authMode != "demo" && authMode != "session") { fail("VALIDATION_ERROR") }
    if (!publicOrigin.isEmpty() && authMode == "demo") { fail("VALIDATION_ERROR") }
    let sessionTtl = Int64.parse(getVariable("ICT_SESSION_TTL") ?? "3600")
    if (sessionTtl < 60 || sessionTtl > 86400) { fail("VALIDATION_ERROR") }
    // Login throttle (week-9 ledger R-W9-5). Defaults are loose enough that ordinary use
    // and the regression suites (which fail at most 2 logins per username) never hit
    // them; an operator tightens them for an internet-reachable deployment.
    let loginMaxFailures = Int64.parse(getVariable("ICT_LOGIN_MAX_FAILURES") ?? "10")
    let loginWindowSeconds = Int64.parse(getVariable("ICT_LOGIN_WINDOW_SECONDS") ?? "300")
    let loginLockoutSeconds = Int64.parse(getVariable("ICT_LOGIN_LOCKOUT_SECONDS") ?? "600")
    if (loginMaxFailures < 1 || loginWindowSeconds < 1 || loginLockoutSeconds < 1) { fail("VALIDATION_ERROR") }
    // Credentials: inline JSON or a file with the same content. Session mode without
    // credentials cannot authenticate anyone, so it refuses to start instead of running
    // in a state where every login fails for an unexplained reason.
    let inlineUsers = (getVariable("ICT_AUTH_USERS") ?? "").trimAscii()
    let usersFile = (getVariable("ICT_AUTH_FILE") ?? "").trimAscii()
    var creds = Credentials("")
    if (!inlineUsers.isEmpty()) { creds = Credentials(inlineUsers) }
    else if (!usersFile.isEmpty()) {
        if (!exists(usersFile)) { fail("VALIDATION_ERROR") }
        creds = Credentials(String.fromUtf8(File.readFrom(usersFile)))
    } else if (authMode == "session") { fail("VALIDATION_ERROR") }
    let auth = Auth(authMode, SessionStore(sessionTtl, clock: clock), credentials: creds,
                    throttle: LoginGuard(maxFailures: loginMaxFailures, windowSeconds: loginWindowSeconds,
                                      lockoutSeconds: loginLockoutSeconds, clock: clock))
    let business = Business(knowledge, storePath, clock: clock, ttl: ttl, auth: auth)
    var rawOrigins = getVariable("ICT_CORS") ?? "http://127.0.0.1:5173,http://localhost:5173"
    if (!publicOrigin.isEmpty()) { rawOrigins = rawOrigins + "," + publicOrigin }
    let origins = rawOrigins.split(",", removeEmpty: true)
    for (origin in origins) {
        if (!publicOrigin.isEmpty() && origin == publicOrigin) { continue }
        if (!(origin.startsWith("http://127.0.0.1:") || origin.startsWith("http://localhost:"))) { fail("VALIDATION_ERROR") }
    }
    let handler = ApiHandler(business, auth, origins)
    let server = ServerBuilder().addr("127.0.0.1").port(port).distributor(ApiDistributor(handler))
        .maxRequestBodySize(1048576).readTimeout(Duration.second * 5).writeTimeout(Duration.second * 5).build()
    println("synthetic Cangjie backend 0.1.0 http://127.0.0.1:${port}; auth=${auth.describe()}; realBusinessWrite=false; G1 not run")
    server.serve()
}
