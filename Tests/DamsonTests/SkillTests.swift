import XCTest
@testable import DamsonCore
@testable import DamsonProviders

final class SkillTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("skilltest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testSlug() {
        XCTAssertEqual(SkillStore.slug("Backend & APIs"), "backend-apis")
        XCTAssertEqual(SkillStore.slug("Time & effort estimation"), "time-effort-estimation")
        XCTAssertEqual(SkillStore.slug("already-a-slug"), "already-a-slug")
        XCTAssertEqual(SkillStore.slug("Çeviri Şimdi"), "ceviri-simdi")
    }

    func testParseFrontmatter() {
        let (meta, body) = SkillStore.parse("---\nname: pirate\ndescription: >\n  Use when greeting.\n  Be nice.\n---\nAlways say ARRR.\n")
        XCTAssertEqual(meta["name"], "pirate")
        XCTAssertEqual(meta["description"], "Use when greeting. Be nice.")
        XCTAssertEqual(body, "Always say ARRR.")
    }

    func testSaveAndListIsRealSkillMd() throws {
        let root = tempDir()
        try SkillStore.save(name: "Code Review", description: "Use for \"reviews\".", body: "Check edge cases.", in: root)
        let file = root.appendingPathComponent("code-review/SKILL.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: code-review\n"))
        let all = SkillStore.list(damson: root, claude: tempDir())
        XCTAssertEqual(all.map { $0.name }, ["code-review"])
        XCTAssertEqual(all[0].description, "Use for \"reviews\".")
        XCTAssertEqual(all[0].body, "Check edge cases.")
        SkillStore.delete(name: "Code Review", in: root)
        XCTAssertTrue(SkillStore.list(damson: root, claude: tempDir()).isEmpty)
    }

    func testDamsonSkillShadowsClaudeSkill() throws {
        let d = tempDir(), c = tempDir()
        try SkillStore.save(name: "pirate", description: "mine", body: "x", in: d)
        try SkillStore.save(name: "pirate", description: "theirs", body: "y", in: c)
        try SkillStore.save(name: "robot", description: "r", body: "z", in: c)
        let all = SkillStore.list(damson: d, claude: c)
        XCTAssertEqual(all.first { $0.name == "pirate" }?.source, .damson)
        XCTAssertEqual(all.first { $0.name == "robot" }?.source, .claude)
    }

    func testSeedBuiltinsDoesNotOverwriteEdits() throws {
        let root = tempDir()
        SkillStore.seedBuiltins(in: root)
        XCTAssertEqual(SkillStore.list(damson: root, claude: tempDir()).count, Skill.builtins.count)
        try SkillStore.save(name: "Testing & QA", description: "edited", body: "mine", in: root)
        SkillStore.seedBuiltins(in: root)
        XCTAssertEqual(SkillStore.list(damson: root, claude: tempDir()).first { $0.name == "testing-qa" }?.body, "mine")
    }

    func testSelectionSplitsAllowedAndBlocked() throws {
        let root = tempDir()
        try SkillStore.save(name: "a", description: "d", body: "b", in: root)
        try SkillStore.save(name: "b", description: "d", body: "b", in: root)
        let all = SkillStore.list(damson: root, claude: tempDir())
        let sel = SkillStore.selection(for: ["A"], all: all)
        XCTAssertEqual(sel.refs.map { $0.name }, ["a"])
        XCTAssertEqual(sel.blocked, ["b"])
    }

    func testOldCompanyFileIsMigrated() throws {
        let json = """
        {"name":"X","teams":[{"id":"t","name":"T","members":[{"id":"p","name":"P Q","role":"R","skills":["Backend & APIs"]}]}],
         "skillLibrary":[{"name":"Custom thing","instructions":"Do it."}]}
        """
        let c = try JSONDecoder().decode(Company.self, from: Data(json.utf8))
        XCTAssertEqual(c.teams[0].members[0].skills, ["backend-apis"])
        XCTAssertEqual(c.legacySkills.map { $0.name }, ["Custom thing"])
        let back = String(data: try JSONEncoder().encode(c), encoding: .utf8) ?? ""
        XCTAssertFalse(back.contains("skillLibrary"))
    }
}
