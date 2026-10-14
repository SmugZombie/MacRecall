import Foundation
import Testing
@testable import RecallCore

/// Intercepts provider HTTP traffic so request shapes and response handling can be tested offline.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Captured { var request: URLRequest; var body: Data }
    nonisolated(unsafe) static var responses: [(status: Int, headers: [String: String], body: Data)] = []
    nonisolated(unsafe) static var captured: [Captured] = []

    static func reset(_ responses: [(Int, [String: String], Any)]) {
        self.responses = responses.map { ($0.0, $0.1, (try? JSONSerialization.data(withJSONObject: $0.2)) ?? Data()) }
        captured = []
    }

    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockURLProtocol.self]
        return c
    }

    static func json(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: captured[index].body)) as? [String: Any] ?? [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        Self.captured.append(Captured(request: request, body: body))
        let next: (status: Int, headers: [String: String], body: Data) =
            Self.responses.isEmpty ? (200, [:], Data("{}".utf8)) : Self.responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1", headerFields: next.headers)!
        if (300..<400).contains(next.status), let location = next.headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct ProviderTests {
    let schema = ActivityAnalysis.schema
    let analysis: [String: Any] = ["activity": "Coding", "description": "Editing Swift", "applications": ["Xcode"], "topics": [], "confidence": 0.8]

    // MARK: SigV4

    @Test func sigV4MatchesAWSTestSuiteVector() {
        // "get-vanilla" from the AWS Signature Version 4 test suite.
        var request = URLRequest(url: URL(string: "https://example.amazonaws.com/")!)
        request.httpMethod = "GET"
        let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
        SigV4.sign(&request, body: Data(), credentials: AWSCredentials(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                   region: "us-east-1", service: "service", date: date)
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test func sigV4DoubleEncodesPathAndSortsQuery() {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "bedrock-runtime.us-east-1.amazonaws.com"
        components.percentEncodedPath = "/model/\(BedrockProvider.pathSegment("anthropic.claude-3-haiku-20240307-v1:0"))/converse"
        components.queryItems = [URLQueryItem(name: "b", value: "2"), URLQueryItem(name: "a-b", value: "x y"), URLQueryItem(name: "a", value: "1")]
        let url = components.url!
        #expect(SigV4.canonicalURI(url) == "/model/anthropic.claude-3-haiku-20240307-v1%253A0/converse")
        #expect(SigV4.canonicalQuery(url) == "a=1&a-b=x%20y&b=2")
    }

    @Test func sessionTokenIsSigned() {
        var request = URLRequest(url: URL(string: "https://bedrock.us-west-2.amazonaws.com/foundation-models")!)
        SigV4.sign(&request, body: Data(), credentials: AWSCredentials(accessKeyID: "A", secretAccessKey: "S", sessionToken: "T"),
                   region: "us-west-2", service: "bedrock")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == "T")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains("SignedHeaders=host;x-amz-date;x-amz-security-token") == true)
    }

    @Test func parsesAWSCredentialsFile() {
        let ini = """
        [default]
        aws_access_key_id = AKIA1
        aws_secret_access_key = secret1
        # comment
        [work]
        aws_access_key_id=AKIA2
        aws_secret_access_key=secret2
        aws_session_token=tok
        """
        let parsed = AWSProfileCredentials.parseINI(ini)
        #expect(parsed["default"]?["aws_access_key_id"] == "AKIA1")
        #expect(parsed["work"]?["aws_session_token"] == "tok")
    }

    // MARK: Bedrock

    func bedrock(_ auth: BedrockAuth = .apiKey("br-key")) -> BedrockProvider {
        BedrockProvider(region: "us-west-2", auth: auth, configuration: MockURLProtocol.configuration)
    }

    @Test func bedrockConverseForcesToolAndParsesToolUse() async throws {
        MockURLProtocol.reset([(200, [:], ["output": ["message": ["role": "assistant", "content": [["toolUse": ["toolUseId": "1", "name": "record_result", "input": analysis]]]]],
                                         "stopReason": "tool_use"])])
        let image = Data([0xFF, 0xD8, 0xFF])
        let raw = try await bedrock().chat(model: "us.anthropic.claude-sonnet-4-6", messages: [
            ChatMessage(role: "system", content: "sys"), ChatMessage(role: "user", content: "describe", images: [image]),
        ], schema: schema, temperature: 0.1)
        #expect(try ActivityAnalysis.parse(raw).activity == "Coding")

        let req = MockURLProtocol.captured[0].request
        #expect(req.url?.host == "bedrock-runtime.us-west-2.amazonaws.com")
        #expect(req.url?.absoluteString.hasSuffix("/model/us.anthropic.claude-sonnet-4-6/converse") == true)
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer br-key")
        let body = MockURLProtocol.json(0)
        #expect((body["inferenceConfig"] as? [String: Any])?["maxTokens"] as? Int == BedrockProvider.maxTokens)
        #expect((body["system"] as? [[String: Any]])?.first?["text"] as? String == "sys")
        let tool = (body["toolConfig"] as? [String: Any])?["toolChoice"] as? [String: Any]
        #expect((tool?["tool"] as? [String: Any])?["name"] as? String == "record_result")
        let content = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        let img = content.first?["image"] as? [String: Any]
        #expect(img?["format"] as? String == "jpeg")
        #expect((img?["source"] as? [String: Any])?["bytes"] as? String == image.base64EncodedString())
    }

    @Test func bedrockFallsBackWhenToolChoiceUnsupported() async throws {
        MockURLProtocol.reset([
            (400, ["x-amzn-ErrorType": "ValidationException:http://internal"], ["message": "This model doesn't support the toolConfig.toolChoice.tool field."]),
            (200, [:], ["output": ["message": ["role": "assistant", "content": [["text": "```json\n{\"activity\":\"Coding\",\"description\":\"x\",\"applications\":[],\"topics\":[],\"confidence\":0.5}\n```"]]]]]),
        ])
        let provider = bedrock()
        let raw = try await provider.chat(model: "meta.llama3-1-8b-instruct-v1:0", messages: [ChatMessage(role: "user", content: "hi")], schema: schema, temperature: 0)
        #expect(try ActivityAnalysis.parse(raw).activity == "Coding")
        let retry = MockURLProtocol.json(1)
        #expect(retry["toolConfig"] == nil)
        #expect(((retry["system"] as? [[String: Any]])?.last?["text"] as? String)?.contains("JSON schema") == true)
        // The model ID's colon is percent-encoded in the path.
        #expect(MockURLProtocol.captured[0].request.url?.absoluteString.contains("v1%3A0/converse") == true)
    }

    @Test func bedrockAuthErrorsAreOutages() async {
        MockURLProtocol.reset([(403, ["x-amzn-ErrorType": "UnrecognizedClientException:http://internal"], ["message": "The security token included in the request is invalid."])])
        do {
            _ = try await bedrock(.accessKeys(AWSCredentials(accessKeyID: "A", secretAccessKey: "S"))).chat(model: "m", messages: [ChatMessage(role: "user", content: "x")])
            Issue.record("expected failure")
        } catch let error as AIProviderError {
            #expect(error.isOutage)
            #expect(MockURLProtocol.captured[0].request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256") == true)
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func bedrockThrottlingIsTransientNotOutage() {
        let e = BedrockProvider.error(status: 429, data: Data(), errorType: "ThrottlingException")
        #expect(e.isTransient && !e.isOutage)
        let denied = BedrockProvider.error(status: 403, data: Data(#"{"message":"no access"}"#.utf8), errorType: "AccessDeniedException")
        #expect(!denied.isTransient && !denied.isOutage)
    }

    @Test func bedrockListsModelsAndInferenceProfiles() async throws {
        MockURLProtocol.reset([
            (200, [:], ["modelSummaries": [
                ["modelId": "anthropic.claude-sonnet-4-6", "providerName": "Anthropic", "modelName": "Claude Sonnet 4.6",
                 "inputModalities": ["TEXT", "IMAGE"], "outputModalities": ["TEXT"], "inferenceTypesSupported": ["INFERENCE_PROFILE"]],
                ["modelId": "amazon.titan-embed-text-v2:0", "inputModalities": ["TEXT"], "outputModalities": ["EMBEDDING"], "inferenceTypesSupported": ["ON_DEMAND"]],
                ["modelId": "amazon.nova-canvas-v1:0", "inputModalities": ["TEXT"], "outputModalities": ["IMAGE"], "inferenceTypesSupported": ["ON_DEMAND"]],
            ]]),
            (200, [:], ["inferenceProfileSummaries": [
                ["inferenceProfileId": "us.anthropic.claude-sonnet-4-6", "inferenceProfileName": "US Claude Sonnet 4.6", "status": "ACTIVE",
                 "models": [["modelArn": "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-6"]]],
            ]]),
        ])
        let models = try await bedrock().listModels()
        #expect(models.map(\.name) == ["amazon.titan-embed-text-v2:0", "us.anthropic.claude-sonnet-4-6"])
        #expect(models.first { $0.name.hasPrefix("us.") }?.capabilities == [.completion, .vision])
        #expect(models.first?.capabilities == [.embedding])
    }

    @Test func bedrockTitanAndCohereEmbeddings() async throws {
        MockURLProtocol.reset([(200, [:], ["embedding": [0.1, 0.2]]), (200, [:], ["embedding": [0.3, 0.4]])])
        let titan = try await bedrock().embed(model: "amazon.titan-embed-text-v2:0", inputs: ["a", "b"])
        #expect(titan.count == 2 && titan[1] == [0.3, 0.4])
        #expect(MockURLProtocol.json(0)["dimensions"] as? Int == 1024)
        #expect(MockURLProtocol.captured[0].request.url?.path.hasSuffix("/invoke") == true)

        MockURLProtocol.reset([(200, [:], ["embeddings": ["float": [[1, 2], [3, 4]]]])])
        let cohere = try await bedrock().embed(model: "cohere.embed-v4:0", inputs: ["a", "b"], purpose: .query)
        #expect(cohere == [[1, 2], [3, 4]])
        #expect(MockURLProtocol.json(0)["input_type"] as? String == "search_query")
        #expect(try BedrockProvider.parseCohere(Data(#"{"embeddings":[[5,6]]}"#.utf8), expected: 1) == [[5, 6]])
    }

    // MARK: OpenAI-compatible

    func openAI(_ kind: AIProviderKind = .openAI) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(kind: kind, endpoint: "https://api.example.com/v1", apiKey: "sk-test", configuration: MockURLProtocol.configuration)
    }

    @Test func openAIChatRequestShape() async throws {
        let json = String(data: try JSONSerialization.data(withJSONObject: analysis), encoding: .utf8)!
        MockURLProtocol.reset([(200, [:], ["choices": [["message": ["role": "assistant", "content": json]]]])])
        let raw = try await openAI().chat(model: "gpt-4.1-mini", messages: [ChatMessage(role: "user", content: "look", images: [Data([1, 2])])],
                                          schema: schema, temperature: 0.2)
        #expect(try ActivityAnalysis.parse(raw).description == "Editing Swift")
        let req = MockURLProtocol.captured[0].request
        #expect(req.url?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = MockURLProtocol.json(0)
        #expect(body["max_completion_tokens"] as? Int == 1500)
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        let parts = ((body["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
        #expect(((parts.last?["image_url"] as? [String: Any])?["url"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
    }

    @Test func openAIDropsRejectedParameters() async throws {
        MockURLProtocol.reset([
            (400, [:], ["error": ["message": "Unsupported value: 'temperature' does not support 0.1 with this model."]]),
            (400, [:], ["error": ["message": "Invalid parameter: 'response_format' of type 'json_schema' is not supported with this model."]]),
            (200, [:], ["choices": [["message": ["content": "{}"]]]]),
        ])
        _ = try await openAI(.lmStudio).chat(model: "local-model", messages: [ChatMessage(role: "user", content: "x")], schema: schema, temperature: 0.1)
        let last = MockURLProtocol.json(2)
        #expect(last["temperature"] == nil)
        #expect(last["response_format"] == nil)
        #expect(last["max_tokens"] as? Int == 1500)  // LM Studio uses max_tokens
        #expect(((last["messages"] as? [[String: Any]])?.first?["content"] as? String)?.contains("JSON schema") == true)
    }

    @Test func openAIEmbeddingsOrderedByIndex() async throws {
        MockURLProtocol.reset([(200, [:], ["data": [["index": 1, "embedding": [3, 4]], ["index": 0, "embedding": [1, 2]]]])])
        let v = try await openAI().embed(model: "text-embedding-3-small", inputs: ["a", "b"])
        #expect(v == [[1, 2], [3, 4]])
    }

    @Test func openAIUnauthorizedIsOutage() async {
        MockURLProtocol.reset([(401, [:], ["error": ["message": "Incorrect API key provided"]])])
        do {
            _ = try await openAI().chat(model: "gpt-4.1", messages: [ChatMessage(role: "user", content: "x")])
            Issue.record("expected failure")
        } catch let error as AIProviderError {
            #expect(error.isOutage)
        } catch { Issue.record("unexpected \(error)") }
    }

    @Test func openAIModelClassification() {
        #expect(OpenAICompatibleProvider.classify("whisper-1") == nil)
        #expect(OpenAICompatibleProvider.classify("tts-1-hd") == nil)
        #expect(OpenAICompatibleProvider.classify("text-embedding-3-large")?.capabilities == [.embedding])
        #expect(OpenAICompatibleProvider.classify("gpt-4o-mini")?.capabilities.contains(.vision) == true)
    }

    @Test func crossHostRedirectIsNotFollowed() async {
        MockURLProtocol.reset([(307, ["Location": "https://evil.example.net/v1/chat/completions"], [:])])
        let provider = OpenAICompatibleProvider(kind: .openAI, endpoint: "https://api.example.com/v1", apiKey: "k",
                                                configuration: MockURLProtocol.configuration)
        do {
            _ = try await provider.chat(model: "m", messages: [ChatMessage(role: "user", content: "screenshot text")])
            Issue.record("expected the redirect to be refused")
        } catch let error as AIProviderError {
            #expect(error.isOutage)
            if case .redirectRefused = error {} else { Issue.record("unexpected \(error)") }
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(MockURLProtocol.captured.allSatisfy { $0.request.url?.host == "api.example.com" })
    }

    @Test func missingOpenAIKeyFailsFast() async {
        let p = OpenAICompatibleProvider(kind: .openAI, endpoint: OpenAICompatibleProvider.defaultOpenAIEndpoint, apiKey: nil,
                                         configuration: MockURLProtocol.configuration)
        #expect(await p.ping() == false)
    }
}

@Suite struct ProviderSettingsTests {
    @Test func legacyOllamaSettingsMigrate() throws {
        let legacy = #"{"visionModel":"qwen2.5vl","summaryModel":"llama3.2","embeddingModel":"nomic-embed-text","ollamaEndpoint":"http://10.0.0.5:11434","remoteEndpointAcknowledged":true}"#
        let s = try JSONDecoder().decode(RecallSettings.self, from: Data(legacy.utf8))
        #expect(s.aiProvider == .ollama)
        #expect(s.visionModel == "qwen2.5vl")
        #expect(s.embeddingIndexKey == "nomic-embed-text")  // unchanged key keeps existing vectors usable
        #expect(s.providerIsRemote)
        #expect(s.aiTransmissionAllowed)  // earlier approval carried over
        // Round trip doesn't lose the migrated selection.
        let again = try JSONDecoder().decode(RecallSettings.self, from: JSONEncoder().encode(s))
        #expect(again.summaryModel == "llama3.2")
    }

    @Test func modelSelectionsArePerProvider() {
        var s = RecallSettings()
        s.summaryModel = "llama3.2"
        s.aiProvider = .openAI
        #expect(s.summaryModel == "")
        s.summaryModel = "gpt-4.1-mini"
        s.embeddingModel = "text-embedding-3-small"
        #expect(s.embeddingIndexKey == "openAI/text-embedding-3-small")
        s.aiProvider = .ollama
        #expect(s.summaryModel == "llama3.2")
    }

    @Test func cloudProvidersRequireApproval() {
        var s = RecallSettings()
        #expect(s.aiTransmissionAllowed)  // local Ollama
        s.aiProvider = .lmStudio
        #expect(!s.providerIsRemote && s.aiTransmissionAllowed)
        s.aiProvider = .bedrock
        #expect(s.providerIsRemote && !s.aiTransmissionAllowed)
        s.acknowledgeRemoteTarget()
        #expect(s.aiTransmissionAllowed)
        // Approval is per destination: another region needs its own.
        s.bedrockRegion = "eu-central-1"
        #expect(!s.aiTransmissionAllowed)
        s.aiProvider = .openAI
        #expect(!s.aiTransmissionAllowed)
    }

    @Test func factoryBuildsMatchingProvider() {
        var s = RecallSettings()
        for kind in AIProviderKind.allCases {
            s.aiProvider = kind
            #expect(s.makeProvider(secrets: { _ in "x" }).kind == kind)
        }
    }
}
