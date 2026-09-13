// ⌘K global search overlay: FTS messages + chats + contacts over local DB.
import SwiftUI

struct SearchOverlay: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var results: SearchResponse?
    @State private var searching = false
    /// Keyboard highlight into the flat results list (↓/↑/Enter).
    @State private var selection: Int?
    @FocusState private var focused: Bool

    /// Display-order rows: chats, contacts, messages (matches the sections).
    enum SearchRow {
        case chat(Chat)
        case contact(Contact)
        case hit(SearchResponse.Hit)
    }

    private var flatRows: [SearchRow] {
        guard let res = results else { return [] }
        return res.chats.map { .chat($0) }
            + res.contacts.map { .contact($0) }
            + res.messages.map { .hit($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            Divider()
            resultList
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 18)
        .padding(60)
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onAppear { focused = true }
        .onChange(of: query) { _, q in
            selection = nil
            Task {
                // Local FTS answers in ~10 ms; 250 ms of debounce only added
                // perceived lag. Still long enough to swallow fast typing.
                try? await Task.sleep(for: .milliseconds(120))
                guard query == q else { return } // debounce
                await search()
            }
        }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let rows = flatRows
        guard !rows.isEmpty else { return .ignored }
        let next = min(max((selection ?? -1) + delta, 0), rows.count - 1)
        selection = next
        return .handled
    }

    private func open(_ row: SearchRow) {
        switch row {
        case .chat(let c):
            Task { await state.jump(toChat: c.jid) }
        case .contact(let c):
            Task { await state.jump(toChat: c.jid) }
        case .hit(let hit):
            // Deep-link: open the chat scrolled to the hit itself.
            // An empty message_id must not send the pager hunting.
            let anchor = hit.message_id.flatMap { $0.isEmpty ? nil : $0 }
            Task { await state.jump(toChat: hit.chat_jid, anchorMessageID: anchor) }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search messages, chats, contacts…", text: $query)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit {
                    // Enter opens the highlighted result; empty selection
                    // just runs the search (Enter-as-search preserved).
                    if let idx = selection, flatRows.indices.contains(idx) {
                        open(flatRows[idx])
                    } else {
                        Task { await search() }
                    }
                }
            if searching { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    @ViewBuilder
    private var resultList: some View {
        ScrollView {
            if let res = results {
                if isEmpty(res) {
                    Text("No results").foregroundStyle(.secondary).padding(.vertical, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(flatRows.enumerated()), id: \.offset) { idx, row in
                            if idx == 0 || sectionName(flatRows[idx - 1]) != sectionName(row) {
                                header(sectionName(row))
                            }
                            rowContent(row)
                                .background(selection == idx
                                            ? Color.accentColor.opacity(0.18)
                                            : Color.clear)
                                .contentShape(Rectangle())
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: 420)
    }

    private func sectionName(_ row: SearchRow) -> String {
        switch row {
        case .chat: "Chats"
        case .contact: "Contacts"
        case .hit: "Messages"
        }
    }

    @ViewBuilder
    private func rowContent(_ row: SearchRow) -> some View {
        switch row {
        case .chat(let c):
            plainRow(text: c.display_name.isEmpty ? c.jid : c.display_name,
                     subtitle: nil, icon: "bubble.left.and.bubble.right") {
                open(row)
            }
        case .contact(let c):
            plainRow(text: c.full_name ?? c.push_name ?? c.jid,
                     subtitle: nil, icon: "person") {
                open(row)
            }
        case .hit(let hit):
            hitRow(hit) {
                open(row)
            }
        }
    }

    private func isEmpty(_ r: SearchResponse) -> Bool {
        r.messages.isEmpty && r.chats.isEmpty && r.contacts.isEmpty
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.bold())
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private func plainRow(text: String, subtitle: String?, icon: String,
                          action: @escaping () -> Void) -> some View {
        row(label: Text(text).lineLimit(1), subtitle: subtitle, icon: icon, action: action)
    }

    private func hitRow(_ hit: SearchResponse.Hit, action: @escaping () -> Void) -> some View {
        let attributed = (try? AttributedString(markdown: hit.snippet
            .replacingOccurrences(of: "⟪", with: "**")
            .replacingOccurrences(of: "⟫", with: "**")))
            ?? AttributedString(hit.snippet)
        return row(label: Text(attributed).lineLimit(2),
                   subtitle: hitSubtitle(hit), icon: "text.bubble", action: action)
    }

    /// "10:36 · Backend Team" — a hit without its when/where is half a result.
    private func hitSubtitle(_ hit: SearchResponse.Hit) -> String {
        let time = ChatRow.timeString(hit.timestamp)
        let chat = chatName(hit.chat_jid)
        return time.isEmpty ? chat : "\(time) · \(chat)"
    }

    private func row(label: any View, subtitle: String?, icon: String,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    AnyView(label)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        searching = true
        let res = await state.runSearch(q)
        // A slower stale response (Enter racing the debounce) must not
        // overwrite results for a newer query.
        if query.trimmingCharacters(in: .whitespaces) == q {
            results = res
        }
        searching = false
    }

    private func chatName(_ jid: String) -> String {
        state.chats.first(where: { $0.jid == jid })?.display_name ?? jid
    }
}
