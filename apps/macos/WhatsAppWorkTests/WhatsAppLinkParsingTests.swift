import XCTest
@testable import WhatsAppWork

/// wa.me / api.whatsapp.com / whatsapp:// "Continue to Chat" links parse
/// into (chat digits, prefill text); everything else is not ours.
final class WhatsAppLinkParsingTests: XCTestCase {
    func testWaMePathFormWithText() throws {
        let url = try XCTUnwrap(URL(string: "https://wa.me/6285172277259?text=vote%2052831206"))
        let parsed = AppState.parseWhatsAppChatLink(url)
        XCTAssertEqual(parsed?.digits, "6285172277259")
        XCTAssertEqual(parsed?.text, "vote 52831206")
    }

    func testWaMePathFormWithoutText() throws {
        let url = try XCTUnwrap(URL(string: "https://wa.me/254700000002"))
        let parsed = AppState.parseWhatsAppChatLink(url)
        XCTAssertEqual(parsed?.digits, "254700000002")
        XCTAssertNil(parsed?.text)
    }

    func testCustomSchemeSendForm() throws {
        let url = try XCTUnwrap(URL(string: "whatsapp://send?phone=6285172277259&text=hi%20there"))
        let parsed = AppState.parseWhatsAppChatLink(url)
        XCTAssertEqual(parsed?.digits, "6285172277259")
        XCTAssertEqual(parsed?.text, "hi there")
    }

    func testApiWhatsAppComSendForm() throws {
        let url = try XCTUnwrap(URL(string: "https://api.whatsapp.com/send?phone=254700000002&text=vote%201")))
        let parsed = AppState.parseWhatsAppChatLink(url)
        XCTAssertEqual(parsed?.digits, "254700000002")
        XCTAssertEqual(parsed?.text, "vote 1")
    }

    func testPlainExternalURLIsNotOurs() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/6285172277259"))
        XCTAssertNil(AppState.parseWhatsAppChatLink(url))
    }

    func testWaMeGarbagePathRejected() throws {
        let url = try XCTUnwrap(URL(string: "https://wa.me/not-a-number"))
        XCTAssertNil(AppState.parseWhatsAppChatLink(url))
    }
}
