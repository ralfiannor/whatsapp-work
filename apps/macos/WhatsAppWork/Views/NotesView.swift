// Local notes (NotesStore): the pinned chat-list row, and the detail pane
// with the note list beside a Markdown editor / preview.
import AppKit
import SwiftUI

/// First row of the chat list, above every chat in every filter. Not a chat:
/// its tag never reaches selectedChat or the core.
struct NotesChatListRow: View {
    @ObservedObject var notes: NotesStore

    var body: some View {
        let latest = notes.notes.first
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(.yellow)
                Text("Notes")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                if !notes.notes.isEmpty {
                    Text("\(notes.notes.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(latest.map { NoteMarkdown.title(of: $0.body) } ?? "Private, stays on this Mac")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(ChatRow.timeString(Int64(latest?.updatedAt.timeIntervalSince1970 ?? 0)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Notes, \(notes.notes.count) local notes")
    }
}

struct NotesView: View {
    @ObservedObject var notes: NotesStore
    @AppStorage("notesPreview") private var preview = false
    @State private var query = ""
    @State private var pendingDelete: Note?

    var body: some View {
        HSplitView {
            noteList
                .frame(minWidth: 200, idealWidth: 240, maxWidth: 360)
            detail
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("Delete this note?", isPresented: deleteDialogShown,
                            presenting: pendingDelete) { note in
            Button("Delete", role: .destructive) { notes.delete(note.id) }
            Button("Cancel", role: .cancel) {}
        } message: { note in
            Text("“\(NoteMarkdown.title(of: note.body))” is removed from this Mac. This can't be undone.")
        }
        // A blank note (New Note button or ⌥⌘N) opens ready to type, even
        // from Preview or under a search that would hide it.
        .onChange(of: notes.selectedID, initial: true) { _, id in
            guard let id, let note = notes.note(id), NotesStore.isBlank(note.body) else { return }
            preview = false
            query = ""
        }
    }

    private var filtered: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return notes.notes }
        return notes.notes.filter { $0.body.localizedCaseInsensitiveContains(q) }
    }

    private var noteList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search notes", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button(action: newNote) {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New note (⌥⌘N)")
                .accessibilityLabel("New note")
            }
            .padding(8)
            Divider()
            List(selection: $notes.selectedID) {
                ForEach(filtered) { note in
                    NoteListRow(note: note)
                        .tag(note.id)
                        .contextMenu {
                            Button("Delete Note", role: .destructive) { requestDelete(note) }
                        }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filtered.isEmpty {
                    Text(notes.notes.isEmpty ? "No notes" : "No matches")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = notes.selectedID, let note = notes.note(id) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        preview.toggle()
                    } label: {
                        Label(preview ? "Edit" : "Preview", systemImage: preview ? "pencil" : "eye")
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .help(preview ? "Edit Markdown (⇧⌘P)" : "Preview Markdown (⇧⌘P)")
                    Button {
                        requestDelete(note)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("Delete note")
                    .accessibilityLabel("Delete note")
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                if preview {
                    ScrollView {
                        NoteMarkdownView(blocks: NoteMarkdown.blocks(note.body)) { line in
                            notes.toggleTask(line: line, in: id)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    NoteEditor(text: Binding(
                        get: { notes.note(id)?.body ?? "" },
                        set: { notes.setBody($0, for: id) }
                    ), focusOnAppear: NotesStore.isBlank(note.body))
                    // Fresh text view per note: its own undo stack and caret.
                    .id(id)
                }
                problemBar
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(notes.notes.isEmpty ? "No notes yet" : "Select a note")
                    .font(.title3.bold())
                Text("Notes support Markdown and are stored only on this Mac.\nNothing is sent to WhatsApp.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("New Note", action: newNote)
                problemBar
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var problemBar: some View {
        if let problem = notes.saveProblem ?? notes.loadProblem {
            Text(problem)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.bar)
        }
    }

    private var deleteDialogShown: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    private func newNote() {
        notes.create()
    }

    /// Blank notes go without asking; anything with text is confirmed.
    private func requestDelete(_ note: Note) {
        if NotesStore.isBlank(note.body) {
            notes.delete(note.id)
        } else {
            pendingDelete = note
        }
    }
}

/// Equatable like ChatRow: a keystroke re-renders only the edited note's row.
struct NoteListRow: View, Equatable {
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(NoteMarkdown.title(of: note.body))
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(ChatRow.timeString(Int64(note.updatedAt.timeIntervalSince1970)))
                Text(NoteMarkdown.preview(of: note.body))
                    .lineLimit(1)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Markdown source editor: ONE NSTextView (the per-row ban is about the
/// transcript). SwiftUI's TextEditor follows the system's smart-dash
/// setting, which turns "---" and "|---|" into em dashes mid-typing.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var focusOnAppear: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NoteTextView()
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        if focusOnAppear {
            DispatchQueue.main.async { tv.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView, tv.string != text else { return }
        tv.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteEditor
        /// Per-note undo: the window's shared manager would let ⌘Z replay
        /// another note's edits into this one.
        private let undo = UndoManager()

        init(_ parent: NoteEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }
}

/// The app replaces the Edit menu's pasteboard group (custom ⌘V routing),
/// which drops Select All — handle ⌘A here, as ComposerTextView does.
final class NoteTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if window?.firstResponder == self, mods == .command,
           event.charactersIgnoringModifiers == "a" {
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Rendered note. Plain SwiftUI Text per block (no AppKit views); task
/// checkboxes write back through `onToggleTask(sourceLine)`.
struct NoteMarkdownView: View {
    let blocks: [NoteMarkdown.Block]
    let onToggleTask: (Int) -> Void

    private static let bodySize: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: NoteMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.styled(text))
                .font(.system(size: Self.headingSize(level), weight: .bold, design: .monospaced))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            Text(Self.styled(text)).font(Self.bodyFont)
        case .listItem(let depth, let marker, let text, let line):
            listItem(depth: depth, marker: marker, text: text, line: line)
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 3)
                Text(Self.styled(text))
                    .font(Self.bodyFont)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let header, let rows):
            table(header: header, rows: rows)
        }
    }

    private func listItem(depth: Int, marker: NoteMarkdown.ListMarker, text: String, line: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch marker {
            case .bullet:
                Text(depth.isMultiple(of: 2) ? "•" : "◦").font(Self.bodyFont).foregroundStyle(.secondary)
            case .ordered(let number):
                Text(number).font(Self.bodyFont).foregroundStyle(.secondary)
            case .task(let done):
                Button {
                    onToggleTask(line)
                } label: {
                    Image(systemName: done ? "checkmark.square.fill" : "square")
                        .foregroundStyle(done ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(done ? "Completed" : "Not completed")
                .accessibilityHint("Toggles this checklist item")
            }
            Text(Self.styled(text))
                .font(Self.bodyFont)
                .strikethrough(marker == .task(done: true))
                .foregroundStyle(marker == .task(done: true) ? .secondary : .primary)
        }
        .padding(.leading, CGFloat(depth) * 18)
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                    Text(Self.styled(cell)).font(Self.bodyFont.bold())
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(Self.styled(cell)).font(Self.bodyFont)
                    }
                }
            }
        }
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private static let bodyFont = Font.system(size: bodySize, design: .monospaced)

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 20
        case 2: 17
        case 3: 15
        default: bodySize
        }
    }

    /// Inline Markdown, with code spans tinted: the body is already
    /// monospaced, so `code` would otherwise look like plain text.
    private static func styled(_ text: String) -> AttributedString {
        var out = NoteMarkdown.inline(text)
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].backgroundColor = Color.white.opacity(0.1)
            out[run.range].foregroundColor = Color(red: 0.95, green: 0.6, blue: 0.5)
        }
        return out
    }
}
