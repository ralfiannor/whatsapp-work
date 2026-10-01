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

/// Wire rewrite: whole-token digit replacement in every group — the exact
/// case that corrupted on receivers ("@Nura Biks" → "@Nura Biks Biks")
/// when a word-boundary fallback ate only the first word of a multi-word
/// label.
final class WireMentionTextTests: XCTestCase {
    private let group = "120363410035450855@g.us"
    private let nura = "4915204107177@s.whatsapp.net"

    private func member(_ jid: String, lid: String? = nil) -> APIClient.GroupMember {
        APIClient.GroupMember(jid: jid, display_name: nil, role: "member", lid: lid)
    }

    func testMultiWordLabelReplacedWholeInNonLIDGroup() {
        // Member HAS a lid twin, but a non-LID group sends the PN mention
        // (core pass-through) — the token must carry PN digits or WhatsApp
        // renders it as plain text (digits ≠ MentionedJID never binds).
        let out = AppState.wireMentionText(
            "@Nura Biks lu ada update?", chat: group, mentioned: [nura],
            targets: [nura: "Nura Biks"], members: [member(nura, lid: "229055001571436@lid")])
        XCTAssertEqual(out, "@4915204107177 lu ada update?")
    }

    func testLIDSpaceMemberUsesLIDDigits() {
        let lidGroup = "4782936427-1234567890@g.us"
        let out = AppState.wireMentionText(
            "@Nura Biks x", chat: lidGroup, mentioned: [nura],
            targets: [nura: "Nura Biks"], members: [member(nura, lid: "34411378638957@lid")])
        XCTAssertEqual(out, "@34411378638957 x")
    }

    func testDirectChatUntouched() {
        let out = AppState.wireMentionText(
            "@Nura Biks x", chat: nura, mentioned: [nura],
            targets: [nura: "Nura Biks"], members: [member(nura)])
        XCTAssertEqual(out, "@Nura Biks x")
    }

    func testRosterMissKeepsLabel() {
        let out = AppState.wireMentionText(
            "@Nura Biks x", chat: group, mentioned: [nura],
            targets: [nura: "Nura Biks"], members: [])
        XCTAssertEqual(out, "@Nura Biks x")
    }

    func testLongerWordSuffixNotReplaced() {
        let out = AppState.wireMentionText(
            "@Anna hi", chat: group, mentioned: [nura],
            targets: [nura: "Ann"], members: [member(nura)])
        XCTAssertEqual(out, "@Anna hi")
    }
}
