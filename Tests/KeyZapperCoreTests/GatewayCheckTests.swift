@testable import KeyZapperCore
import Foundation
import Testing

/// Answers like LiteLLM: /v1/models lists the models of key "sk-good", rejects other keys.
final class StubGateway: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let key = request.value(forHTTPHeaderField: "x-api-key")
        let ok = key == "sk-good" && request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-good"
        let info = #"{"key":"sk-good","info":{"spend":2.5,"max_budget":10.0,"budget_reset_at":"2026-11-01T00:00:00.123456+00:00"}}"#
        let body = ok && request.url!.path.hasSuffix("/key/info") ? info : ok ? #"{"data":[{"id":"eu.anthropic.claude-sonnet-5-iti-cs"},{"id":"eu.anthropic.claude-opus-5-iti-cs"}]}"# : #"{"error":"invalid key"}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: ok ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct GatewayCheckTests {
    let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubGateway.self]
        return URLSession(configuration: config)
    }()
    let endpoint = URL(string: "https://gateway.example.test")!

    @Test func listsModelsOfTheKey() async {
        let result = await GatewayCheck.models(endpoint: endpoint, key: "sk-good", session: session)
        let models = try? result.get()
        #expect(models == ["eu.anthropic.claude-opus-5-iti-cs", "eu.anthropic.claude-sonnet-5-iti-cs"])
    }

    @Test func reportsMissingModelsAndRejectedKeys() async {
        let partial = await GatewayCheck.run(endpoint: endpoint, key: "sk-good",
                                             models: ["eu.anthropic.claude-sonnet-5-iti-cs", "eu.anthropic.claude-haiku-x"], session: session)
        #expect(partial == .ok(missingModels: ["eu.anthropic.claude-haiku-x"]))
        #expect(partial.isSuccess == false)
        let complete = await GatewayCheck.run(endpoint: endpoint, key: "sk-good", models: ["eu.anthropic.claude-opus-5-iti-cs"], session: session)
        #expect(complete.isSuccess)
        let rejected = await GatewayCheck.run(endpoint: endpoint, key: "sk-bad", models: [], session: session)
        #expect(rejected == .unauthorized)
    }

    @Test func readsKeyBudget() async throws {
        let budget = try await GatewayCheck.budget(endpoint: endpoint, key: "sk-good", session: session).get()
        #expect(budget == KeyBudget(spend: 2.5, maxBudget: 10, resetAt: Date(timeIntervalSince1970: 1_793_491_200)))
        #expect(budget.remaining == 7.5)
        #expect(KeyBudget(spend: 3, maxBudget: nil).remaining == .infinity)
        #expect(KeyBudget(spend: 12, maxBudget: 10).remaining == 0)
        let rejected = await GatewayCheck.budget(endpoint: endpoint, key: "sk-bad", session: session)
        #expect(rejected == .failure(GatewayFailure(result: .unauthorized)))
        #expect(GatewayCheck.parseDate("2026-11-01T00:00:00") == Date(timeIntervalSince1970: 1_793_491_200))
    }
}
