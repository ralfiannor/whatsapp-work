import XCTest
@testable import WhatsAppWork

final class MentionTextTests: XCTestCase {
    private func tokens(_ text: String, labels: [String]) -> [String] {
        MentionTokenMatcher.matchedRanges(text: text, labels: labels).map { String(text[$0]) }
    }

    func testWholeWordBoundariesOnly() {
        // "@Ann" standalone matches; the "@Ann" inside "@Anna" and after
        // "x" do not.
        XCTAssertEqual(tokens("hi @Ann and @Anna and x@Ann", labels: ["Ann"]), ["@Ann"])
    }

    func testStartAndEndBoundaries() {
        XCTAssertEqual(tokens("@Ann", labels: ["Ann"]), ["@Ann"])
        XCTAssertEqual(tokens("see @Ann", labels: ["Ann"]), ["@Ann"])
    }

    func testMultipleLabelsAndMultipleOccurrences() {
        XCTAssertEqual(tokens("@Ann tell @Bob", labels: ["Ann", "Bob"]), ["@Ann", "@Bob"])
        XCTAssertEqual(tokens("@Ann … @Ann", labels: ["Ann"]), ["@Ann", "@Ann"])
    }

    func testUnresolvedTokensNeverMatch() {
        XCTAssertEqual(tokens("@ghost hello", labels: ["Ann"]), [])
        XCTAssertEqual(tokens("@Ann hello", labels: []), [])
    }
}
