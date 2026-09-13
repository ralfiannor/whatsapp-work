// Work inbox panel: actionable CONVERSATIONS (one row per chat — busy groups
// are one Done, not fifty), plus starred chats and a recently-done audit
// trail. Rows deep-link to the newest pending message.
import SwiftUI

struct InboxView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if let inbox = state.inbox {
            if inbox.counts.total == 0 && inbox.starred_chats.isEmpty && inbox.done_recent.isEmpty {
                zeroState
            } else {
                list(inbox)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var zeroState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)
            Text("Inbox Zero").font(.title3.bold())
            Text("Nothing needs your attention.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Direct messages, @mentions and work-group traffic land here.\nMark a group as Work (right-click it in Chats) to route its traffic in.\nDone clears a whole conversation; reading a chat keeps it.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func list(_ inbox: Inbox) -> some View {
        List {
            if !inbox.mentions.isEmpty {
                section("Mentions", "at", .red, inbox.mentions)
            }
            if !inbox.work_groups.isEmpty {
                section("Work Groups", "briefcase", .orange, inbox.work_groups)
            }
            if !inbox.direct_messages.isEmpty {
                section("Direct", "person", .accentColor, inbox.direct_messages)
            }
            if !inbox.starred_chats.isEmpty {
                Section {
                    ForEach(inbox.starred_chats) { chat in
                        Button {
                            Task { await state.open(chat.jid, source: .inbox) }
                        } label: {
                            HStack(spacing: 8) {
                                CircleAvatar(name: chat.display_name, kind: chat.kind)
                                Text(chat.display_name.isEmpty ? AppState.prettyJID(chat.jid) : chat.display_name)
                                Spacer()
                                Image(systemName: "star.fill")
                                    .font(.caption).foregroundStyle(.yellow)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Label("Starred", systemImage: "star.fill").foregroundStyle(.yellow)
                }
            }
            if !inbox.done_recent.isEmpty {
                Section {
                    ForEach(inbox.done_recent) { item in
                        DoneRow(item: item)
                    }
                } header: {
                    Label("Done — last 7 days", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.sidebar)
        .refreshable { await state.refreshInbox() }
        .task {
            // Fetch immediately on appear: the segmented control switches
            // tabs without going through showInbox() (⌘4), so the view
            // itself must load its data — otherwise nil inbox = spinner
            // forever. Snooze deadlines expire silently on the core
            // (query-time rule, no timers): the slow loop below resurfaces
            // due conversations while the tab stays visible.
            await state.refreshInbox()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard state.sidebarTab == .inbox else { return }
                await state.refreshInbox()
            }
        }
    }

    private func section(_ title: String, _ icon: String, _ tint: Color,
                         _ items: [InboxConversation]) -> some View {
        Section {
            ForEach(items) { ConversationRow(conversation: $0) }
        } header: {
            Label("\(title) — \(items.count)", systemImage: icon).foregroundStyle(tint)
        }
    }
}

/// One actionable conversation: avatar, name, pending count, newest message
/// digest. Done/Snooze act on the WHOLE conversation.
struct ConversationRow: View {
    let conversation: InboxConversation
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CircleAvatar(name: conversation.chat_name, kind: conversation.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(conversation.chat_name.isEmpty ? AppState.prettyJID(conversation.chat_jid) : conversation.chat_name)
                        .bold().lineLimit(1)
                    if conversation.has_mention {
                        Image(systemName: "at").font(.caption2).foregroundStyle(.red)
                    }
                    if conversation.count > 1 {
                        Text("×\(conversation.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                            .foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                    Text(ChatRow.timeString(conversation.last_timestamp))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                Text(snippet)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            actionButtons
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await state.open(conversation.chat_jid, anchorMessageID: conversation.last_message_id, source: .inbox) }
        }
        .contextMenu { menu }
    }

    private var snippet: String {
        let sender = state.ircNick(for: carrier)
        let body = conversation.last_text?.isEmpty == false ? conversation.last_text! : "Media message"
        return "\(sender): \(state.resolveBareMentionTokens(in: body))"
    }

    private var actionButtons: some View {
        HStack(spacing: 2) {
            rowButton("checkmark", "Mark conversation done (\(conversation.count) item\(conversation.count == 1 ? "" : "s"))") {
                _ = await state.markConversationDone(conversation)
            }
            rowButton("clock.arrow.circlepath", "Snooze conversation") {
                _ = await state.snoozeConversation(conversation, until: AppState.snoozeOneHour, label: "1 hour")
            }
        }
    }

    private func rowButton(_ icon: String, _ help: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: icon)
                .font(.caption)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var menu: some View {
        Group {
            Button("✓ Done — all \(conversation.count) item\(conversation.count == 1 ? "" : "s")") {
                Task { _ = await state.markConversationDone(conversation) }
            }
            Button("Snooze 1 hour") {
                Task { _ = await state.snoozeConversation(conversation, until: AppState.snoozeOneHour, label: "1 hour") }
            }
            Button("Snooze until tomorrow 09:00") {
                Task { _ = await state.snoozeConversation(conversation, until: AppState.nextMorning(), label: "tomorrow 9am") }
            }
            Button("Open conversation") {
                Task { await state.open(conversation.chat_jid, anchorMessageID: conversation.last_message_id, source: .inbox) }
            }
        }
    }

    /// Message-shaped carrier for the transcript nick resolver.
    private var carrier: Message {
        Message(id: conversation.last_rowid, message_id: conversation.last_message_id,
                chat_jid: conversation.chat_jid, sender_jid: conversation.last_sender_jid,
                from_me: false, timestamp: conversation.last_timestamp, kind: conversation.last_kind,
                text: conversation.last_text, reply_to_id: nil, reply_to_sender: nil,
                quoted_text: nil, has_mention: conversation.has_mention, receipt_status: nil,
                revoked: false, forwarded: nil, edited_ts: nil, raw_kind: nil,
                media: nil, reactions: nil)
    }
}

/// Completed item: quiet audit row with a Reopen button — done must be
/// visible and reversible, not a black hole.
struct DoneRow: View {
    let item: InboxItem
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.chat_name.isEmpty ? AppState.prettyJID(item.chat_jid) : item.chat_name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(item.text?.isEmpty == false ? item.text! : "Media message")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .strikethrough()
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task {
                    _ = await state.markDone(carrier, done: false)
                    await state.refreshInbox()
                }
            } label: {
                Text("Reopen")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Put this item back in the inbox")
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { Task { await state.open(item.chat_jid, anchorMessageID: item.message_id, source: .inbox) } }
    }

    private var carrier: Message {
        Message(id: item.rowid, message_id: item.message_id, chat_jid: item.chat_jid,
                sender_jid: item.sender_jid, from_me: false, timestamp: item.timestamp,
                kind: "text", text: item.text, reply_to_id: nil, reply_to_sender: nil,
                quoted_text: nil, has_mention: item.has_mention, receipt_status: nil,
                revoked: false, forwarded: nil, edited_ts: nil, raw_kind: nil,
                media: nil, reactions: nil)
    }
}
