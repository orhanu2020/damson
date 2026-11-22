import XCTest
@testable import DamsonCore
@testable import DamsonProviders

final class SkillTests: XCTestCase {
    private func makeSkills(_ items: [(String, String)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("skilltest-\(UUID().uuidString)")
        for (name, front) in items {
            let dir = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\n\(front)\n---\nBody".write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    func testListReadsFrontmatter() throws {
        let root = try makeSkills([("pirate", "name: pirate\ndescription: >\n  Use when greeting.\n  Be nice."), ("robot", "description: \"Use for goodbyes\"")])
        let all = SkillStore.list(in: root)
        XCTAssertEqual(all.map { $0.name }, ["pirate", "robot"])   // robot falls back to the folder name
        XCTAssertEqual(all[0].description, "Use when greeting. Be nice.")
        XCTAssertEqual(all[1].description, "Use for goodbyes")
    }

    func testFoldersWithoutSkillMdAreIgnoredAndMissingRootIsEmpty() throws {
        let root = try makeSkills([("a", "name: a")])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("not-a-skill"), withIntermediateDirectories: true)
        XCTAssertEqual(SkillStore.list(in: root).map { $0.name }, ["a"])
        XCTAssertTrue(SkillStore.list(in: root.appendingPathComponent("nope")).isEmpty)
    }

    func testSelectionSplitsAllowedAndBlocked() throws {
        let root = try makeSkills([("a", "name: a"), ("b", "name: b")])
        let sel = SkillStore.selection(for: ["a", "gone"], all: SkillStore.list(in: root))
        XCTAssertEqual(sel.refs.map { $0.name }, ["a"])
        XCTAssertEqual(sel.blocked, ["b"])
    }

    func testOldCompanyFileStillLoads() throws {
        let json = """
        {"name":"X","teams":[{"id":"t","name":"T","members":[{"id":"p","name":"P Q","role":"R","skills":["Backend & APIs"]}]}],
         "skillLibrary":[{"name":"Custom thing","instructions":"Do it."}]}
        """
        let c = try JSONDecoder().decode(Company.self, from: Data(json.utf8))
        XCTAssertEqual(c.teams[0].members[0].name, "P Q")
        XCTAssertFalse((String(data: try JSONEncoder().encode(c), encoding: .utf8) ?? "").contains("skillLibrary"))
    }
}
