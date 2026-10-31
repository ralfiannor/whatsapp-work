import XCTest
@testable import WhatsAppWork

final class NoteMarkdownTests: XCTestCase {
    func testBlocksCoverHeadingsListsQuotesCodeRulesAndTables() {
        let source = """
        # Plan
        Call the supplier
        email the invoice

        - one
          - nested
        1. first
        - [ ] open task
        - [x] done task
        > quoted
        ---
        ```
        let x = 1
        ```
        | a | b |
        |---|:-:|
        | 1 | 2 |
        """
        XCTAssertEqual(NoteMarkdown.blocks(source), [
            .heading(level: 1, text: "Plan"),
            // A single newline stays a line break.
            .paragraph("Call the supplier\nemail the invoice"),
            .listItem(depth: 0, marker: .bullet, text: "one", line: 4),
            .listItem(depth: 1, marker: .bullet, text: "nested", line: 5),
            .listItem(depth: 0, marker: .ordered("1."), text: "first", line: 6),
            .listItem(depth: 0, marker: .task(done: false), text: "open task", line: 7),
            .listItem(depth: 0, marker: .task(done: true), text: "done task", line: 8),
            .quote("quoted"),
            .rule,
            .code("let x = 1"),
            .table(header: ["a", "b"], rows: [["1", "2"]]),
        ])
    }

    func testHashtagAndBulletRuleAreNotHeadingOrList() {
        XCTAssertEqual(NoteMarkdown.blocks("#tag\n- - -"), [.paragraph("#tag"), .rule])
    }

    func testFourSpaceNestingMapsToDepthOne() {
        XCTAssertEqual(NoteMarkdown.blocks("- a\n    - b\n- c"), [
            .listItem(depth: 0, marker: .bullet, text: "a", line: 0),
            .listItem(depth: 1, marker: .bullet, text: "b", line: 1),
            .listItem(depth: 0, marker: .bullet, text: "c", line: 2),
        ])
    }

    func testTogglingTaskFlipsOnlyThatLine() {
        let source = "intro [ ]\n- [ ] a\n- [x] b"
        XCTAssertEqual(NoteMarkdown.togglingTask(in: source, line: 1), "intro [ ]\n- [x] a\n- [x] b")
        XCTAssertEqual(NoteMarkdown.togglingTask(in: source, line: 2), "intro [ ]\n- [ ] a\n- [ ] b")
        XCTAssertNil(NoteMarkdown.togglingTask(in: source, line: 0))
        XCTAssertNil(NoteMarkdown.togglingTask(in: source, line: 9))
    }

    func testTitleAndPreviewStripMarkdown() {
        let body = "\n## **Weekly** sync\n\n- [ ] send `report`\n"
        XCTAssertEqual(NoteMarkdown.title(of: body), "Weekly sync")
        XCTAssertEqual(NoteMarkdown.preview(of: body), "send report")
        XCTAssertEqual(NoteMarkdown.title(of: "  \n"), "New Note")
        XCTAssertEqual(NoteMarkdown.preview(of: "only title"), "")
    }
}

@MainActor
final class NotesStoreTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var fileURL: URL { dir.appendingPathComponent("Notes/notes.json") }

    func testEditsPersistMostRecentFirstWithPrivatePermissions() throws {
        let store = NotesStore(fileURL: fileURL, saveDelay: .seconds(60))
        let first = store.create()
        store.setBody("first", for: first)
        let second = store.create()
        store.setBody("second", for: second)
        store.setBody("first, edited", for: first)
        store.flush()

        let reloaded = NotesStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.notes.map(\.body), ["first, edited", "second"])
        XCTAssertEqual(reloaded.selectedID, first)
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: fileURL.deletingLastPathComponent().path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testLeavingABlankNoteDiscardsIt() {
        let store = NotesStore(fileURL: fileURL, saveDelay: .seconds(60))
        let kept = store.create()
        store.setBody("kept", for: kept)
        _ = store.create()
        _ = store.create() // leaves the previous blank note
        XCTAssertEqual(store.notes.count, 2)
        store.selectedID = kept
        XCTAssertEqual(store.notes.map(\.body), ["kept"])
    }

    func testDeleteSelectsNeighbourAndPersists() {
        let store = NotesStore(fileURL: fileURL, saveDelay: .seconds(60))
        let a = store.create()
        store.setBody("a", for: a)
        let b = store.create()
        store.setBody("b", for: b)
        store.delete(b)
        XCTAssertEqual(store.selectedID, a)
        store.flush()
        XCTAssertEqual(NotesStore(fileURL: fileURL).notes.map(\.body), ["a"])
    }

    func testToggleTaskRewritesSource() {
        let store = NotesStore(fileURL: fileURL, saveDelay: .seconds(60))
        let id = store.create()
        store.setBody("- [ ] call", for: id)
        store.toggleTask(line: 0, in: id)
        XCTAssertEqual(store.note(id)?.body, "- [x] call")
    }

    func testUnreadableFileIsMovedAsideNotOverwritten() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)

        let store = NotesStore(fileURL: fileURL, saveDelay: .seconds(60))
        XCTAssertTrue(store.notes.isEmpty)
        XCTAssertNotNil(store.loadProblem)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        let aside = try XCTUnwrap(siblings.first { $0.hasPrefix("notes-unreadable-") })
        XCTAssertEqual(try Data(contentsOf: fileURL.deletingLastPathComponent().appendingPathComponent(aside)),
                       Data("not json".utf8))
    }
}

@MainActor
final class AppStateNotesTests: XCTestCase {
    func testNotesAndChatSelectionAreMutuallyExclusive() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStateNotesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let state = AppState(notes: NotesStore(fileURL: dir.appendingPathComponent("notes.json")))
        state.sidebarTab = .inbox
        state.selectedChat = "254700000001@s.whatsapp.net"

        state.openNotes()
        XCTAssertTrue(state.notesOpen)
        XCTAssertNil(state.selectedChat)
        XCTAssertEqual(state.sidebarTab, .chats)

        state.selectedChat = "6285000000001@s.whatsapp.net"
        XCTAssertFalse(state.notesOpen)
    }
}
