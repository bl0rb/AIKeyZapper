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
        let body = ok ? #"{"data":[{"id":"eu.anthropic.claude-sonnet-5-iti-cs"},{"id":"eu.anthropic.claude-opus-5-iti-cs"}]}"# : #"{"error":"invalid key"}"#
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
}
