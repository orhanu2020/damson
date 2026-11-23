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
        Company(name: "X", teams: ["Design", "Business Analysis", "Dev", "Platform", "Deployment", "Test"].map(team))
    }

    func testGraphRunsInOrderAndRoutesOnVerdict() {
        var p = Project(name: "G", brief: "b", folder: "/tmp/g")
        p.steps = []; p.edges = []
        let a = p.addStep(kind: .build, at: .zero)
        let r = p.addStep(kind: .review, at: .zero)
        let ok = p.addStep(kind: .deploy, env: "qa", at: .zero)
        let fix = p.addStep(kind: .task, at: .zero)
        XCTAssertTrue(p.connect(from: a, to: r))
        XCTAssertTrue(p.connect(from: r, to: ok, condition: .pass))
        XCTAssertTrue(p.connect(from: r, to: fix, condition: .fail))
        XCTAssertEqual(ProjectFlow.ready(in: p), [a])
        p.steps[0].status = .done
        XCTAssertEqual(ProjectFlow.ready(in: p), [r])
        p.steps[1].status = .done; p.steps[1].badVerdict = true
        XCTAssertEqual(ProjectFlow.ready(in: p), [fix])
        XCTAssertEqual(ProjectFlow.toSkip(in: p), [ok])
    }

    func testAgentsAreFoundByCapabilityNotTeam() {
        let tester = Person(id: "t1", name: "Tess Tester", role: "QA", capability: "Test")
        let other = Person(id: "o1", name: "Olly", role: "Dev", capability: "Development")
        let c = Company(name: "X", teams: [Team(id: "pool", name: "Agents", members: [other, tester])])
        XCTAssertEqual(ProjectFlow.capability(of: tester, in: c), "Test")
        XCTAssertEqual(ProjectFlow.agent(for: FlowStep(kind: .test, env: "qa"), in: c)?.person.id, "t1")
        XCTAssertNil(ProjectFlow.agent(for: FlowStep(kind: .design), in: c))
        var chosen = FlowStep(kind: .design)
        chosen.agentIDs = ["o1"]
        XCTAssertEqual(ProjectFlow.agents(for: chosen, in: c).map { $0.person.id }, ["o1"])
    }

    func testSidesAndReconnect() throws {
        var p = Project(name: "X", brief: "", folder: "/tmp/x")
        XCTAssertTrue(p.connect(from: "requirements", to: "build", fromSide: .bottom, toSide: .top))
        let e = p.edges.first { $0.id == "requirements->build" }!
        XCTAssertEqual(e.fromSide, .bottom)
        let back = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.edges.first { $0.id == "requirements->build" }?.toSide, .top)
        // Move the end to another step and another side.
        XCTAssertEqual(p.reconnect("requirements->build", to: "review", fromSide: .bottom, toSide: .left), "requirements->review")
        XCTAssertNil(p.reconnect("requirements->review", to: "requirements", fromSide: nil, toSide: nil))
        XCTAssertTrue(p.edges.contains { $0.id == "requirements->review" })
    }

    func testOrderedStepsFollowTheProcess() {
        var p = Project(name: "X", brief: "", folder: "/tmp/x")
        let id = p.addStep(kind: .task, at: CGPoint(x: 0, y: 0))
        p.connect(from: "review", to: id)
        let ids = p.orderedSteps.map { $0.id }
        XCTAssertEqual(ids.count, p.steps.count)
        XCTAssertEqual(ids.first, "requirements")
        XCTAssertTrue(ids.firstIndex(of: "review")! < ids.firstIndex(of: id)!)
    }

    func testStepAgentsAndLegacyDecode() throws {
        var step = FlowStep(kind: .build)
        step.agentIDs = ["a", "b"]
        XCTAssertEqual(step.agentID, "a")
        let back = try JSONDecoder().decode(FlowStep.self, from: JSONEncoder().encode(step))
        XCTAssertEqual(back.agentIDs, ["a", "b"])
        let legacy = #"{"id":"x","kind":"task","agentID":"z"}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FlowStep.self, from: legacy).agentIDs, ["z"])
    }

    func testInsertDuplicateAndNotes() {
        var p = Project(name: "X", brief: "", folder: "/tmp/x")
        let edge = p.edges.first { $0.from == "requirements" && $0.to == "design" }!
        let id = p.insertStep(kind: .approval, on: edge.id)!
        XCTAssertFalse(p.edges.contains { $0.id == edge.id })
        XCTAssertTrue(p.edges.contains { $0.from == "requirements" && $0.to == id })
        XCTAssertTrue(p.edges.contains { $0.from == id && $0.to == "design" })
        let copy = p.duplicateStep("build")!
        XCTAssertNotEqual(copy, "build")
        XCTAssertEqual(p.step(copy)?.kind, .build)
        p.notes.append(FlowNote(text: "hi", x: 1, y: 2))
        let data = try! JSONEncoder().encode(p)
        let back = try! JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(back.notes.first?.text, "hi")
    }

    func testConnectionsCannotLoopOrRepeat() {
        var p = Project(name: "G", brief: "b", folder: "/tmp/g")
        p.steps = []; p.edges = []
        let a = p.addStep(kind: .task, at: .zero), b = p.addStep(kind: .task, at: .zero), c = p.addStep(kind: .task, at: .zero)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(p.connect(from: a, to: b))
        XCTAssertTrue(p.connect(from: b, to: c))
        XCTAssertTrue(p.connect(from: c, to: a))
        XCTAssertEqual(p.edges.last, FlowEdge(from: c, to: a, loop: true))
        XCTAssertEqual(p.edges.last?.condition, .fail)
        XCTAssertFalse(p.connect(from: a, to: b))
        XCTAssertFalse(p.connect(from: a, to: a))
        XCTAssertEqual(p.downstream(of: b), [b, c])
        p.removeStep(b)
        XCTAssertFalse(p.edges.contains { $0.from == b || $0.to == b })
    }

    func testFailedReviewSendsWorkBackOnlyAlongTheLoop() {
        var p = Project(name: "L", brief: "b", folder: "/tmp/l")
        for id in ["requirements", "design", "build"] { p.steps[p.steps.firstIndex { $0.id == id }!].status = .done }
        let r = p.steps.firstIndex { $0.id == "review" }!
        p.steps[r].status = .done; p.steps[r].badVerdict = true
        // The forward edge needs a pass, so the approval is skipped; the loop edge is not an ordinary dependency.
        XCTAssertEqual(ProjectFlow.toSkip(in: p), ["approval-qa"])
        XCTAssertFalse(ProjectFlow.ready(in: p).contains("build"))
        var build = FlowStep(kind: .build)
        build.round = 2; build.feedback = "reports/review-report.md"
        let text = ProjectFlow.instruction(for: build, project: p)
        XCTAssertTrue(text.contains("REWORK ROUND 2 OF 3") && text.contains("reports/review-report.md"))
        XCTAssertEqual(ProjectFlow.maxLoops, 3)
        XCTAssertTrue(p.downstream(of: "build").contains("review"))
    }

    func testJoinWaitsForAllBranchesAndDefaultProcessIsAChain() {
        let p = Project(name: "D", brief: "b", folder: "/tmp/d")
        XCTAssertEqual(p.edges.count, p.steps.count - 1 + 3)
        XCTAssertEqual(p.edges.filter { $0.loop }.map { $0.from }, ["review", "test-qa", "test-uat"])
        XCTAssertTrue(p.edges.filter { $0.loop }.allSatisfy { $0.to == "build" })
        XCTAssertEqual(ProjectFlow.ready(in: p), ["requirements"])
        XCTAssertTrue(p.steps.allSatisfy { $0.x > 0 })
        XCTAssertEqual(p.reportBefore(p.steps.firstIndex { $0.id == "approval-qa" }!), "reports/review-report.md")
    }

    func testProjectWithoutGraphFieldsStillLoads() throws {
        let json = """
        {"id":"1","name":"Old","brief":"b","folder":"/tmp/o","createdAt":"2026-01-01T00:00:00Z",
         "steps":[{"id":"requirements","kind":"requirements","status":"done"},{"id":"design","kind":"design","status":"pending"}]}
        """
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let p = try d.decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(p.edges, [FlowEdge(from: "requirements", to: "design")])
        XCTAssertEqual(ProjectFlow.ready(in: p), ["design"])
        XCTAssertTrue(p.teamIDs.isEmpty && p.usesTeam("any"))
    }

    func testCustomTaskGoesToChosenAgent() {
        var c = Company(name: "X", teams: [team("Dev")])
        c.teams[0].members[0].id = "dev1"
        var s = FlowStep(kind: .task, id: "task")
        s.agentID = "dev1"
        XCTAssertEqual(ProjectFlow.agent(for: s, in: c)?.person.id, "dev1")
        s.agentID = nil; s.customRole = .dev
        XCTAssertEqual(ProjectFlow.agent(for: s, in: c)?.team.name, "Dev")
        s.extra = "Write a haiku"
        let p = Project(name: "T", brief: "b", folder: "/tmp/t")
        XCTAssertTrue(ProjectFlow.instruction(for: s, project: p).contains("Write a haiku"))
        XCTAssertEqual(s.outputFile, "reports/task.md")
    }

    func testFindsTeamsByName() {
        let c = company
        XCTAssertEqual(ProjectFlow.team(for: .design, in: c)?.name, "Design")
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
        XCTAssertEqual(ids, ["requirements", "design", "build", "review",
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
