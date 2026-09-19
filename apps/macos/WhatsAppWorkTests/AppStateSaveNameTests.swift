import XCTest
@testable import WhatsAppWork

final class AppStateSaveNameTests: XCTestCase {
    func testStoredFilenameWins() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: "report.pdf", kind: "document", mime: "application/pdf", rowID: 7),
            "report.pdf")
    }

    func testMissingFilenameDerivesKindRowIDAndMIMEExtension() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: nil, kind: "image", mime: "image/jpeg", rowID: 42),
            "Image-42.jpg")
    }

    func testPathSeparatorsAreSanitized() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: "a/b.png", kind: "image", mime: "image/png", rowID: 1),
            "a_b.png")
    }

    func testUnknownMIMEFallsBackToBin() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: nil, kind: "document", mime: "x-widget/nothing", rowID: 3),
            "Document-3.bin")
    }
}
