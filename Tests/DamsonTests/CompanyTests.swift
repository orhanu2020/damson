import XCTest
@testable import DamsonCore

final class CompanyTests: XCTestCase {
    let company = Company.sample

    func ids(_ text: String) -> [String]? {
        return CompanyCommandParser.parse(text, company: company)?.people.map { $0.id }
    }

    func testFoldingTurkishLetters() {
        XCTAssertEqual(CompanyCommandParser.fold("İSTANBUL ŞEHRİ"), "istanbul sehri")
        XCTAssertEqual(CompanyCommandParser.fold("Çığ güneş"), "cig gunes")
    }

    func testSelectsPersonWithTurkishSuffixes() {
        XCTAssertEqual(ids("Ayşe'yi seç"), ["ayse"])
        XCTAssertEqual(ids("Ayşeyi seç"), ["ayse"])
        XCTAssertEqual(ids("ayse"), ["ayse"])
    }

    func testSelectsSeveralPeopleInCompanyOrder() {
        XCTAssertEqual(ids("Mehmet ve AYŞE raporu hazırlasın"), ["ayse", "mehmet"])
        XCTAssertEqual(ids("Elif, Burak ve Selin toplansın"), ["elif", "burak", "selin"])
    }

    func testSelectsWholeTeam() {
        XCTAssertEqual(ids("select the software team"), ["ayse", "mehmet", "zeynep", "can"])
        XCTAssertEqual(ids("design team please"), ["elif", "burak", "selin"])
    }

    func testShortNamesNeedAnExactMatch() {
        XCTAssertEqual(ids("Can'a söyle"), ["can"])
        XCTAssertNil(ids("canım benim"))
    }

    func testUnrelatedTextSelectsNobody() {
        XCTAssertNil(ids("bugün hava nasıl"))
        XCTAssertNil(ids(""))
    }

    func testInitials() {
        XCTAssertEqual(Person(id: "a", name: "Ayşe Kaya", role: "").initials, "AK")
        XCTAssertEqual(Person(id: "s", name: "Şule Çelik", role: "").initials, "ŞÇ")
    }

    func testStubAgentJustAcknowledges() async {
        let reply = await StubTeamAgent(delayNanoseconds: 0).handle(command: "raporu hazırla", for: company.allPeople[0])
        XCTAssertEqual(reply, "Very well.")
    }

    func testSampleCompanyHasUniqueFirstNames() {
        let names = company.allPeople.map { CompanyCommandParser.fold($0.firstName) }
        XCTAssertEqual(Set(names).count, names.count)
    }
}

final class LangGraphAgentTests: XCTestCase {
    func testFallsBackWhenServerIsDown() async {
        let agent = LangGraphTeamAgent(endpoint: URL(string: "http://127.0.0.1:1/run")!, timeout: 2)
        let reply = await agent.handle(command: "x", for: Company.sample.allPeople[0])
        XCTAssertEqual(reply, "Very well.")
    }
}
