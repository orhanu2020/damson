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
    private func team(_ n: String) -> Team { Team(id: n, name: n, members: [Person(id: n + "1", name: n + " A", role: "r"), Person(id: n + "2", name: n + " B", role: "r")]) }
    private var company: Company {
        Company(name: "X", teams: ["Project Management", "Business Analysis", "Dev", "Platform", "Deployment", "Test"].map(team))
    }

    func testFindsTeamsByName() {
        let c = company
        XCTAssertEqual(ProjectFlow.team(for: .projectManagement, in: c)?.name, "Project Management")
        XCTAssertEqual(ProjectFlow.team(for: .businessAnalysis, in: c)?.name, "Business Analysis")
        XCTAssertEqual(ProjectFlow.team(for: .dev, in: c)?.name, "Dev")
        XCTAssertEqual(ProjectFlow.team(for: .platform, in: c)?.name, "Platform")
        XCTAssertEqual(ProjectFlow.team(for: .deployment, in: c)?.name, "Deployment")
        XCTAssertEqual(ProjectFlow.team(for: .test, in: c)?.name, "Test")
        XCTAssertNil(ProjectFlow.team(for: .test, in: Company(name: "X", teams: [team("Design")])))
        // "DevOps" is a platform team, not the dev team.
        let ops = Company(name: "X", teams: [team("DevOps"), team("Dev")])
        XCTAssertEqual(ProjectFlow.team(for: .dev, in: ops)?.name, "Dev")
        XCTAssertEqual(ProjectFlow.team(for: .platform, in: ops)?.name, "DevOps")
    }

    func testDefaultFlowMatchesTheProcess() {
        let ids = ProjectFlow.defaultSteps(environments: ["qa", "uat", "production"]).map { $0.id }
        XCTAssertEqual(ids, ["requirements", "estimate", "build", "review",
                             "approval-qa", "provision-qa", "deploy-qa", "test-qa",
                             "approval-uat", "provision-uat", "deploy-uat", "test-uat",
                             "approval-production", "provision-production", "deploy-production"])
    }

    func testEveryAgentStepLeavesAFileAndGatesLeaveNone() {
        let steps = ProjectFlow.defaultSteps(environments: ["qa", "uat", "production"])
        let files = steps.compactMap { $0.outputFile }
        XCTAssertEqual(files.count, Set(files).count)
        XCTAssertEqual(steps.filter { $0.outputFile == nil }.map { $0.kind }, [.approval, .approval, .approval])
    }

    func testReviewIsDoneByAnotherDevAgent() {
        let c = company
        XCTAssertEqual(ProjectFlow.agent(for: FlowStep(kind: .build), in: c)?.person.id, "Dev1")
        XCTAssertEqual(ProjectFlow.agent(for: FlowStep(kind: .review), in: c)?.person.id, "Dev2")
        XCTAssertEqual(ProjectFlow.agent(for: FlowStep(kind: .deploy, env: "qa"), in: c)?.team.name, "Deployment")
    }

    func testVerdictParsing() {
        XCTAssertEqual(ProjectFlow.verdict(of: "# Report\nVerdict: PASS"), .pass)
        XCTAssertEqual(ProjectFlow.verdict(of: "x\nVerdict: FAIL"), .fail)
        XCTAssertEqual(ProjectFlow.verdict(of: "x\nVerdict: CHANGES REQUESTED"), .fail)
        XCTAssertEqual(ProjectFlow.verdict(of: "x\nStatus: DEPLOYED"), .pass)
        XCTAssertEqual(ProjectFlow.verdict(of: "x\nStatus: FAILED"), .fail)
        XCTAssertEqual(ProjectFlow.verdict(of: "just text"), .unknown)
        // Prose that merely mentions a status or a failure is not a verdict; the closing line decides.
        XCTAssertEqual(ProjectFlow.verdict(of: "A bad data file exits with status 1 and could fail.\nVerdict: APPROVED"), .pass)
        XCTAssertEqual(ProjectFlow.verdict(of: "Status: READY earlier\n\n**Verdict: FAIL**"), .fail)
        XCTAssertEqual(ProjectFlow.verdict(of: "Verdict: PASS\nSome later sentence about failure."), .pass)
    }

    func testGateShowsTheReportBeforeIt() {
        let p = Project(name: "A", brief: "b", folder: "/tmp/a")
        let qaGate = p.steps.firstIndex { $0.id == "approval-qa" }!
        let uatGate = p.steps.firstIndex { $0.id == "approval-uat" }!
        XCTAssertEqual(p.reportBefore(qaGate), "reports/review-report.md")
        XCTAssertEqual(p.reportBefore(uatGate), "reports/qa-test-report.md")
    }

    func testInstructionsUseEnvironmentSettings() {
        var p = Project(name: "A", brief: "b", folder: "/tmp/a")
        p.environments[0] = EnvSettings(name: "qa", target: .aws, options: ["region": "eu-west-1", "profile": "dev"])
        let text = ProjectFlow.instruction(for: FlowStep(kind: .deploy, env: "qa"), project: p)
        XCTAssertTrue(text.contains("AWS (AWS CLI profile: dev, Region: eu-west-1)"))
        XCTAssertTrue(text.contains("deploy/qa-notice.md"))
        let prod = ProjectFlow.instruction(for: FlowStep(kind: .deploy, env: "production"), project: p)
        XCTAssertTrue(prod.contains("reports/production-release.md"))
        XCTAssertFalse(text.contains("reports/production-release.md"))
    }

    func testOldProjectFileStillLoads() throws {
        let json = #"{"id":"1","name":"Old","brief":"b","folder":"/tmp/o","createdAt":"2026-01-01T00:00:00Z","stages":[{"kind":"requirements","status":"done"}]}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let p = try d.decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.steps.count, 15)
        XCTAssertEqual(p.environments.map { $0.name }, ["qa", "uat", "production"])
    }

    func testSlug() {
        XCTAssertEqual(ProjectFlow.slug("Müşteri Portalı 2"), "musteri-portali-2")
    }
}
