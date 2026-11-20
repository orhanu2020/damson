import XCTest
import DamsonSupport
@testable import DamsonProviders
@testable import DamsonStore

final class JSONValueTests: XCTestCase {
    func testParseAndRoundTrip() {
        let value = JSONValue.parse("{\"a\": 1, \"b\": [true, null, \"x\"], \"c\": {\"d\": 2.5}}")
        XCTAssertEqual(value?["a"]?.intValue, 1)
        XCTAssertEqual(value?["b"]?.arrayValue?.count, 3)
        XCTAssertEqual(value?["b"]?.arrayValue?[0].boolValue, true)
        XCTAssertEqual(value?["c"]?["d"]?.doubleValue, 2.5)
        let text = value!.jsonString()
        XCTAssertEqual(JSONValue.parse(text), value)
    }

    func testCodable() throws {
        let value = JSONValue.object(["k": .array([.string("v"), .number(3), .bool(false), .null])])
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, value)
    }

    func testSchemaHelper() {
        let schema = JSONValue.schema([("path", "string", "A path")], required: ["path"])
        XCTAssertEqual(schema["type"]?.stringValue, "object")
        XCTAssertEqual(schema["properties"]?["path"]?["type"]?.stringValue, "string")
        XCTAssertEqual(schema["required"]?.arrayValue?.first?.stringValue, "path")
    }
}

final class OllamaProviderTests: XCTestCase {
    func testBodyMapsToolsAndResults() {
        let request = LLMRequest(
            model: "llama3", system: "sys",
            messages: [
                Message(role: .user, text: "go"),
                Message(role: .assistant, content: [.toolUse(ToolCall(id: "c1", name: "shell", input: .object(["command": .string("ls")])))]),
                Message(role: .user, content: [.toolResult(toolUseID: "c1", content: "out", isError: false)]),
            ],
            tools: [ToolSpec(name: "shell", description: "d", inputSchema: JSONValue.schema([]))])
        let body = OllamaProvider.body(for: request, stream: false)
        let messages = body["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?[2]["tool_calls"] != nil, true)
        XCTAssertEqual(messages?[3]["role"] as? String, "tool")
        XCTAssertEqual(messages?[3]["tool_name"] as? String, "shell")
        XCTAssertNotNil(body["tools"])
    }
}

final class GatewayTests: XCTestCase {
    func testRoutesByRoleAndRecordsUsage() async throws {
        let registry = ProviderRegistry()
        let seenModels = Locked<[String]>([])
        registry.register(ScriptedProvider(id: ClaudeCodeProvider.providerID) { request in
            seenModels.withLock { $0.append(request.model) }
            return LLMResponse(message: Message(role: .assistant, text: "ok"), usage: Usage(inputTokens: 3, outputTokens: 4))
        })
        var table = RoutingTable.claudeDefault
        table.set(.conversation, ModelRoute(provider: ClaudeCodeProvider.providerID, model: "custom-chat"))
        let finalTable = table
        let gateway = ModelGateway(registry: registry, routing: { finalTable })
        let usage = Locked<Int>(0)
        gateway.setUsageHandler { _, _, _, u in usage.withLock { $0 += u.total } }

        _ = try await gateway.complete(role: .conversation, system: "", messages: [Message(role: .user, text: "x")])
        XCTAssertEqual(seenModels.current, ["custom-chat"])
        XCTAssertEqual(usage.current, 7)
    }

    func testAllLocalPresetNeedsNoClaude() {
        let table = RoutingTable.allLocal(assistant: "chat-model")
        XCTAssertEqual(table.usesProviders, ["ollama"])
        XCTAssertEqual(table.route(for: .conversation).model, "chat-model")
        XCTAssertEqual(table.route(for: .conversation).thinking, false)
        XCTAssertEqual(RoutingTable.claudeDefault.usesProviders, [ClaudeCodeProvider.providerID])
    }

    func testThinkingFlagReachesOllamaBodyAndOldSettingsStillDecode() throws {
        let request = LLMRequest(model: "m", messages: [Message(role: .user, text: "x")], thinking: false)
        XCTAssertEqual(OllamaProvider.body(for: request, stream: false)["think"] as? Bool, false)
        let unset = LLMRequest(model: "m", messages: [Message(role: .user, text: "x")])
        XCTAssertNil(OllamaProvider.body(for: unset, stream: false)["think"])
        let old = Data("{\"provider\":\"ollama\",\"model\":\"x\"}".utf8)
        let route = try JSONDecoder().decode(ModelRoute.self, from: old)
        XCTAssertNil(route.thinking)
    }

    func testUnknownProviderThrows() async {
        let gateway = ModelGateway(registry: ProviderRegistry(), routing: { RoutingTable.claudeDefault })
        do {
            _ = try await gateway.complete(role: .conversation, system: "", messages: [Message(role: .user, text: "x")])
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error is LLMError)
        }
    }

    func testDefaultStreamReplaysCompleteResult() async throws {
        let provider = ScriptedProvider { _ in LLMResponse(message: Message(role: .assistant, text: "hello")) }
        var text = ""
        var done = false
        for try await event in provider.stream(LLMRequest(model: "m", messages: [])) {
            switch event {
            case .textDelta(let d): text += d
            case .toolCall: break
            case .done: done = true
            }
        }
        XCTAssertEqual(text, "hello")
        XCTAssertTrue(done)
    }
}

final class StoreTests: XCTestCase {
    func testEventsMessagesUsage() throws {
        let store = try DamsonStore.inMemory()
        try store.appendEvent(taskID: "a", type: "report", payload: "p1")
        try store.appendEvent(taskID: "a", type: "tool", payload: "p2")
        try store.appendEvent(taskID: "b", type: "tool", payload: "other")
        let events = try store.events(taskID: "a")
        XCTAssertEqual(events.map { $0.payload }, ["p1", "p2"])

        try store.saveMessage(id: "m1", role: "user", text: "hello", source: "text")
        try store.saveMessage(id: "m2", role: "assistant", text: "hi", source: "assistant")
        XCTAssertEqual(try store.recentMessages(limit: 10).map { $0.text }, ["hello", "hi"])

        try store.recordUsage(taskID: "a", role: "worker", provider: "anthropic", model: "m", tokensIn: 10, tokensOut: 5)
        try store.recordUsage(taskID: "a", role: "worker", provider: "anthropic", model: "m", tokensIn: 1, tokensOut: 1)
        let totals = try store.usageTotals(taskID: "a")
        XCTAssertEqual(totals.inputTokens, 11)
        XCTAssertEqual(totals.outputTokens, 6)
    }
}

final class ThinkTagFilterTests: XCTestCase {
    func testStripsInlineReasoning() {
        XCTAssertEqual(ThinkTagFilter.strip("<think>let me think</think>\nHello there"), "Hello there")
        XCTAssertEqual(ThinkTagFilter.strip("No tags here"), "No tags here")
    }

    func testHandlesTagsSplitAcrossChunks() {
        var f = ThinkTagFilter()
        var out = ""
        for chunk in ["Sure. <thi", "nk>reasoning that is", " long</th", "ink>Hello", " world"] {
            out += f.push(chunk)
        }
        out += f.flush()
        XCTAssertEqual(out, "Sure. Hello world")
    }

    func testUnfinishedReasoningIsDropped() {
        var f = ThinkTagFilter()
        var out = f.push("Answer: <think>still thinking")
        out += f.flush()
        XCTAssertEqual(out, "Answer: ")
    }

    func testLiteralLessThanIsKept() {
        XCTAssertEqual(ThinkTagFilter.strip("if a < b then"), "if a < b then")
    }
}

final class ClaudeCodeProviderTests: XCTestCase {
    func testParsesToolCallsAndStripsThemFromText() {
        let r = ClaudeCodeProvider.parse("Let me look. <tool_call>{\"name\": \"read_file\", \"input\": {\"path\": \"a.txt\"}}</tool_call>")
        XCTAssertEqual(r.text, "Let me look.")
        XCTAssertEqual(r.calls.count, 1)
        XCTAssertEqual(r.calls.first?.name, "read_file")
        XCTAssertEqual(r.calls.first?.input["path"]?.stringValue, "a.txt")
    }

    func testPlainReplyHasNoCalls() {
        let r = ClaudeCodeProvider.parse("Hello there.")
        XCTAssertEqual(r.text, "Hello there.")
        XCTAssertTrue(r.calls.isEmpty)
    }

    func testTranscriptEndsWithYourTurn() {
        let t = ClaudeCodeProvider.transcript([Message(role: .user, text: "Hi")])
        XCTAssertTrue(t.hasSuffix("[You]\n"))
        XCTAssertTrue(t.contains("[User]\nHi"))
    }
}

final class LegacyRouteTests: XCTestCase {
    func testOldAnthropicProviderMeansSubscription() throws {
        let json = #"{"provider":"anthropic","model":"claude-sonnet-5-5"}"#
        let route = try JSONDecoder().decode(ModelRoute.self, from: Data(json.utf8))
        XCTAssertEqual(route.provider, ClaudeCodeProvider.providerID)
    }
}
