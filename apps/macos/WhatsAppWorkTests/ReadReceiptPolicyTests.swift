import XCTest
@testable import WhatsAppWork

final class ReadReceiptPolicyTests: XCTestCase {
    let group = "1203630000000000@g.us"
    let dm = "254700000002@s.whatsapp.net"

    func testGroupsAlwaysSendReceipts() {
        XCTAssertTrue(ReadReceiptPolicy.shouldSendReceipt(chatJID: group, suppressDMReceipts: true))
        XCTAssertTrue(ReadReceiptPolicy.shouldSendReceipt(chatJID: group, suppressDMReceipts: false))
    }

    func testDMsSuppressedOnlyWhenSettingOn() {
        XCTAssertFalse(ReadReceiptPolicy.shouldSendReceipt(chatJID: dm, suppressDMReceipts: true))
        XCTAssertTrue(ReadReceiptPolicy.shouldSendReceipt(chatJID: dm, suppressDMReceipts: false))
    }
}
