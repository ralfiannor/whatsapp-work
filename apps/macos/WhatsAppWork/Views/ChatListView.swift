// Main three-pane layout: sidebar (chats) + transcript + composer.
// Lists use `List` (NSTableView-backed virtualization) per R7 — never
// LazyVStack-in-ScrollView for long data.
import SwiftUI

struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationSplitView {
            ChatListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 380)
        } detail: {
            if let chat = state.selectedChat {
                TranscriptView(chatJID: chat)
            } else {
                Text("Select a conversation")
                    .font(.title3).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct ChatListView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Sidebar", selection: $state.sidebarTab) {
                    Text("Chats").tag(SidebarTab.chats)
                    Text("Inbox").tag(SidebarTab.inbox)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: .infinity)
                Button {
                    state.toggleFocusMode()
                } label: {
                    Image(systemName: state.focusMode ? "moon.fill" : "moon")
                        .foregroundStyle(state.focusMode ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(state.focusMode
                      ? "Focus Mode on — only work chats notify"
                      : "Focus Mode off — all chats notify")
            }
            .padding(.horizontal, 10).padding(.top, 6)
            Divider().padding(.top, 6)
            if state.sidebarTab == .inbox {
                InboxView()
            } else {
                Picker("Filter", selection: filterBinding) {
                    Text("All").tag("all")
                    Text("Unread").tag("unread")
                    Text("Mentions").tag("mentions")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                chatList
            }
        }
    }

    private var filterBinding: Binding<String> {
        Binding(get: { state.chatFilter }, set: { f in
            Task { await state.applyFilter(f) }
        })
    }

    private var chatList: some View {
        List(selection: $state.selectedChat) {
            ForEach(state.chats) { chat in
                ChatRow(chat: chat,
                        focus: state.focusMode,
                        work: state.isWorkChat(chat.jid))
                    .tag(chat.jid)
                    .onAppear {
                        if chat.jid == state.chats.last?.jid {
                            Task { await state.loadMoreChats() }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .onKeyPress("j") { moveSelection(1) }
        .onKeyPress("k") { moveSelection(-1) }
        .onKeyPress(.return) {
            guard let jid = state.selectedChat else { return .ignored }
            Task { await state.commitRead(jid, source: .enter) }
            return .handled
        }
        .overlay {
            if state.chats.isEmpty {
                if state.chatsLoaded {
                    emptyState
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for sync…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: state.selectedChat) { _, jid in
            guard let jid else { return }
            let browsing = state.consumeSelectionBrowsing()
            Task {
                await state.loadSelectedChat(jid)
                if !browsing {
                    await state.commitRead(jid, source: .selectionChange)
                }
            }
        }
        .onAppear { finishLaunchAtLoadedRunLoopProxy() }
        .onChange(of: state.chatsLoaded) { _, loaded in
            if loaded { finishLaunchAtLoadedRunLoopProxy() }
        }
        .refreshable { await state.refreshChats() }
    }

    /// Correlation marker after SwiftUI has scheduled the loaded list. Actual
    /// first-frame presentation is measured by Instruments App Launch.
    private func finishLaunchAtLoadedRunLoopProxy() {
        guard state.chatsLoaded else { return }
        DispatchQueue.main.async {
            guard state.chatsLoaded else { return }
            state.loadedChatListDidReachRunLoopProxy()
        }
    }

    /// Loaded-but-empty list: an honest per-filter message, not a spinner
    /// that never stops (the old state read as "broken" on empty filters).
    private var emptyState: some View {
        let (icon, title, subtitle): (String, String, String)
        switch state.chatFilter {
        case "mentions":
            icon = "at"
            title = "No unread mentions"
            subtitle = "You're all caught up. New @mentions appear here while unread.\nHandled mentions live in the Inbox (⌘4)."
        case "unread":
            icon = "envelope.open"
            title = "No unread messages"
            subtitle = "You're all caught up."
        default:
            icon = "bubble.left.and.bubble.right"
            title = "No conversations"
            subtitle = "Chats appear here after the first sync."
        }
        return VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.bold())
            Text(subtitle)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// J/K: next/previous conversation (fires only while the list has key
    /// focus — typing in the composer is never captured).
    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        guard !state.chats.isEmpty else { return .ignored }
        let current = state.selectedChat.flatMap { jid in
            state.chats.firstIndex(where: { $0.jid == jid })
        }
        let next: Int
        switch current {
        case let idx?: next = min(max(idx + delta, 0), state.chats.count - 1)
        case nil: next = delta > 0 ? 0 : state.chats.count - 1
        }
        state.markSelectionBrowsing()
        state.selectedChat = state.chats[next].jid
        return .handled
    }
}

/// Equatable row: chats-array writes (every incoming message bumps it) skip
/// identical rows instead of re-diffing 165 mono-styled rows on old Intel.
struct ChatRow: View, Equatable {
    let chat: String
    let chatData: Chat
    @EnvironmentObject var state: AppState
    let focusMode: Bool
    let isWork: Bool

    init(chat c: Chat, focus: Bool, work: Bool) {
        chat = c.jid
        chatData = c
        focusMode = focus
        isWork = work
    }

    static func == (lhs: ChatRow, rhs: ChatRow) -> Bool {
        lhs.chatData == rhs.chatData && lhs.focusMode == rhs.focusMode && lhs.isWork == rhs.isWork
    }

    var body: some View {
        rowBody
            .opacity(focusMode && !isWork ? 0.45 : 1)
            .contextMenu { menu }
    }

    private var menu: some View {
        Group {
            Button("Mark Read") { Task { await state.commitRead(chat, source: .mouse) } }
            Divider()
            Button((chatData.is_starred ?? false) ? "Unstar" : "Star as Work Contact") {
                Task { try? await state.apiClient?.setChatStar(jid: chat, starred: !(chatData.is_starred ?? false)) }
            }
            if chatData.kind == "group" {
                Button((chatData.is_work ?? false) ? "Remove from Work Groups" : "Mark as Work Group") {
                    Task { try? await state.apiClient?.setChatWork(jid: chat, work: !(chatData.is_work ?? false)) }
                }
            }
            if chatData.kind != "group" {
                Button("Copy wa.me Link") { state.copyWaMeLink(forChat: chat) }
            }
        }
    }

    private var chatTitle: String {
        chatData.display_name.isEmpty ? AppState.prettyJID(chatData.jid) : chatData.display_name
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(chatData.kind == "group" ? "#" : "@")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Text(chatTitle)
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(chatData.kind == "group" ? .primary : IRCPalette.nickColor(state.nickColorKey(for: chatData.jid)))
                    .lineLimit(1)
                if chatData.is_starred == true {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                }
                if chatData.is_work ?? false {
                    Image(systemName: "briefcase.fill").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                if chatData.mentioned_unread > 0 {
                    // Mention state must be scannable without switching to
                    // the Mentions filter: glyph + number, not color alone.
                    Text("@\(chatData.mentioned_unread)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 0)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                        .foregroundStyle(Color.accentColor)
                }
                if chatData.unread_count > 0 {
                    Text("\(chatData.unread_count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 0)
                        .background(Capsule().fill(Color(red: 0.75, green: 0.15, blue: 0.15)))
                        .foregroundStyle(.white)
                }
            }
            HStack {
                Text(state.resolveBareMentionTokens(in: chatData.last_preview ?? ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(Self.timeString(chatData.last_message_ts ?? 0))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
        .simultaneousGesture(TapGesture().onEnded {
            Task { await state.openChatRow(chat, source: .mouse) }
        })
    }

    static func timeString(_ ts: Int64) -> String {
        guard ts > 0 else { return "" }
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct CircleAvatar: View {
    let name: String
    let kind: String

    var body: some View {
        ZStack {
            Circle().fill(avatarColor.opacity(0.25))
            Text(String(name.prefix(1)).uppercased())
                .font(.headline)
        }
        .frame(width: 34, height: 34)
    }

    private var avatarColor: Color {
        kind == "group" ? .blue : .green
    }
}
