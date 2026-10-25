package ict_backend

import std.collection.*
import std.convert.*
import std.env.*
import std.io.*
import std.sync.*
import std.time.*
import stdx.encoding.json.*
import stdx.net.http.*

// Call metadata for a single gateway attempt. Empty strings and zero counters mean
// "not applicable", which is what every G0 and Mock path reports.
//
// authorised records whether the endpoint was declared an authorised real provider
// (ICT_PROVIDER_REAL=1). It defaults to false so that pointing the adapter at a local
// stub can never be reported as a real G1 run.
struct AnswerMeta {
    AnswerMeta(let provider: String, let modelVersion: String, let latencyMs: Int64,
        let promptTokens: Int64, let completionTokens: Int64, let authorised: Bool) {}
}

let noMeta = AnswerMeta("", "", 0, 0, 0, false)

struct Answer {
    Answer(let text: String, let mode: String, let fallback: String, let attempts: Int64, let meta: AnswerMeta) {}
}

interface AnswerGateway {
    func generate(question: String, evidence: JsonArray, baseline: String): Answer
}

class DeterministicGateway <: AnswerGateway {
    public func generate(_: String, _: JsonArray, baseline: String): Answer { Answer(baseline, "G0", "", 0, noMeta) }
}

class GatewayFailure <: Exception {
    let code: String
    init(code: String) { super(code); this.code = code }
}

let gatewayGate = Mutex()
var activeGateways: Int64 = 0

func acquireGateway(): Bool {
    synchronized(gatewayGate) {
        if (activeGateways >= 4) { return false }
        activeGateways++; return true
    }
}
func releaseGateway(): Unit { synchronized(gatewayGate) { activeGateways-- } }

// Mock has no HTTP client, credentials or business tools. A real provider must implement this boundary later.
class MockGateway <: AnswerGateway {
    let fault: String
    var calls: Int64 = 0
    init(fault: String) { this.fault = fault }
    func attempt(evidence: JsonArray, baseline: String): (String, String) {
        calls++
        if (fault == "auth") { throw GatewayFailure("MOCK_AUTH_FAILED") }
        if (fault == "timeout") {
            sleep(Duration.millisecond * 80)
            throw GatewayFailure("MOCK_TIMEOUT")
        }
        if (fault == "rate-limit" || (fault == "rate-limit-once" && calls == 1)) {
            throw GatewayFailure("MOCK_RATE_LIMIT")
        }
        let citation = if (fault == "invalid-output") { "OUTSIDE_AUTHORIZED_EVIDENCE" } else {
            str(evidence[0].asObject(), "evidenceId")
        }
        return ("[Mock] " + baseline, citation)
    }

    public func generate(_: String, evidence: JsonArray, baseline: String): Answer {
        if (!acquireGateway()) { return Answer(baseline, "MOCK", "MOCK_CONCURRENCY_LIMIT", 0, noMeta) }
        let start = MonoTime.now()
        try {
            while (calls < 2) {
                try {
                    let (text, citation) = attempt(evidence, baseline)
                    var supported = false
                    for (v in evidence.getItems()) { if (str(v.asObject(), "evidenceId") == citation) { supported = true } }
                    if (!supported) { return Answer(baseline, "MOCK", "MOCK_INVALID_CITATION", calls, noMeta) }
                    return Answer(text, "MOCK", "", calls, noMeta)
                } catch (e: GatewayFailure) {
                    if (e.code != "MOCK_RATE_LIMIT" || calls >= 2 || (MonoTime.now() - start).toMilliseconds() >= 80) {
                        return Answer(baseline, "MOCK", e.code, calls, noMeta)
                    }
                    sleep(Duration.millisecond * 20)
                }
            }
            return Answer(baseline, "MOCK", "MOCK_TIMEOUT", calls, noMeta)
        } finally { releaseGateway() }
    }
}

// ---------------------------------------------------------------------------
// Single real-provider adapter.
//
// Exactly one provider can be active at a time: it is configured entirely through
// environment variables, and an incomplete configuration means "not configured",
// which keeps the G0 deterministic path in charge. There is no provider registry
// and no runtime switching, so a deployment cannot silently mix providers.
//
// The gateway only ever returns text. It has no reference to Business, no ticket
// id, and no write method, so "the model organises authorised evidence but never
// writes tickets" is enforced by the type boundary rather than by a prompt.
// ---------------------------------------------------------------------------

struct ProviderConfig {
    ProviderConfig(let name: String, let endpoint: String, let apiKey: String, let model: String,
        let timeoutMs: Int64, let authorised: Bool) {}
}

func providerConfig(): Option<ProviderConfig> {
    let endpoint = (getVariable("ICT_PROVIDER_ENDPOINT") ?? "").trimAscii()
    let apiKey = (getVariable("ICT_PROVIDER_API_KEY") ?? "").trimAscii()
    let model = (getVariable("ICT_PROVIDER_MODEL") ?? "").trimAscii()
    if (endpoint.isEmpty() || apiKey.isEmpty() || model.isEmpty()) { return None }
    var name = (getVariable("ICT_PROVIDER_NAME") ?? "openai-compatible").trimAscii()
    if (name.isEmpty()) { name = "openai-compatible" }
    var timeout = Int64.parse(getVariable("ICT_PROVIDER_TIMEOUT_MS") ?? "15000")
    if (timeout < 1000 || timeout > 120000) { timeout = 15000 }
    // Only an explicit operator declaration marks the endpoint as an authorised real
    // provider. Anything else (including a local stub) stays unauthorised.
    let authorised = (getVariable("ICT_PROVIDER_REAL") ?? "") == "1"
    return Some(ProviderConfig(name, endpoint, apiKey, model, timeout, authorised))
}

let providerSystemPrompt = "你是演示系统的回答整理器。只能使用用户消息中列出的证据条目，不得引入证据之外的知识。" +
    "每一条结论后面必须用方括号标注所依据的证据编号，例如 [K_REPAIR]；证据不足时直接说明证据不足，不要推测。" +
    "你没有创建工单、提交、修改数据的权限，也不要声称已经提交或已被受理。"

func evidenceBlock(evidence: JsonArray): String {
    var block = ""
    for (v in evidence.getItems()) {
        let ref = v.asObject()
        block += "[" + str(ref, "evidenceId") + "] " + str(ref, "content") + "\n"
    }
    return block
}

func providerRequestBody(config: ProviderConfig, question: String, evidence: JsonArray): String {
    let messages = JsonArray()
    let system = obj()
    system.put("role", s("system")); system.put("content", s(providerSystemPrompt))
    messages.add(system)
    let user = obj()
    user.put("role", s("user"))
    user.put("content", s("问题：" + question + "\n授权证据：\n" + evidenceBlock(evidence)))
    messages.add(user)
    let body = obj()
    body.put("model", s(config.model))
    body.put("messages", messages)
    body.put("temperature", n(0))
    body.put("stream", flag(false))
    return body.toString()
}

func citationsOf(text: String): Array<String> {
    let out = ArrayList<String>()
    for (part in text.split("[")) {
        if (let Some(end) <- part.indexOf("]")) {
            let id = part[0..end].trimAscii()
            if (!id.isEmpty() && id.size <= 64 && !hasString(out, id)) { out.add(id) }
        }
    }
    return out.toArray()
}

func hasString(values: ArrayList<String>, value: String): Bool {
    for (item in values) { if (item == value) { return true } }
    return false
}

func unsupportedCitation(citations: Array<String>, evidence: JsonArray): String {
    for (id in citations) {
        var supported = false
        for (v in evidence.getItems()) { if (str(v.asObject(), "evidenceId") == id) { supported = true } }
        if (!supported) { return id }
    }
    return ""
}

func containsAny(text: String, needles: Array<String>): Bool {
    for (needle in needles) { if (text.contains(needle)) { return true } }
    return false
}

func statusFallback(status: Int64): String {    if (status == 401 || status == 403) { return "G1_AUTH_FAILED" }
    if (status == 429) { return "G1_RATE_LIMIT" }
    if (status >= 500) { return "G1_PROVIDER_ERROR" }
    if (status != 200) { return "G1_HTTP_" + status.toString() }
    return ""
}

func readAll(stream: InputStream): String {
    let collected = ArrayList<UInt8>()
    let buffer = Array<UInt8>(4096, repeat: 0)
    while (true) {
        let read = stream.read(buffer)
        if (read <= 0) { break }
        for (i in 0..read) { collected.add(buffer[i]) }
    }
    return String.fromUtf8(collected.toArray())
}

// Parses an OpenAI-compatible chat completion. Returns (text, promptTokens, completionTokens).
func providerText(body: String): (String, Int64, Int64) {
    let root = JsonValue.fromStr(body).asObject()
    let choices = root["choices"].asArray()
    if (choices.size() == 0) { throw GatewayFailure("G1_EMPTY_CHOICES") }
    let message = choices[0].asObject()["message"].asObject()
    let text = str(message, "content").trimAscii()
    var prompt: Int64 = 0
    var completion: Int64 = 0
    if (let Some(raw) <- root.get("usage")) {
        if (raw is JsonObject) {
            let usage = raw.asObject()
            if (let Some(v) <- usage.get("prompt_tokens")) { if (v is JsonInt) { prompt = v.asInt().getValue() } }
            if (let Some(v) <- usage.get("completion_tokens")) { if (v is JsonInt) { completion = v.asInt().getValue() } }
        }
    }
    return (text, prompt, completion)
}

class ProviderGateway <: AnswerGateway {
    let config: ProviderConfig
    init(config: ProviderConfig) { this.config = config }

    public func generate(question: String, evidence: JsonArray, baseline: String): Answer {
        if (!acquireGateway()) { return Answer(baseline, "G0", "G1_CONCURRENCY_LIMIT", 0, noMeta) }
        let start = MonoTime.now()
        try {
            let client = ClientBuilder().readTimeout(Duration.millisecond * config.timeoutMs).build()
            let request = HttpRequestBuilder()
                .method("POST")
                .url(config.endpoint)
                .header("Content-Type", "application/json")
                .header("Authorization", "Bearer " + config.apiKey)
                .body(providerRequestBody(config, question, evidence))
                .build()
            let response = client.send(request)
            let status = Int64(response.status)
            let latency = (MonoTime.now() - start).toMilliseconds()
            let failure = statusFallback(status)
            if (!failure.isEmpty()) {
                return Answer(baseline, "G0", failure, 1, AnswerMeta(config.name, config.model, latency, 0, 0, config.authorised))
            }
            let body = readAll(response.body)
            let (text, prompt, completion) = providerText(body)
            let meta = AnswerMeta(config.name, config.model, latency, prompt, completion, config.authorised)
            if (text.isEmpty()) { return Answer(baseline, "G0", "G1_EMPTY_OUTPUT", 1, meta) }
            let citations = citationsOf(text)
            if (citations.isEmpty()) { return Answer(baseline, "G0", "G1_MISSING_CITATION", 1, meta) }
            let unsupported = unsupportedCitation(citations, evidence)
            if (!unsupported.isEmpty()) { return Answer(baseline, "G0", "G1_INVALID_CITATION", 1, meta) }
            return Answer(text, "G1", "", 1, meta)
        } catch (e: Exception) {
            let latency = (MonoTime.now() - start).toMilliseconds()
            let reason = if (containsAny(e.message, ["timeout", "Timeout", "TIMEOUT", "超时"])) {
                "G1_TIMEOUT"
            } else if (containsAny(e.message, ["10061", "refused", "Refused"])) {
                "G1_CONNECT_FAILED"
            } else {
                "G1_UNAVAILABLE"
            }
            return Answer(baseline, "G0", reason, 1, AnswerMeta(config.name, config.model, latency, 0, 0, config.authorised))
        } finally { releaseGateway() }
    }
}

func intentOf(text: String, domain: String): String {
    for (term in ["报修", "维修", "坏了", "漏水"]) { if (text.contains(term)) { return "repair" } }
    for (term in ["失物", "拾物", "丢了", "捡到"]) { if (text.contains(term)) { return "lost" } }
    for (term in ["活动", "报名"]) { if (text.contains(term)) { return "activity" } }
    for (term in ["通知", "停水", "供水"]) { if (text.contains(term)) { return "notice" } }
    if (domain == "campus-demo") {
        for (term in ["课程", "考试", "课表"]) { if (text.contains(term)) { return "schedule" } }
    } else {
        for (term in ["养老", "医疗", "老人"]) { if (text.contains(term)) { return "eldercare" } }
        for (term in ["办事", "材料", "证明"]) { if (text.contains(term)) { return "service" } }
    }
    return "general"
}

func chat(body: JsonObject, who: Identity, knowledge: Knowledge, now: DateTime): JsonObject {
    allowedFields(body, ["requestId", "text", "conversationId", "mockFault"])
    let rid = requestId(body)
    let text = required(body, "text", limit: 8000)
    let conversation = if (str(body, "conversationId").isEmpty()) { "conv-" + rid } else { identifier(str(body, "conversationId")) }
    let intent = intentOf(text, who.domain)
    let refs = knowledge.refs(who, now, text)
    var baseline = "演示资料中没有适用依据，请补充具体事项或向实际服务方核实。"
    if (refs.size() > 0) {
        baseline = "以下来自本地合成资料，仅用于开发演示："
        for (v in refs.getItems()) {
            let ref = v.asObject()
            baseline += "\n[" + str(ref, "evidenceId") + "@" + str(ref, "version") + "] " + str(ref, "content")
        }
    }
    var gateway: AnswerGateway = DeterministicGateway()
    let mock = str(body, "mockFault")
    if (!mock.isEmpty()) {
        if ((getVariable("ICT_ENABLE_TEST_FAULTS") ?? "") != "1") { fail("VALIDATION_ERROR") }
        if (!has(JsonArray([s("none"), s("auth"), s("timeout"), s("rate-limit"), s("rate-limit-once"), s("invalid-output"), s("disconnect"), s("slow")]), mock)) { fail("VALIDATION_ERROR") }
        gateway = MockGateway(mock)
    } else if (let Some(config) <- providerConfig()) {
        // A real provider only runs when evidence exists; with no applicable evidence the
        // deterministic clarification path stays in charge and no model call is made.
        gateway = ProviderGateway(config)
    }
    let answer = if (refs.size() == 0) { Answer(baseline, "G0", "NO_APPLICABLE_EVIDENCE", 0, noMeta) } else { gateway.generate(text, refs, baseline) }
    let result = obj()
    result.put("requestId", s(rid)); result.put("conversationId", s(conversation))
    result.put("answer", s(answer.text)); result.put("evidenceRefs", refs); result.put("intent", s(intent))
    result.put("gatewayMode", s(answer.mode)); result.put("attempts", n(answer.attempts))
    // realG1Ran requires three things: a G1 answer, no fallback, and an endpoint the
    // operator declared as an authorised real provider. A local stub therefore reports
    // G1 with realG1Ran=false, which is the honest reading.
    result.put("realG1Ran", flag(answer.mode == "G1" && answer.fallback.isEmpty() && answer.meta.authorised))
    result.put("providerAuthorised", flag(answer.meta.authorised))
    result.put("provider", s(answer.meta.provider)); result.put("modelVersion", s(answer.meta.modelVersion))
    result.put("latencyMs", n(answer.meta.latencyMs))
    let usage = obj()
    usage.put("promptTokens", n(answer.meta.promptTokens))
    usage.put("completionTokens", n(answer.meta.completionTokens))
    usage.put("totalTokens", n(answer.meta.promptTokens + answer.meta.completionTokens))
    result.put("usage", usage)
    result.put("answerStatus", s(if (refs.size() == 0) { "CLARIFICATION_REQUIRED" } else { "ANSWERED" }))
    if (!answer.fallback.isEmpty()) { result.put("fallbackReason", s(answer.fallback)) }
    result.put("datasetVersion", s(str(knowledge.dataset, "version")))
    return marked(result)
}
