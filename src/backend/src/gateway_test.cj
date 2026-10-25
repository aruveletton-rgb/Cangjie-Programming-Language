package ict_backend

import std.env.*
import std.unittest.*
import std.unittest.testmacro.*
import stdx.encoding.json.*

@Test
class GatewayTests {
    @TestCase
    func attemptsAndCitationValidation() {
        let ref = obj(); ref.put("evidenceId", s("authorized")); let evidence = JsonArray([ref])
        let limited = MockGateway("rate-limit"); let a = limited.generate("q", evidence, "baseline")
        @Expect(limited.calls, 2); @Expect(a.attempts, limited.calls); @Expect(a.fallback,"MOCK_RATE_LIMIT")
        let once = MockGateway("rate-limit-once"); let b = once.generate("q", evidence, "baseline")
        @Expect(once.calls, 2); @Expect(b.fallback, "")
        let auth = MockGateway("auth"); auth.generate("q",evidence,"baseline"); @Expect(auth.calls,1)
        let invalid = MockGateway("invalid-output"); let c = invalid.generate("q",evidence,"baseline")
        @Expect(c.fallback,"MOCK_INVALID_CITATION"); @Expect(c.text,"baseline")
    }

    @TestCase
    func citationExtractionKeepsOrderAndDeduplicates() {
        let ids = citationsOf("结论一[K_REPAIR]，结论二[K_NOTICE]，重复[K_REPAIR]。")
        @Expect(ids.size, 2)
        @Expect(ids[0], "K_REPAIR")
        @Expect(ids[1], "K_NOTICE")
        @Expect(citationsOf("没有任何引用").size, 0)
    }

    @TestCase
    func unsupportedCitationRejectsAnythingOutsideEvidence() {
        let first = obj(); first.put("evidenceId", s("K_REPAIR"))
        let second = obj(); second.put("evidenceId", s("K_NOTICE"))
        let evidence = JsonArray([first, second])
        @Expect(unsupportedCitation(["K_REPAIR"], evidence), "")
        @Expect(unsupportedCitation(["K_REPAIR", "K_NOTICE"], evidence), "")
        @Expect(unsupportedCitation(["K_REPAIR", "K_SECRET"], evidence), "K_SECRET")
    }

    @TestCase
    func statusMappingIsExplicitForEveryFailureClass() {
        @Expect(statusFallback(200), "")
        @Expect(statusFallback(401), "G1_AUTH_FAILED")
        @Expect(statusFallback(403), "G1_AUTH_FAILED")
        @Expect(statusFallback(429), "G1_RATE_LIMIT")
        @Expect(statusFallback(500), "G1_PROVIDER_ERROR")
        @Expect(statusFallback(503), "G1_PROVIDER_ERROR")
        @Expect(statusFallback(404), "G1_HTTP_404")
    }

    @TestCase
    func providerResponseCarriesTextAndUsage() {
        let body = ##"{"choices":[{"message":{"role":"assistant","content":"供水维护在九点开始[K_NOTICE]"}}],"usage":{"prompt_tokens":41,"completion_tokens":17}}"##
        let (text, prompt, completion) = providerText(body)
        @Expect(text, "供水维护在九点开始[K_NOTICE]")
        @Expect(prompt, 41)
        @Expect(completion, 17)
        @Expect(citationsOf(text)[0], "K_NOTICE")
    }

    @TestCase
    func providerResponseWithoutUsageStillParses() {
        let body = ##"{"choices":[{"message":{"content":"没有可用依据[K_NOTICE]"}}]}"##
        let (text, prompt, completion) = providerText(body)
        @Expect(text, "没有可用依据[K_NOTICE]")
        @Expect(prompt, 0)
        @Expect(completion, 0)
    }

    @TestCase
    func unconfiguredProviderKeepsG0() {
        match (providerConfig()) {
            case None => @Expect(true, true)
            case Some(_) => @Expect(false, true)
        }
    }

    @TestCase
    func unreachableProviderFallsBackToG0WithoutClaimingG1() {
        let config = ProviderConfig("stub", "http://127.0.0.1:1/v1/chat/completions", "test-key", "stub-model", 2000, false)
        let gateway = ProviderGateway(config)
        let ref = obj(); ref.put("evidenceId", s("K_REPAIR")); ref.put("content", s("合成报修说明"))
        let answer = gateway.generate("公共区域漏水", JsonArray([ref]), "baseline")
        @Expect(answer.mode, "G0")
        @Expect(answer.text, "baseline")
        @Expect(answer.fallback.startsWith("G1_"), true)
        @Expect(answer.meta.provider, "stub")
        @Expect(answer.meta.modelVersion, "stub-model")
        @Expect(answer.meta.latencyMs >= 0, true)
        @Expect(answer.meta.promptTokens, 0)
    }

    @TestCase
    func requestBodyOnlyCarriesAuthorisedEvidence() {
        let config = ProviderConfig("stub", "http://127.0.0.1:1/x", "k", "m", 1000, false)
        let ref = obj(); ref.put("evidenceId", s("K_REPAIR")); ref.put("content", s("公共区域报修需填写地点"))
        let body = JsonValue.fromStr(providerRequestBody(config, "漏水怎么办", JsonArray([ref]))).asObject()
        @Expect(str(body, "model"), "m")
        let messages = body["messages"].asArray()
        @Expect(messages.size(), 2)
        let system = messages[0].asObject()
        @Expect(str(system, "role"), "system")
        @Expect(str(system, "content").contains("没有创建工单"), true)
        let user = messages[1].asObject()
        @Expect(str(user, "content").contains("[K_REPAIR]"), true)
        @Expect(str(user, "content").contains("公共区域报修需填写地点"), true)
    }
}
