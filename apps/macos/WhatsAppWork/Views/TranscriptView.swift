// Transcript: paginated history + composer. Loads older pages on scroll-top.
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptView: View {
    let chatJID: String
    @EnvironmentObject var state: AppState

    @State private var nickColWidth: CGFloat = 90
    /// mIRC-style nick panel visibility (groups only), persisted.
    @AppStorage("showMemberPanel") var showMemberPanel = true
    /// Transcript typography (persisted): body size + vertical density.
    /// Passed DOWN as plain values so the MessageList Equatable wall sees
    /// changes — @AppStorage inside the wall would bypass `==`.
    @AppStorage("transcriptFontSize") var fontSize: Double = 12.5
    @AppStorage("transcriptDensity") var density: String = "compact"

    /// Density presets: only spacing metrics — same layout, no architecture
    /// switch (§36). Compact stays the default: this is an IRC client.
    private var rowPadding: CGFloat {
        switch density {
        case "comfortable": return 3
        case "spacious": return 6
        default: return 0.5
        }
    }

    private var isGroup: Bool { chatJID.hasSuffix("@g.us") }

    private var messages: [Message] { state.messagesByChat[chatJID] ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                MessageList(chatJID: chatJID, messages: messages, nickColumn: nickColWidth,
                            unreadBoundary: state.unreadBoundaries[chatJID],
                            fontSize: fontSize, rowPadding: rowPadding,
                            pageRenderVersion: state.selectedMessagePageRenderVersion)
                Divider()
                ComposerBar(chatJID: chatJID)
            }
            if isGroup && showMemberPanel {
                Divider()
                MemberPanel(chatJID: chatJID)
                    .frame(width: 180)
            }
        }
        // Appearance lives at RootView (app-wide dark); no per-view override.
        .background(Color(white: 0.07))
        .sheet(isPresented: previewBinding) { ImagePreviewSheet() }
        // Delete confirmation lives OUTSIDE the MessageList Equatable wall:
        // inside it, deleteTarget changes either skip the list body (alert
        // never presents) or force the wall to watch all of AppState.
        .alert("Delete for everyone?", isPresented: Binding(
            get: { state.deleteTarget != nil },
            set: { if !$0 { state.deleteTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let m = state.deleteTarget { Task { await state.deleteMessage(m) } }
                state.deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { state.deleteTarget = nil }
        } message: {
            Text("The message will be removed for everyone in this chat.")
        }
        .onAppear { recomputeNickColumn() }
        .onChange(of: messages.count) { _, _ in recomputeNickColumn() }
        .onChange(of: state.contactNames) { _, _ in
            // Names landed after connect: nick text changes (and may get
            // longer than the JID-sized column) — recompute width. This also
            // re-evaluates row bodies, picking up the new labels/colors.
            recomputeNickColumn()
        }
        .onChange(of: state.profileRequest) { _, req in
            // Nick tap with the panel hidden: open the panel, not nothing.
            if req != nil { showMemberPanel = true }
        }
    }

    /// Nick width only changes when the page set changes — never per keystroke.
    private func recomputeNickColumn() {
        let maxLen = messages.map { state.ircNick(for: $0).count }.max() ?? 6
        let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let charW = ("M" as NSString).size(withAttributes: [.font: f]).width
        nickColWidth = charW * CGFloat(max(9, min(18, maxLen)))
    }

    /// Header typography menu: size steps and density presets, both
    /// persisted via @AppStorage.
    private var typographyMenu: some View {
        Menu {
            Button("Bigger Text") { fontSize = min(16, fontSize + 0.5) }
                .disabled(fontSize >= 16)
            Button("Smaller Text") { fontSize = max(11, fontSize - 0.5) }
                .disabled(fontSize <= 11)
            Divider()
            Picker("Density", selection: $density) {
                Text("Compact").tag("compact")
                Text("Comfortable").tag("comfortable")
                Text("Spacious").tag("spacious")
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "textformat.size")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Transcript text size and density")
    }

    private var previewBinding: Binding<Bool> {
        Binding(get: { state.previewImage != nil },
                set: { if !$0 { state.previewImage = nil } })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(chatJID.hasSuffix("@g.us") ? "#" : "@")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(headerName)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            if isGroup {
                Text("\(state.chatMembers[chatJID]?.count ?? 0)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                // Raw group identifier: small and tertiary, but selectable so
                // it can be copied (select + ⌘C) for sharing/invites.
                Text(chatJID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("Group identifier — select and press ⌘C to copy")
            } else {
                // Direct chat: BOTH identity forms next to the name, header
                // only (same treatment as groups). The @lid twin appears
                // once the lid map knows it; selectable for copy.
                Text(chatJID)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let lid = state.lid(forChat: chatJID), lid != chatJID {
                    Text("· \(lid)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            typographyMenu
            if isGroup {
                Button {
                    showMemberPanel.toggle()
                } label: {
                    Image(systemName: showMemberPanel ? "person.2.fill" : "person.2")
                        .foregroundStyle(showMemberPanel ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(showMemberPanel ? "Hide members" : "Show members")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var headerName: String {
        guard let chat = state.chats.first(where: { $0.jid == chatJID }) else {
            return AppState.prettyJID(chatJID)
        }
        return chat.display_name.isEmpty ? AppState.prettyJID(chat.jid) : chat.display_name
    }

}

/// Equatable list wrapper: skips re-diffing 200 rows when nothing relevant
/// changed (receipt storms, media decodes, inbox polls re-render the parent —
/// this wall keeps typing and scrolling smooth on old Intel).
private struct MessageList: View, Equatable {
    let chatJID: String
    let messages: [Message]
    let nickColumn: CGFloat
    // Passed as a value (not read from state here): this struct is Equatable,
    // and environment reads inside body would bypass the == wall.
    var unreadBoundary: UnreadBoundary?
    var fontSize: Double
    var rowPadding: CGFloat
    var pageRenderVersion: UInt64

    @EnvironmentObject private var state: AppState
    @State private var loadingOlder = false
    @State private var atBottom = true
    @State private var jumping = false
    @State private var flashID: Int64?
    /// Increments on every flash; the expiry task only clears the flash if
    /// no newer flash (re-click on the same quote) superseded it.
    @State private var flashGeneration = 0
    /// Keyboard row selection (List selection; arrow keys move it when the
    /// list has focus). D/S/R/E act on it.
    @State private var selectedRowID: Int64?
    @State private var snoozeFor: Int64?
    @State private var reactFor: Int64?
    @FocusState private var listFocused: Bool

    static func == (lhs: MessageList, rhs: MessageList) -> Bool {
        lhs.chatJID == rhs.chatJID && lhs.nickColumn == rhs.nickColumn
            && lhs.messages == rhs.messages && lhs.unreadBoundary == rhs.unreadBoundary
            && lhs.fontSize == rhs.fontSize && lhs.rowPadding == rhs.rowPadding
            && lhs.pageRenderVersion == rhs.pageRenderVersion
    }

    /// "HH:mm" — seconds carried no scanning value and cost column width.
    private var timeColumnWidth: CGFloat {
        let f = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return ("M" as NSString).size(withAttributes: [.font: f]).width * 5
    }

    private var unreadMarker: UnreadMarkerPresentation? {
        UnreadMarkerPresenter.presentation(
            for: unreadBoundary,
            loadedMessageCount: messages.count
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selectedRowID) {
                Group {
                    if loadingOlder { ProgressView().frame(maxWidth: .infinity) }
                    if case let .some(.boundedTop(label, actionTitle)) = unreadMarker {
                        BoundedUnreadDivider(label: label, actionTitle: actionTitle) {
                            Task { await loadOlderAnchored(proxy) }
                        }
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.id) { idx, m in
                        VStack(spacing: 0) {
                            if idx == 0 || !Self.sameDay(messages[idx - 1].timestamp, m.timestamp) {
                                DateDivider(timestamp: m.timestamp)
                            }
                            if case let .some(.row(rowID, count)) = unreadMarker,
                               rowID == m.id {
                                UnreadDivider(count: count) {
                                    withAnimation(.easeOut(duration: 0.25)) {
                                        proxy.scrollTo("bottom", anchor: .bottom)
                                    }
                                }
                            }
                            MessageBubble(message: m, highlighted: m.id == flashID,
                                          timeColumn: timeColumnWidth, nickColumn: nickColumn,
                                          fontSize: fontSize, rowPadding: rowPadding,
                                          onJumpQuote: { id in jumpToMessage(id, proxy: proxy) })
                        }
                        .tag(m.id)
                        .id(m.id)
                    }
                    // Bottom sentinel: visible == user is at the latest
                    // messages; drives auto-scroll and the jump button.
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
            }
            .listStyle(.plain)
            // Older-message paging trigger: the List's clip-view offset, not
            // a sentinel row's onAppear (which never fires on macOS).
            .background(
                TopPagingMonitor {
                    Task { await automaticTopPaging(proxy) }
                }
            )
            .focused($listFocused)
            .simultaneousGesture(TapGesture().onEnded {
                Task { await state.commitRead(chatJID, source: .transcriptFocus) }
            })
            .defaultScrollAnchor(.bottom)
            .onKeyPress("d") { actOnSelection { await state.markDone($0) } }
            .onKeyPress("s") { if selectedRowID != nil { snoozeFor = selectedRowID; reactFor = nil }
                return selectedRowID != nil ? .handled : .ignored }
            .onKeyPress("e") { if selectedRowID != nil { reactFor = selectedRowID; snoozeFor = nil }
                return selectedRowID != nil ? .handled : .ignored }
            .onKeyPress("r") { replyToSelection() }
            .onKeyPress(.escape) {
                guard selectedRowID != nil || snoozeFor != nil || reactFor != nil else { return .ignored }
                selectedRowID = nil
                snoozeFor = nil
                reactFor = nil
                return .handled
            }
            .overlay(alignment: .bottom) {
                if !atBottom && !messages.isEmpty {
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                            .background(Circle().fill(.regularMaterial))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .help("Jump to latest")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let id = snoozeFor {
                    SnoozePanel(rowID: id) { snoozeFor = nil }
                        .padding(12)
                } else if let id = reactFor {
                    ReactionPanel(rowID: id) { reactFor = nil }
                        .padding(12)
                }
            }
            // New message while reading at the bottom: snap (no animation —
            // a busy group must not make the transcript swim).
            .onChange(of: messages.last?.id) { _, _ in
                if atBottom {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .onAppear {
                resolvePendingAnchor(proxy)
                finishSelectedPageAtViewUpdateProxy()
            }
            .onChange(of: messages.count) { _, _ in resolvePendingAnchor(proxy) }
            .onChange(of: pageRenderVersion) { _, _ in
                finishSelectedPageAtViewUpdateProxy()
            }
            .onChange(of: listFocused) { _, focused in
                guard focused else { return }
                Task { await state.commitRead(chatJID, source: .transcriptFocus) }
            }
            .onChange(of: chatJID) { _, _ in
                // Rowids are globally unique, but a leftover selection would
                // still scroll-highlight a random row — clear it.
                selectedRowID = nil
                snoozeFor = nil
                reactFor = nil
            }
        }
    }

    /// Correlation marker after the fetched generation reaches MessageList.
    /// Instruments remains authoritative for presented-frame latency.
    private func finishSelectedPageAtViewUpdateProxy() {
        let version = pageRenderVersion
        DispatchQueue.main.async {
            state.selectedMessagePageDidReachViewUpdateProxy(
                chatJID: chatJID,
                renderVersion: version
            )
        }
    }

    /// Keyboard action on the selected row; closure receives the message.
    private func actOnSelection(_ action: @escaping (Message) async -> Void) -> KeyPress.Result {
        guard let id = selectedRowID,
              let m = messages.first(where: { $0.id == id }) else { return .ignored }
        Task { await action(m) }
        return .handled
    }

    private func replyToSelection() -> KeyPress.Result {
        guard let id = selectedRowID,
              let m = messages.first(where: { $0.id == id }) else { return .ignored }
        state.setReply(m, for: m.chat_jid)
        state.composerFocusRequest += 1
        return .handled
    }

    private static func sameDay(_ a: Int64, _ b: Int64) -> Bool {
        Calendar.current.isDate(Date(timeIntervalSince1970: TimeInterval(a)),
                                inSameDayAs: Date(timeIntervalSince1970: TimeInterval(b)))
    }

    /// Flashes a row for the quote-jump / anchor jump: the reader must be
    /// able to tell WHICH message was being replied to. Re-jumps restart the
    /// window (generation guard) instead of letting the first expiry cut a
    /// fresh flash short.
    private func flash(_ id: Int64) {
        flashID = id
        flashGeneration += 1
        let gen = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            guard gen == flashGeneration else { return }
            flashID = nil
        }
    }

    /// Quote-tap jump: scroll to the quoted message; if it predates the
    /// loaded pages, page history in until it appears (anchor mechanism).
    private func jumpToMessage(_ messageID: String, proxy: ScrollViewProxy) {
        guard !messageID.isEmpty else { return }
        guard let m = messages.first(where: { $0.message_id == messageID }) else {
            state.pendingAnchor = .init(chatJID: chatJID, messageID: messageID)
            resolvePendingAnchor(proxy)
            return
        }
        flash(m.id)
        jumping = true
        // scrollTo from inside a gesture handler needs the next runloop
        // pass — called synchronously the List ignores it.
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(m.id, anchor: .center)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            jumping = false // top region may now be visible; resume paging
        }
    }

    /// Scrolls to the message an inbox row / quote / search hit pointed at;
    /// pages older history in until it appears, then flashes the row. When
    /// the history genuinely ends without it, says so instead of doing
    /// nothing.
    private func resolvePendingAnchor(_ proxy: ScrollViewProxy) {
        // Anchors from other chats are not ours to resolve (user switched
        // before it landed) — leave them untouched.
        guard let anchor = state.pendingAnchor, anchor.chatJID == chatJID else { return }
        guard let m = messages.first(where: { $0.message_id == anchor.messageID }) else {
            let before = messages.count
            Task {
                await loadOlder()
                if messages.count == before, state.pendingAnchor == anchor {
                    // loadOlder made no progress: end of history, target absent.
                    state.pendingAnchor = nil
                    state.toast = "Message is older than the loaded history — try ⌘K search"
                }
            }
            return
        }
        state.pendingAnchor = nil
        flash(m.id)
        DispatchQueue.main.async {
            proxy.scrollTo(m.id, anchor: .center)
        }
    }

    private func loadOlder() async {
        // A short first page means the whole history is already loaded.
        guard !loadingOlder, messages.count >= 50 else { return }
        loadingOlder = true
        await state.loadOlderMessages(for: chatJID)
        loadingOlder = false
    }

    /// Scroll-driven paging entry: one shared decision for every automatic
    /// trigger. The visible Load Earlier divider stays for explicit paging
    /// and as the unread-count affordance.
    private func automaticTopPaging(_ proxy: ScrollViewProxy) async {
        guard AutomaticTopPagingDecision.shouldLoad(
            jumping: jumping,
            loadingOlder: loadingOlder,
            messageCount: messages.count
        ) else { return }
        await loadOlderAnchored(proxy)
    }

    /// Paging for manual scroll-up. After a successful prepend the
    /// TopPagingMonitor probe shifts the clip view to the equivalent offset
    /// (the row the reader was on stays visually fixed), leaving offset room
    /// for the next reach-top to fire — `proxy.scrollTo` here was unreliable
    /// (silently dropped) and left the offset pinned at the top.
    private func loadOlderAnchored(_ proxy: ScrollViewProxy) async {
        let before = messages.count
        await loadOlder()
        let after = state.messagesByChat[chatJID]?.count ?? before
        guard after > before else { return }
        resolvePendingAnchor(proxy)
    }
}

/// Centered typographic day marker — the only separator between days.
struct DateDivider: View {
    let timestamp: Int64

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    private var label: String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return Self.dayFormatter.string(from: date)
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// "── N unread ──" boundary above the first unread incoming message.
/// Click scrolls to the latest (the usual "caught up" action).
struct UnreadDivider: View {
    let count: Int
    var onCatchUp: () -> Void = {}

    var body: some View {
        Button(action: onCatchUp) {
            HStack(spacing: 8) {
                Rectangle().fill(Color.accentColor.opacity(0.45)).frame(height: 1)
                Text("\(count) unread")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Color.accentColor.opacity(0.45)).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 3)
        .help("Jump to latest")
        .accessibilityLabel("\(count) unread messages")
    }
}

/// Honest marker for a captured unread count whose first row is older than
/// the bounded transcript window. Its action requests one older page; the
/// boundary is recomputed after that merge and remains bounded if necessary.
struct BoundedUnreadDivider: View {
    let label: String
    let actionTitle: String
    let onLoadEarlier: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.accentColor.opacity(0.45)).frame(height: 1)
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .fixedSize()
            Button(actionTitle, action: onLoadEarlier)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .buttonStyle(.borderless)
            Rectangle().fill(Color.accentColor.opacity(0.45)).frame(height: 1)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityHint("Loads one earlier message page")
    }
}

/// Compact snooze chooser for the selected row (S key). Keyboard-native:
/// each option carries its letter, matching the work-inbox shortcuts.
/// Deadlines are absolute — "tomorrow" means the next 09:00 local, not +16 h.
struct SnoozePanel: View {
    let rowID: Int64
    let onDismiss: () -> Void
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SNOOZE")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8).padding(.top, 6)
            option("Later today", "H", until: AppState.snoozeOneHour)
            option("Tomorrow 9am", "T", until: AppState.nextMorning())
            option("Next week", "W", until: AppState.snoozeNextWeek())
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)))
        .frame(width: 150)
    }

    private func option(_ title: String, _ key: String, until: Int64) -> some View {
        Button {
            Task {
                if await state.snoozeMessage(rowID: rowID, until: until, label: title.lowercased()) {
                    onDismiss()
                }
            }
        } label: {
            HStack {
                Text(title).font(.system(size: 11.5, design: .monospaced))
                Spacer()
                Text(key).font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Reaction picker for the selected row (E key).
struct ReactionPanel: View {
    let rowID: Int64
    let onDismiss: () -> Void
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 2) {
            ForEach(["👍", "❤️", "😂", "✅"], id: \.self) { emoji in
                Button {
                    Task {
                        try? await state.apiClient?.react(rowID: rowID, emoji: emoji)
                        onDismiss()
                    }
                } label: {
                    Text(emoji)
                        .font(.system(size: 16))
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)))
    }
}

/// Isolated composer: keystrokes re-render only this view, never the
/// 200-row transcript list above it. Typing "@…" in a group opens a member
/// mention popup (click / Tab / Enter to accept).
struct ComposerBar: View {
    /// Owning chat: switching chats must clear the mention popup, but the
    /// DRAFT is preserved per chat in state.draftStore — peeking at another
    /// conversation must not lose a half-typed message.
    let chatJID: String
    @EnvironmentObject var state: AppState
    @State private var draft = ""
    @State private var fieldFocused = false
    /// Picked-but-not-sent image. Two-step attach: paperclip only picks,
    /// the user types a caption, ⌘Enter / send ships them together.
    @State private var attachmentURL: URL?
    @StateObject private var mediaSubmitAction = ComposerMediaSubmitAction()
    @State private var mentionMembers: [APIClient.GroupMember] = []
    @State private var mentionPrefix = ""
    @State private var mentionActive = false

    /// Members matching the typed "@prefix" (empty prefix = first few).
    private var mentionSuggestions: [APIClient.GroupMember] {
        guard mentionActive else { return [] }
        let q = mentionPrefix.lowercased()
        var scored: [APIClient.GroupMember] = []
        for m in mentionMembers {
            let name = label(for: m).lowercased()
            if q.isEmpty || name.contains(q) {
                scored.append(m)
                if scored.count >= 6 { break }
            }
        }
        return scored
    }

    private func label(for m: APIClient.GroupMember) -> String {
        state.mentionLabel(for: m.jid, fallback: m.display_name)
    }

    var body: some View {
        VStack(spacing: 6) {
            replyBanner
            attachmentBanner
            inputRow
        }
        .padding(10)
        .onAppear { draft = state.draftStore[chatJID] ?? "" }
        .onChange(of: draft) { _, d in
            if state.draftStore[chatJID] != d {
                mediaSubmitAction.noteCompositionChanged(for: chatJID)
            }
            state.draftStore[chatJID] = d
            updateMentionState(d)
        }
        .onChange(of: state.composerFocusRequest) { _, _ in
            fieldFocused = true
        }
        .onChange(of: fieldFocused) { _, focused in
            // The ⌘V dispatcher (replaced Edit>Paste command) needs to know
            // whether the composer is the paste target.
            state.composerFieldFocused = focused
            if focused {
                Task { await state.commitRead(chatJID, source: .composerFocus) }
            }
        }
        .onChange(of: state.pendingPasteImage) { _, url in
            guard let url else { return }
            attach(url: url)
            state.pendingPasteImage = nil
        }
        .onChange(of: state.pendingMentionInsert) { _, label in
            guard let label else { return }
            if !draft.isEmpty && !draft.hasSuffix(" ") { draft += " " }
            draft += "@\(label) "
            state.pendingMentionInsert = nil
        }
        .onChange(of: chatJID) { _, newChat in
            draft = state.draftStore[newChat] ?? ""
            attachmentURL = nil // a picked image belongs to the chat it was picked in
            mentionActive = false
            mentionPrefix = ""
            // Roster MUST follow the chat: mentionMembers is @State fetched
            // lazily (only when empty), so without this the PREVIOUS group's
            // members kept popping up — even in direct chats.
            mentionMembers = []
        }
        .onDisappear { mentionActive = false }
    }

    @ViewBuilder
    private var replyBanner: some View {
        if let reply = state.reply(for: chatJID) {
            HStack(spacing: 8) {
                Rectangle().fill(Color.accentColor).frame(width: 2, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.nameFor(reply.sender_jid)).font(.caption.bold())
                    Text(reply.text ?? reply.media?.kind.capitalized ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button {
                    state.clearReply(for: chatJID)
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
        }
    }

    /// Icon for a staged attachment, by MIME family (UTType lookup with the
    /// same fallback rules as the send path).
    static func attachIcon(for url: URL) -> String {
        switch AppState.mime(forExtension: url.pathExtension) {
        case let m where m.hasPrefix("image/"): return "photo"
        case let m where m.hasPrefix("video/"): return "film"
        case let m where m.hasPrefix("audio/"): return "waveform"
        default: return "doc"
        }
    }

    /// Picked image waiting to be sent: file name + remove, same quiet chip
    /// style as the reply banner. File metadata belongs to the async loader.
    @ViewBuilder
    private var attachmentBanner: some View {
        if let url = attachmentURL {
            HStack(spacing: 8) {
                Image(systemName: Self.attachIcon(for: url)).foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                Spacer()
                Button {
                    removeAttachment()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove attachment")
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if mediaSubmitAction.isSubmitting || state.sendingMedia {
                ProgressView().controlSize(.small).padding(.bottom, 10)
            }
            Button(action: pickFile) {
                Image(systemName: "paperclip")
            }
            .buttonStyle(.plain)
            .help("Attach file — pick now, type a caption, send together")
            .padding(.bottom, 6)
            inputField
            Button(action: { Task { await submit() } }) {
                Image(systemName: "paperplane.fill")
            }
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .padding(.bottom, 8)
        }
    }

    private var canSend: Bool {
        mediaSubmitAction.isSubmitting == false &&
            state.sendingMedia == false &&
            (attachmentURL != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Two-step attach: the panel only PICKS (any file — documents, video,
    /// audio, images; the core maps the MIME to the right WhatsApp kind).
    /// Caption is typed afterwards in the normal composer; ⌘Enter (or the
    /// plane) ships file + text together.
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attach(url: url)
    }

    /// Shared attach path for picker and clipboard paste: stage the file and
    /// drop the caret into the caption field. Bumping the focus request
    /// (instead of setting fieldFocused directly) is what actually focuses
    /// the NSTextView via MentionTextView's focusRequest.
    private func attach(url: URL) {
        mediaSubmitAction.noteCompositionChanged(for: chatJID)
        attachmentURL = url
        state.composerFocusRequest += 1
    }

    private func removeAttachment() {
        mediaSubmitAction.noteCompositionChanged(for: chatJID)
        attachmentURL = nil
    }

    private var inputField: some View {
        VStack(spacing: 4) {
            if !mentionSuggestions.isEmpty {
                mentionPopup
            }
            ZStack(alignment: .topLeading) {
                MentionTextView(
                    text: $draft,
                    resolvedLabels: Array(state.mentionTargets.values),
                    font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                    enterInterceptor: {
                        // Enter with the popup open accepts the first match.
                        if let first = mentionSuggestions.first {
                            acceptMention(first)
                            return true
                        }
                        return false
                    },
                    onEnter: { submitFromKeyboard() },
                    onFocusChange: { fieldFocused = $0 },
                    focusRequest: state.composerFocusRequest
                )
                // Placeholder: an NSTextView has none of its own. Offsets
                // mirror TextKit's line-fragment padding.
                if draft.isEmpty {
                    Text("Message…")
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(EdgeInsets(top: 3, leading: 10, bottom: 0, trailing: 10))
                        .allowsHitTesting(false)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 2).fill(.quaternary.opacity(0.35)))
        }
    }

    /// Popup: click a row, Tab accepts the first (multiline composer means
    /// Return inserts a newline), Esc dismisses.
    private var mentionPopup: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(mentionSuggestions.enumerated()), id: \.element.jid) { idx, m in
                mentionRow(m, tabAccept: idx == 0)
            }
            // Esc closes the popup; invisible landing spot for .cancelAction.
            Button("Dismiss suggestions") { mentionActive = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(height: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func mentionRow(_ m: APIClient.GroupMember, tabAccept: Bool) -> some View {
        let row = mentionRowButton(m)
        if tabAccept {
            row.keyboardShortcut(.tab, modifiers: [])
        } else {
            row
        }
    }

    private func mentionRowButton(_ m: APIClient.GroupMember) -> some View {
        Button {
            acceptMention(m)
        } label: {
            HStack(spacing: 6) {
                Text(mentionRowTitle(m))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(IRCPalette.nickColor(state.nickColorKey(for: m.jid)))
                    .lineLimit(1)
                if m.role == "admin" || m.role == "superadmin" {
                    Text(m.role)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func mentionRowTitle(_ m: APIClient.GroupMember) -> String {
        "@" + label(for: m)
    }

    /// Track the trailing "@token" being typed; (re)try the member load
    /// while it's empty — a failed fetch must not kill autocomplete.
    private func updateMentionState(_ d: String) {
        guard let range = d.range(of: #"(?:^|\s)@([A-Za-z0-9_]*)$"#, options: .regularExpression),
              let at = d[range].firstIndex(of: "@") else {
            mentionActive = false
            mentionPrefix = ""
            return
        }
        let token = d[range]
        mentionPrefix = String(token[token.index(after: at)...])
        if !mentionActive {
            mentionActive = true
        }
        if mentionMembers.isEmpty {
            let chat = chatJID
            Task { mentionMembers = await state.mentionCandidates(for: chat) }
        }
    }

    private func acceptMention(_ m: APIClient.GroupMember) {
        let label = label(for: m)
        guard let range = draft.range(of: #"(?:^|\s)@([A-Za-z0-9_]*)$"#, options: .regularExpression) else {
            return
        }
        draft.removeSubrange(range)
        if !draft.isEmpty && !draft.hasSuffix(" ") { draft += " " }
        draft += "@\(label) "
        state.setMentionTarget(m.jid, label: label, for: chatJID)
        mentionActive = false
        mentionPrefix = ""
    }

    /// Enter with suggestions open accepts the first match instead of sending.
    private func submitFromKeyboard() {
        if let first = mentionSuggestions.first {
            acceptMention(first)
            return
        }
        Task { await submit() }
    }

    private func submit() async {
        guard !mediaSubmitAction.isSubmitting else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attachment flow: image + caption (draft) leave together.
        if let url = attachmentURL {
            let ownerChatJID = chatJID
            let outcome = await mediaSubmitAction.submit(
                chatJID: ownerChatJID,
                draft: draft,
                attachmentURL: url,
                caption: text,
                send: { request in
                    await state.sendAttachment(
                        url: request.attachmentURL,
                        caption: request.caption,
                        in: request.chatJID
                    )
                },
                completionState: {
                    ComposerMediaCompositionSnapshot(
                        ownerDraft: state.draftStore[ownerChatJID],
                        visibleChatJID: state.selectedChat ?? "",
                        visibleDraft: draft,
                        visibleAttachmentURL: attachmentURL
                    )
                }
            )
            if outcome.completion.clearsOwnerDraft {
                state.draftStore[ownerChatJID] = ""
            }
            if outcome.completion.clearsVisibleDraft {
                draft = ""
                mentionActive = false
            }
            if outcome.completion.clearsVisibleAttachment {
                attachmentURL = nil
            }
            return
        }
        guard !text.isEmpty else { return }
        draft = ""
        mentionActive = false
        if state.reply(for: chatJID) != nil {
            await state.sendReply(text, in: chatJID)
        } else {
            await state.send(text, in: chatJID)
        }
    }
}

struct MessageBubble: View {
    let message: Message
    var highlighted: Bool = false
    var timeColumn: CGFloat = 62
    var nickColumn: CGFloat = 72
    var fontSize: Double = 12.5
    var rowPadding: CGFloat = 0.5
    var onJumpQuote: (String) -> Void = { _ in }
    @EnvironmentObject var state: AppState
    @State private var quoteHover = false

    /// weechat-style table row: fixed right-aligned time column, fixed
    /// right-aligned nick column, then the text — so every message starts at
    /// the same x and wraps align under the text column.
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(IRCLineText.timeString(message.timestamp))
                .font(.system(size: fontSize - 1.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: timeColumn, alignment: .trailing)

            Text(state.ircNick(for: message))
                .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(nickColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                .frame(width: nickColumn + 12, alignment: .topTrailing)
                .padding(.leading, 12)
                .contentShape(Rectangle())
                .onTapGesture {
                    state.openProfileRequest(for: message.sender_jid, in: message.chat_jid)
                }
                .help("Click to view profile")

            VStack(alignment: .leading, spacing: 0) {
                if message.starred == true || message.done == true {
                    // Local work state, visible on the row: a star or done
                    // marker that was previously write-only (the action
                    // succeeded with nothing to show for it).
                    HStack(spacing: 4) {
                        if message.starred == true {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                        if message.done == true {
                            Text("✓ done")
                                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.leading, 4)
                }
                if let quoted = message.quoted_text, !quoted.isEmpty {
                    // Quoted text carries raw mention tokens (the quoted
                    // message's own mentioned_jids are gone) — resolve
                    // numeric tokens through the contact index.
                    quoteLine(state.resolveBareMentionTokens(in: quoted))
                        .onTapGesture { onJumpQuote(message.reply_to_id ?? "") }
                        .onHover { quoteHover = $0 }
                        .opacity(quoteHover ? 1 : 0.85)
                        .help("Jump to quoted message")
                }
                IRCLineText(message: message, fontSize: fontSize)
                    .padding(.leading, 4)
                failedLine
                mediaAttachment
                reactionChips
            }
        }
        .padding(.vertical, rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(highlightBackground)
        .contextMenu { menu }
        .onAppear { state.messageRowDidAppearProxy(rowID: message.id) }
    }

    private var nickColor: Color {
        message.from_me ? Color(red: 0.95, green: 0.60, blue: 0.15)
                        : IRCPalette.nickColor(state.nickColorKey(for: message.sender_jid))
    }

    /// weechat highlight: lines that mention you get a full-row tint.
    private var rowTint: Color? {
        message.has_mention && !message.from_me
            ? Color(red: 0.9, green: 0.7, blue: 0.1).opacity(0.14)
            : nil
    }

    /// Jump-flash (quote reply / inbox / search anchor): accent tint PLUS a
    /// 3 pt left bar — unmistakable at a glance, and distinct from the
    /// mention wash and keyboard selection.
    @ViewBuilder
    private var highlightBackground: some View {
        if highlighted {
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor).frame(width: 3)
                Color.accentColor.opacity(0.20)
            }
        } else if let tint = rowTint {
            tint
        }
    }

    /// Reply quote: gray `↩ nick: text` above the message, text-column aligned.
    private func quoteLine(_ quoted: String) -> some View {
        (Text("↩ ").foregroundColor(.secondary)
            .font(.system(size: fontSize - 1.5, design: .monospaced))
        + Text(replyAuthor).foregroundColor(.secondary)
            .font(.system(size: fontSize - 1.5, weight: .semibold, design: .monospaced))
        + Text(": ").foregroundColor(.secondary)
            .font(.system(size: fontSize - 1.5, design: .monospaced))
        + Text(quoted).foregroundColor(.secondary)
            .font(.system(size: fontSize - 1.5, design: .monospaced)))
            .lineLimit(1)
            .padding(.leading, 4)
    }

    @ViewBuilder
    private var mediaAttachment: some View {
        if let media = message.media, !message.revoked {
            MediaBubble(message: message, media: media)
                .frame(maxWidth: 220, maxHeight: 200, alignment: .leading)
                .padding(.leading, 4)
        }
    }    /// Tiny clickable reaction chips (own reaction removable by click).
    @ViewBuilder
    private var reactionChips: some View {
        let reactions = message.reactions ?? []
        if !reactions.isEmpty {
            let grouped = Dictionary(grouping: reactions, by: { $0.emoji })
                .map { (emoji: $0.key, users: $0.value) }
                .sorted { $0.users.count > $1.users.count }
            HStack(spacing: 4) {
                ForEach(grouped, id: \.emoji) { g in
                    Button {
                        // In LID-addressed groups our own reaction is stored
                        // under the @lid twin — compare both forms or the
                        // toggle re-reacts instead of removing.
                        let ownLID = state.chatMembers[message.chat_jid]?
                            .first { $0.jid == state.ownJID }?.lid
                        let mine = g.users.contains {
                            $0.reactor_jid == state.ownJID
                                || (ownLID != nil && $0.reactor_jid == ownLID)
                        }
                        Task {
                            try? await state.apiClient?.react(rowID: message.id,
                                                              emoji: mine ? "" : g.emoji)
                        }
                    } label: {
                        Text("\(g.emoji) \(g.users.count)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 4)
        }
    }

    /// Failed sends must be unmissable and one-click fixable. Retry only
    /// exists for plain text rows: retrySend re-sends the text, and media
    /// bytes are gone after the first attempt (a captioned image would
    /// resend as bare text — wrong content). Media failures say "re-attach".
    private var canRetry: Bool {
        message.media == nil && !(message.text ?? "").isEmpty
    }

    @ViewBuilder
    private var failedLine: some View {
        if message.from_me && message.receipt_status == "failed" {
            HStack(spacing: 6) {
                Text("✗ failed")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
                if canRetry {
                    Button("Retry") { Task { await state.retrySend(message) } }
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .help("Send again")
                } else {
                    Text("re-attach to resend")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 1)
        }
    }

    private var menu: some View {
        Group {
            // Media failures get no Retry: bytes are gone after the first
            // attempt; the row's inline line tells the user to re-attach.
            if canRetry {
                Button("Retry send") { Task { await state.retrySend(message) } }
                Divider()
            }
            Button("Reply") {
                state.setReply(message, for: message.chat_jid)
                state.composerFocusRequest += 1
            }
                .keyboardShortcut("r", modifiers: [])
            if let text = message.text, !text.isEmpty {
                Button("Copy Message") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            // id > 0: optimistic temp rows have negative ids — the server
            // has no message to revoke, Delete would 404.
            if message.from_me && !message.revoked && message.id > 0 {
                Button("Delete…") { state.requestDeleteMessage(message) }
            }
            if message.chat_jid.hasSuffix("@g.us") && !message.from_me {
                Button("Mention @\(state.ircNick(for: message))") {
                    state.insertMention(from: message)
                }
            }
            Divider()
            ForEach(["👍", "❤️", "😂", "✅"], id: \.self) { emoji in
                Button(emoji) { Task { try? await state.apiClient?.react(rowID: message.id, emoji: emoji) } }
            }
            Divider()
            Button(message.done == true ? "Mark Not Done" : "✓ Done") {
                Task { await state.markDone(message, done: !(message.done ?? false)) }
            }
                .keyboardShortcut("d", modifiers: [])
            Button("Snooze 1 hour") {
                Task { await state.snoozeMessage(rowID: message.id, until: AppState.snoozeOneHour, label: "1 hour") }
            }
                .keyboardShortcut("s", modifiers: [])
            Button("Snooze until tomorrow 09:00") {
                Task { await state.snoozeMessage(rowID: message.id, until: AppState.nextMorning(), label: "tomorrow 9am") }
            }
            Button(message.starred == true ? "Unstar" : "Star") {
                Task { await state.starMessage(message) }
            }
        }
    }

    private var replyAuthor: String {
        state.nameFor(message.reply_to_sender ?? "")
    }
}

struct MediaBubble: View {
    let message: Message
    let media: MessageMedia
    @EnvironmentObject var state: AppState

    private var isVisualMedia: Bool {
        media.kind == "image" || media.kind == "sticker"
    }

    var body: some View {
        Group {
            // Stickers behave exactly like images: tap-to-load, decoded
            // preview in the bubble, tap for full view (animated stickers
            // show their first frame).
            if isVisualMedia, let img = state.mediaImages[message.id] {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await state.openPreview(message) } }
                    .help("Click to preview")
            } else if media.state == "downloaded" {
                // Non-image media: open with the system default handler.
                Button {
                    openExternally()
                } label: {
                    Label(openLabel, systemImage: openIcon)
                }
            } else if state.mediaBusy.contains(message.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Downloading…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            } else if media.state == "failed" {
                Button { Task { await retry() } } label: {
                    Label("Download failed — retry", systemImage: "arrow.clockwise")
                }
            } else {
                Button { Task { await state.ensureMedia(message) } } label: {
                    Label("\(media.kind.capitalized) · \(ByteCountFormatter.string(fromByteCount: media.size, countStyle: .file)) — tap to load",
                          systemImage: icon)
                }
            }
        }
    }

    private var icon: String {
        switch media.kind {
        case "image": "photo"
        case "sticker": "rectangle.on.rectangle"
        case "video": "film"
        case "audio": "waveform"
        case "document": "doc"
        default: "doc"
        }
    }

    private var openIcon: String {
        media.kind == "audio" ? "waveform" : icon
    }

    private var openLabel: String {
        let name = media.filename?.isEmpty == false ? media.filename! : "\(media.kind.capitalized)"
        return "\(name) · \(ByteCountFormatter.string(fromByteCount: media.size, countStyle: .file))"
    }



    private func openExternally() {
        // Non-image media: ask where to save (WhatsApp-Desktop-style save
        // dialog), write, then reveal the file in Finder.
        Task {
            if isVisualMedia {
                await state.ensureMedia(message)
                return
            }
            await state.saveMediaToDisk(message)
        }
    }

    private func retry() async {
        // failed → core treats any non-downloaded as fetchable
        await state.ensureMedia(message)
    }
}

/// mIRC-style member panel: group participants sorted A→Z by name, tap a
/// nick to drop an @mention into the composer. Right-click → View Profile
/// replaces the panel with the full profile; closing it restores the list.
struct MemberPanel: View {
    let chatJID: String
    @EnvironmentObject var state: AppState
    @State private var profile: APIClient.UserProfile?

    private func label(_ m: APIClient.GroupMember) -> String {
        state.mentionLabel(for: m.jid, fallback: m.display_name)
    }

    private var sortedMembers: [APIClient.GroupMember] {
        let members = state.chatMembers[chatJID] ?? []
        return members.sorted {
            label($0).localizedStandardCompare(label($1)) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if let profile {
                ProfileView(profile: profile, chatJID: chatJID) { self.profile = nil }
            } else {
                memberList
            }
        }
        .onChange(of: chatJID) { _, _ in profile = nil }
        .onChange(of: state.profileRequest) { _, req in
            guard let req, req.chatJID == chatJID else { return }
            state.profileRequest = nil // consume
            Task { @MainActor in
                var p = try? await state.apiClient?.profile(jid: req.jid, group: chatJID)
            if p == nil {
                let name = state.nameFor(req.jid)
                p = APIClient.UserProfile(jid: req.jid, lid: nil, full_name: name,
                                          push_name: nil, business_name: nil,
                                          role: nil, picture_url: nil)
            }
                profile = p
            }
        }
    }

    private var memberList: some View {
        List(sortedMembers) { m in
            memberRow(m)
        }
        .listStyle(.plain)
        .overlay {
            if sortedMembers.isEmpty {
                ProgressView().padding(.top, 24)
            }
        }
    }

    private func openProfile(_ m: APIClient.GroupMember) {
        Task { @MainActor in
            var p = try? await state.apiClient?.profile(jid: m.jid, group: chatJID)
            if p == nil {
                // Network/profile fetch failed: fall back to what we know
                // locally so the panel still opens instead of doing nothing.
                let name = state.nameFor(m.jid)
                p = APIClient.UserProfile(jid: m.jid, lid: nil, full_name: name,
                                          push_name: nil, business_name: nil,
                                          role: m.role, picture_url: nil)
            }
            profile = p
        }
    }

    private var mentionActions: MemberMentionActionRouter {
        MemberMentionActionRouter(
            setMentionTarget: { jid, label, chatJID in
                state.setMentionTarget(jid, label: label, for: chatJID)
            },
            queueInsertion: { state.pendingMentionInsert = $0 }
        )
    }

    private func memberRow(_ m: APIClient.GroupMember) -> some View {
        Button {
            let name = label(m)
            mentionActions.fromMemberRow(
                memberJID: m.jid,
                label: name,
                groupChatJID: chatJID
            )
        } label: {
            HStack(spacing: 4) {
                Text(label(m))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(IRCPalette.nickColor(state.nickColorKey(for: m.jid)))
                    .lineLimit(1)
                if m.role == "admin" || m.role == "superadmin" {
                    Text("@")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to mention · right-click for profile")
        .contextMenu {
            Button("View Profile") { openProfile(m) }
            Button("Mention @\(label(m))") {
                let name = label(m)
                mentionActions.fromMemberContextMenu(
                    memberJID: m.jid,
                    label: name,
                    groupChatJID: chatJID
                )
            }
        }
    }
}

/// Full user profile replacing the nick panel: photo, names, phone, LID,
/// role, quick actions. Close returns to the member list. Tapping the photo
/// opens a full-size preview.
struct ProfileView: View {
    let profile: APIClient.UserProfile
    let chatJID: String
    let onClose: () -> Void
    @EnvironmentObject var state: AppState
    @State private var photoPreview: URL?

    private var displayName: String {
        [profile.full_name, profile.push_name, profile.business_name]
            .compactMap { $0 }.first { !$0.isEmpty } ?? AppState.prettyJID(profile.jid)
    }

    private var phone: String {
        AppState.prettyJID(profile.jid)
    }

    private var mentionActions: MemberMentionActionRouter {
        MemberMentionActionRouter(
            setMentionTarget: { jid, label, chatJID in
                state.setMentionTarget(jid, label: label, for: chatJID)
            },
            queueInsertion: { state.pendingMentionInsert = $0 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Profile")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Back to members")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    avatar
                        .frame(maxWidth: .infinity)
                        .padding(.top, 14)

                    Text(displayName)
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(IRCPalette.nickColor(state.nickColorKey(for: profile.jid)))
                        .frame(maxWidth: .infinity)

                    if profile.role == "admin" || profile.role == "superadmin" {
                        Label("Group \(profile.role == "superadmin" ? "owner" : "admin")",
                              systemImage: "crown")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                    }

                    Divider().padding(.vertical, 4)

                    field("Phone", phone)
                    if let b = profile.business_name, !b.isEmpty { field("Business", b) }
                    if let p = profile.push_name, !p.isEmpty, p != displayName { field("WhatsApp name", p) }
                    field("JID", profile.jid)
                    if let lid = profile.lid, !lid.isEmpty, lid != profile.jid {
                        field("LID", lid)
                    }

                    Divider().padding(.vertical, 4)

                    VStack(spacing: 6) {
                        Button {
                            mentionActions.fromProfile(
                                memberJID: profile.jid,
                                label: displayName,
                                groupChatJID: chatJID
                            )
                        } label: {
                            Label("Mention", systemImage: "at")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button {
                            Task {
                                state.sidebarTab = .chats
                                await state.open(profile.jid, source: .mouse)
                            }
                        } label: {
                            Label("Message", systemImage: "paperplane")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        Group {
            if let urlString = profile.picture_url, let url = URL(string: urlString) {
                // CDN URLs expire (R4): a failed fetch must fall back to the
                // initial-letter avatar, not spin forever.
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        initialAvatar
                    default:
                        ProgressView()
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.quaternary))
                .contentShape(Circle())
                .onTapGesture { photoPreview = url }
                .help("Click to preview")
            } else {
                initialAvatar
            }
        }
        .sheet(isPresented: Binding(
            get: { photoPreview != nil },
            set: { if !$0 { photoPreview = nil } })) {
            PhotoPreviewSheet(url: photoPreview, name: displayName)
        }
    }

    private var initialAvatar: some View {
        ZStack {
            Circle().fill(IRCPalette.nickColor(state.nickColorKey(for: profile.jid)).opacity(0.25))
            Text(String(displayName.prefix(1)).uppercased())
                .font(.system(size: 34, weight: .bold, design: .monospaced))
        }
        .frame(width: 96, height: 96)
    }

    /// Full-size photo preview (the 96 pt avatar is a downscaled render).
    private struct PhotoPreviewSheet: View {
        let url: URL?
        let name: String
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            VStack(spacing: 12) {
                if let url {
                    AsyncImage(url: url) { image in
                        image.resizable().interpolation(.medium).scaledToFit()
                    } placeholder: {
                        ProgressView().frame(width: 200, height: 200)
                    }
                    .frame(maxWidth: 560, maxHeight: 560)
                }
                HStack {
                    Text(name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            .frame(minWidth: 360, minHeight: 300)
            .background(Color(white: 0.09))
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Clicked-image preview: big fitted render + open-full-size escape hatch.
struct ImagePreviewSheet: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 12) {
            if let preview = state.previewImage {
                Image(nsImage: preview.image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFit()
                    .frame(maxWidth: 900, maxHeight: 640)
                HStack {
                    Text(preview.message.media?.filename ?? "image")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await state.saveMediaToDisk(preview.message) }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Save image to disk")
                    Button("Close") { state.previewImage = nil }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .background(Color(white: 0.09))
    }
}
