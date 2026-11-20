import XCTest
import DamsonSupport
import DamsonProviders
import DamsonStore
import DamsonTools
@testable import DamsonCore

final class TextTests: XCTestCase {
    func testJSONExtractorFindsObjectInProse() {
        let text = "Sure! Here you go:\n```json\n{\"level\": \"complex\", \"title\": \"A {tricky} title\"}\n```\nHope that helps."
        let json = JSONExtractor.firstObject(in: text)
        XCTAssertEqual(json?.string("level"), "complex")
        XCTAssertEqual(json?.string("title"), "A {tricky} title")
    }

    func testJSONExtractorReturnsNilWithoutObject() {
        XCTAssertNil(JSONExtractor.firstObject(in: "no json here"))
        XCTAssertNil(JSONExtractor.firstObject(in: "{ broken"))
    }

    func testSentenceSplitter() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.push("Hello there, my friend. How are"), ["Hello there, my friend."])
        XCTAssertEqual(splitter.push(" you doing today? Fine."), ["How are you doing today?"])
        XCTAssertEqual(splitter.flush(), "Fine.")
        XCTAssertNil(splitter.flush())
    }

    func testSentenceSplitterDoesNotSplitAbbreviationsEarly() {
        var splitter = SentenceSplitter()
        let sentences = splitter.push("Dr. Smith is here. Next one")
        XCTAssertEqual(sentences, ["Dr. Smith is here."])
    }
}

final class EngineLogicTests: XCTestCase {
    func testApprovalPhrases() {
        XCTAssertEqual(DamsonEngine.approvalDecision(for: "Approve."), .approveOnce)
        XCTAssertEqual(DamsonEngine.approvalDecision(for: "yes, go ahead"), .approveOnce)
        XCTAssertNil(DamsonEngine.approvalDecision(for: "yes go ahead and also delete everything"))   // only exact phrases count
        XCTAssertEqual(DamsonEngine.approvalDecision(for: "Go ahead!"), .approveOnce)
        XCTAssertEqual(DamsonEngine.approvalDecision(for: "approve for this task"), .approveForTask)
        XCTAssertEqual(DamsonEngine.approvalDecision(for: "Deny"), .deny)
        XCTAssertEqual(DamsonEngine.approvalDecision(for: "No"), .deny)
        XCTAssertEqual(DamsonEngine.approvalDecision(for: "Don't do it"), .deny)
        XCTAssertNil(DamsonEngine.approvalDecision(for: "what is the weather"))
        XCTAssertNil(DamsonEngine.approvalDecision(for: "approve everything forever and always"))
    }

    func testSettingsDecodeIsLenient() throws {
        let old = Data("{\"verbosity\":\"detailed\"}".utf8)
        let s = try JSONDecoder().decode(DamsonSettings.self, from: old)
        XCTAssertEqual(s.verbosity, .detailed)
        XCTAssertEqual(s.style, .formal)                   // default kept
        XCTAssertEqual(s.routing, RoutingTable.claudeDefault)
    }

    func testApprovalCenterResolves() async {
        let center = ApprovalCenter()
        let request = ApprovalRequest(id: "r1", taskID: "t", subtaskID: "s", tool: "shell", summary: "rm x", createdAt: Date())
        async let decision = center.requestApproval(request)
        // wait until it is registered
        for _ in 0..<100 {
            if !center.pendingRequests().isEmpty { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(center.pendingRequests().count, 1)
        center.resolve(id: "r1", decision: .approveOnce)
        let result = await decision
        XCTAssertEqual(result, .approveOnce)
        XCTAssertTrue(center.pendingRequests().isEmpty)
    }
}

final class ProjectFlowTests: XCTestCase {
    func testFindsTeamsByName() {
        func team(_ n: String) -> Team { Team(id: n, name: n, members: []) }
        let c = Company(name: "X", teams: [team("Project Management"), team("Business Analysis"), team("Dev"), team("Test")])
        XCTAssertEqual(ProjectFlow.team(for: .estimate, in: c)?.name, "Project Management")
        XCTAssertEqual(ProjectFlow.team(for: .requirements, in: c)?.name, "Business Analysis")
        XCTAssertEqual(ProjectFlow.team(for: .development, in: c)?.name, "Dev")
        XCTAssertEqual(ProjectFlow.team(for: .testing, in: c)?.name, "Test")
        XCTAssertNil(ProjectFlow.team(for: .testing, in: Company(name: "X", teams: [team("Design")])))
    }

    func testSlugAndHandoffFiles() {
        XCTAssertEqual(ProjectFlow.slug("Müşteri Portalı 2"), "musteri-portali-2")
        XCTAssertEqual(StageKind.allCases.map { $0.outputFile }.count, Set(StageKind.allCases.map { $0.outputFile }).count)
        let p = Project(name: "A", brief: "b", folder: "/tmp/a")
        XCTAssertTrue(ProjectFlow.instruction(for: .development, project: p).contains("handoff/03-deploy-notice.md"))
        XCTAssertTrue(ProjectFlow.instruction(for: .testing, project: p).contains("handoff/03-deploy-notice.md"))
    }
}
