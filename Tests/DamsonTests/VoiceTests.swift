import XCTest
@testable import DamsonVoice

final class SpeechTextTests: XCTestCase {
    func testCleanStripsMarkdownAndLinks() {
        XCTAssertEqual(SpeechText.clean("**Hello** see https://example.com/a?b=1 now"), "Hello see a link now")
    }

    func testEndPhrases() {
        XCTAssertTrue(SpeechText.isEndPhrase("That's all."))
        XCTAssertTrue(SpeechText.isEndPhrase("Thank you Damson"))
        XCTAssertTrue(SpeechText.isEndPhrase("thanks, Damson!"))
        XCTAssertFalse(SpeechText.isEndPhrase("what is all this"))
        XCTAssertFalse(SpeechText.isEndPhrase("thanks for the report, now do the next one"))
    }
}

final class TurnDetectorTests: XCTestCase {
    func testDetectsStartAndEndOfSpeech() {
        var d = TurnDetector()
        var events: [TurnEvent] = []
        func feed(_ level: Float, frames: Int) {
            for _ in 0..<frames {
                if let e = d.ingest(levelDB: level, duration: 0.1) { events.append(e) }
            }
        }
        feed(-70, frames: 10)    // quiet room
        feed(-20, frames: 5)     // talking
        feed(-70, frames: 15)    // pause
        XCTAssertEqual(events, [.speechStarted, .speechEnded])
    }

    func testShortBlipsAreIgnored() {
        var d = TurnDetector()
        var events: [TurnEvent] = []
        for _ in 0..<10 { if let e = d.ingest(levelDB: -70, duration: 0.1) { events.append(e) } }
        if let e = d.ingest(levelDB: -20, duration: 0.05) { events.append(e) }   // 50 ms click
        for _ in 0..<20 { if let e = d.ingest(levelDB: -70, duration: 0.1) { events.append(e) } }
        XCTAssertTrue(events.isEmpty)
    }

    func testSpeechDoesNotEndDuringShortPause() {
        var d = TurnDetector()
        var events: [TurnEvent] = []
        for _ in 0..<5 { if let e = d.ingest(levelDB: -20, duration: 0.1) { events.append(e) } }
        for _ in 0..<4 { if let e = d.ingest(levelDB: -70, duration: 0.1) { events.append(e) } }   // 0.4 s pause
        for _ in 0..<5 { if let e = d.ingest(levelDB: -20, duration: 0.1) { events.append(e) } }
        XCTAssertEqual(events, [.speechStarted])
    }
}
