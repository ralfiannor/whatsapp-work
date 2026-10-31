import XCTest
@testable import WhatsAppWork

/// Content-less "unsupported" rows render a label instead of a blank line;
/// real content (text, a later upgrade, a deletion) always wins.
final class PlaceholderLabelTests: XCTestCase {
    private func row(kind: String, raw: String?, text: String? = nil, revoked: Bool = false) -> Message {
        Message(id: 1, message_id: "p1", chat_jid: "1203630000000000@g.us",
                sender_jid: "6285000000001@s.whatsapp.net", from_me: false,
                timestamp: 1_700_000_100, kind: kind, text: text, reply_to_id: nil,
                reply_to_sender: nil, quoted_text: nil, has_mention: false, receipt_status: nil,
                revoked: revoked, forwarded: nil, edited_ts: nil, raw_kind: raw,
                media: nil, reactions: nil)
    }

    func testDecryptFailurePlaceholders() {
        XCTAssertEqual(MessageTextRenderer.placeholderLabel(row(kind: "unsupported", raw: "pending")),
                       "Waiting for this message")
        XCTAssertEqual(MessageTextRenderer.placeholderLabel(row(kind: "unsupported", raw: "view_once")),
                       "View once message (open it on your phone)")
    }

    func testOtherUnsupportedRowsAreNeverBlank() {
        XCTAssertEqual(MessageTextRenderer.placeholderLabel(row(kind: "unsupported", raw: "poll")), "Poll")
        XCTAssertEqual(MessageTextRenderer.placeholderLabel(row(kind: "unsupported", raw: "unknown")), "Message")
        XCTAssertEqual(MessageTextRenderer.placeholderLabel(row(kind: "unsupported", raw: nil)), "Message")
    }

    func testRealContentWins() {
        XCTAssertNil(MessageTextRenderer.placeholderLabel(row(kind: "image", raw: nil)))
        XCTAssertNil(MessageTextRenderer.placeholderLabel(row(kind: "unsupported", raw: "pending", text: "hi")))
        XCTAssertNil(MessageTextRenderer.placeholderLabel(row(kind: "unsupported", raw: "pending", revoked: true)))
    }
}
