// Local-only notes. One JSON file in the app's Application Support folder,
// read and written by the app alone: the Go core never sees it, so nothing
// here can reach WhatsApp. Keep it that way — no IPC endpoint, no sync, no
// logging of note text. Logout wipes the core's account data, not notes.
import Foundation

struct Note: Codable, Identifiable, Equatable {
    let id: UUID
    var body: String
    let createdAt: Date
    var updatedAt: Date
}

/// Its own ObservableObject (like UpdateManager) so editor keystrokes
/// re-render the notes pane, not every AppState observer.
@MainActor
final class NotesStore: ObservableObject {
    /// Most recently edited first (Notes.app order).
    @Published private(set) var notes: [Note] = []
    /// Moving off a note that was left blank discards it, like Notes.app —
    /// repeated "New Note" clicks must not pile up empty rows.
    @Published var selectedID: Note.ID? {
        didSet {
            guard let oldValue, oldValue != selectedID,
                  let index = notes.firstIndex(where: { $0.id == oldValue }),
                  Self.isBlank(notes[index].body) else { return }
            notes.remove(at: index)
            scheduleSave()
        }
    }
    @Published private(set) var loadProblem: String?
    @Published private(set) var saveProblem: String?

    nonisolated static let defaultFileURL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("WhatsAppWork/Notes/notes.json")

    private struct NotesFile: Codable {
        var version = 1
        var notes: [Note]
    }

    private let fileURL: URL
    private let saveDelay: Duration
    private var saveTask: Task<Void, Never>?
    private var dirty = false
    /// False when an existing file could not be read or moved aside:
    /// saving would replace notes we failed to load.
    private var writable = true
    /// Serial: a later snapshot can never land before an earlier one.
    private let writeQueue = DispatchQueue(label: "dev.whatsappwork.notes.write", qos: .utility)

    init(fileURL: URL = NotesStore.defaultFileURL, saveDelay: Duration = .milliseconds(500)) {
        self.fileURL = fileURL
        self.saveDelay = saveDelay
        load()
        selectedID = notes.first?.id
    }

    func note(_ id: Note.ID) -> Note? {
        notes.first { $0.id == id }
    }

    @discardableResult
    func create() -> Note.ID {
        let now = Date()
        let note = Note(id: UUID(), body: "", createdAt: now, updatedAt: now)
        notes.insert(note, at: 0)
        selectedID = note.id
        return note.id
    }

    func setBody(_ body: String, for id: Note.ID) {
        guard let index = notes.firstIndex(where: { $0.id == id }),
              notes[index].body != body else { return }
        var list = notes
        var note = list.remove(at: index)
        note.body = body
        note.updatedAt = Date()
        list.insert(note, at: 0)
        notes = list
        scheduleSave()
    }

    func toggleTask(line: Int, in id: Note.ID) {
        guard let body = note(id)?.body,
              let toggled = NoteMarkdown.togglingTask(in: body, line: line) else { return }
        setBody(toggled, for: id)
    }

    /// Deleting the selected note selects its neighbour in list order.
    func delete(_ id: Note.ID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes.remove(at: index)
        if selectedID == id {
            selectedID = notes.isEmpty ? nil : notes[min(index, notes.count - 1)].id
        }
        scheduleSave()
    }

    /// Writes pending edits now and waits for the disk. App quit calls this;
    /// otherwise saves are debounced while typing.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
        save()
        writeQueue.sync {}
    }

    static func isBlank(_ body: String) -> Bool {
        body.allSatisfy(\.isWhitespace)
    }

    // MARK: - persistence

    private func load() {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return // first launch
        } catch {
            writable = false
            loadProblem = "Notes could not be read (\(error.localizedDescription)). Changes won't be saved."
            return
        }
        do {
            notes = try JSONDecoder().decode(NotesFile.self, from: data).notes
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            // Keep the unreadable file for recovery instead of overwriting it.
            let aside = fileURL.deletingLastPathComponent()
                .appendingPathComponent("notes-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.moveItem(at: fileURL, to: aside)
                loadProblem = "The notes file was unreadable and was moved to \(aside.lastPathComponent)."
            } catch {
                writable = false
                loadProblem = "The notes file is unreadable. Changes won't be saved."
            }
        }
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard dirty, writable else { return }
        dirty = false
        let data: Data
        do {
            data = try JSONEncoder().encode(NotesFile(notes: notes))
        } catch {
            saveProblem = "Notes could not be saved (\(error.localizedDescription))."
            return
        }
        let url = fileURL
        writeQueue.async { [weak self] in
            let problem: String?
            do {
                let fm = FileManager.default
                // Same posture as the core's data: folder 0700, file 0600.
                try fm.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try data.write(to: url, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                problem = nil
            } catch {
                problem = "Notes could not be saved (\(error.localizedDescription))."
            }
            Task { @MainActor in
                guard let self else { return }
                self.saveProblem = problem
                // Re-arm so the next edit or quit retries the whole snapshot.
                if problem != nil { self.dirty = true }
            }
        }
    }
}
