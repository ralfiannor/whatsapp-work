// AppState: single source of UI truth. REST is authoritative; WS events are
// hints that patch state incrementally (never a full refresh per message).
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import UserNotifications

@MainActor
final class AppState: ObservableObject {
    enum Screen { case login; case main }

    @Published var screen: Screen = .login
    @Published var connectionState: String = "logged_out"
    /// Last confirmed WS activity — healthy stream makes the 15s poll redundant.
    var lastWSActivityAt: Date?
    @Published var qrCode: String?
    @Published var syncProgress: Double?
    @Published var chats: [Chat] = []
    @Published var selectedChat: String? {
        didSet {
            guard selectedChat != oldValue else { return }
            if let oldValue {
                performanceSignposts.cancelPendingRows(chatKey: oldValue)
                cancelChatSwitchMeasurement(for: oldValue)
            }
            if let selectedChat,
               let operation = performanceSignposts.beginChatSwitch(chatKey: selectedChat) {
                activeChatSwitchMeasurement = ChatSwitchMeasurement(
                    chatKey: selectedChat,
                    operation: operation
                )
            }
            if let selectedChat, messagesByChat[selectedChat] != nil {
                transcriptRetention.touch(selectedChat)
            }
            enforceTranscriptRetention()
        }
    }
    @Published var messagesByChat: [String: [Message]] = [:]
    /// Advances only after the selected chat's newly fetched page has decoded
    /// and merged. TranscriptView uses it to avoid treating cached rows that
    /// appeared before the request completed as a successful chat switch.
    @Published private(set) var selectedMessagePageRenderVersion: UInt64 = 0
    /// Transient error/info surfacing (send failures, media errors). Rendered
    /// by RootView's bottom overlay; auto-dismisses after a few seconds.
    @Published var toast: String? {
        didSet { scheduleToastDismiss() }
    }
    /// Where "new" began when the chat was acknowledged, retained for this
    /// session after markRead zeroes the live counter. rowID is nil while the
    /// first unread row is older than the bounded window; each older-page
    /// merge recomputes it from the captured count.
    @Published var unreadBoundaries: [String: UnreadBoundary] = [:]
    /// Bump to move keyboard focus into the composer (R key / reply flow).
    @Published var composerFocusRequest = 0
    /// Per-chat composer drafts (not published: keystrokes must stay inside
    /// ComposerBar). Switching chats preserves, returning restores.
    var draftStore: [String: String] = [:]
    /// Per-chat @mention target maps — the jid→"@Label" pairs that make a
    /// restored draft's "@Name" tokens send as real mentions.
    var mentionTargetStore: [String: [String: String]] = [:]
    private var mentionGenerations = ChatMentionGenerationStore()
    @Published var contactNames: [String: String] = [:]
    @Published var mediaImages: [Int64: NSImage] = [:]
    @Published var mediaBusy: Set<Int64> = []
    @Published private var replyStore = ChatReplyStore()
    @Published var searchOpen = false
    @Published var chatFilter: String = "all" // all | unread | mentions
    /// True once any chat page has loaded: an empty list afterwards means
    /// "no matches" (empty state), not "still loading" (spinner).
    @Published private(set) var chatsLoaded = false
    @Published var sidebarTab: SidebarTab = .chats
    /// Focus Mode: only work-marked chats (work groups + starred work
    /// contacts) may notify or feed the dock badge; everything else silent.
    @AppStorage("focusMode") var focusMode = false
    /// Message to scroll to once the transcript loads (inbox/search jump).
    /// Chat-scoped: an unresolved anchor must never page history in the
    /// WRONG chat after the user switches before it resolves.
    struct PendingAnchor: Equatable {
        let chatJID: String
        let messageID: String
    }
    @Published var pendingAnchor: PendingAnchor?
    /// Mention composition: jid → "@label" recorded as the user picks
    /// suggestions (autocomplete or context menu); sent as mentioned_jids.
    @Published var mentionTargets: [String: String] = [:]
    /// A label the context menu asked the composer to append ("@Name ").
    @Published var pendingMentionInsert: String?
    /// True while the composer's text field owns keyboard focus — the ⌘V
    /// dispatcher (Edit ▸ Paste replacement) only attaches clipboard images
    /// there; everywhere else ⌘V must keep pasting text.
    var composerFieldFocused = false
    /// Clipboard image staged by the ⌘V dispatcher; ComposerBar attaches it.
    @Published var pendingPasteImage: URL?
    /// Nick-tap in the transcript asking the member panel to open a profile
    /// (chat-scoped: the panel lives inside that group's transcript).
    @Published var profileRequest: ProfileRequest?

    struct ProfileRequest: Equatable {
        let chatJID: String
        let jid: String
    }
    /// Group members per chat (server-side DB cache answers instantly);
    /// powers the nick panel and the mention autocomplete.
    @Published var chatMembers: [String: [APIClient.GroupMember]] = [:]
    @Published var inbox: Inbox?
    /// Full-size preview target (image tap).
    @Published var previewImage: (image: NSImage, message: Message)?
    @Published var sendingMedia = false
    @Published var ownJIDValue: String?

    func reply(for chatJID: String) -> Message? { replyStore.reply(for: chatJID) }
    func setReply(_ message: Message, for chatJID: String) { replyStore.set(message, for: chatJID) }
    func clearReply(for chatJID: String) { replyStore.clear(chatJID) }

    let sidecar: SidecarManager
    private var api: APIClient?
    private var runtimeClient: AppRuntimeClient?
    private let connectionRefresh: ConnectionRefreshCoordinator<AppRuntimeClient>
    private let reconnectSleep: @MainActor (TimeInterval) async -> Void
    private let attachmentLoad: @Sendable (URL, Int64) async throws -> Data
    private let dockBadgeSink: @MainActor (String?) -> Void
    private let pendingMessageTimestamp: @MainActor () -> Int64
    private let performanceSignposts: PerformanceSignpostLifecycle
    private var pollTimer: Timer?
    private var toastDismissTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    /// Sync-progress events arrive per conversation batch; a full chat refresh
    /// per event would hammer /chats + /contacts during the heaviest window.
    private var syncRefreshTask: Task<Void, Never>?
    private var lastSyncDrivenRefresh: Date?
    /// Contact names rarely change; reloading 2000 contacts on every chat
    /// refresh is pure JSON-decode churn on the main actor.
    private var lastContactsLoad: Date?
    /// Monotonic local id for optimistic (not-yet-acked) messages.
    private var nextTempMessageID: Int64 = -1
    private var transcriptRetention = TranscriptRetention(limit: 10)
    /// Counts active optimistic rows directly. Retention checks therefore do
    /// not rescan every retained transcript (or an unbounded active history).
    private var optimisticRowsByChat: [String: Int] = [:]
    /// Exact membership prevents a provisional echo and a later HTTP callback
    /// from decrementing the same optimistic row twice.
    private var protectedOptimisticChatsByTemp: [Int64: String] = [:]
    private struct ProvisionalEchoOwnership {
        let echo: Message
        let removedTemp: Message
    }
    /// An echo cannot identify one of several simultaneous same-chat/text
    /// sends until an HTTP ack arrives. Keep that bounded ownership evidence
    /// by temp ID, including the removed row, so a later exact ack can repair
    /// either a live or definitively failed provisional assignment.
    private var provisionalEchoesByTemp: [Int64: ProvisionalEchoOwnership] = [:]
    /// Text continuations belong to the exact installed runtime generation.
    /// Client identity alone is insufficient because logout clears state while
    /// the old client remains installed until its endpoint returns.
    private var textSendGeneration: UInt64 = 0
    /// Exact in-flight operation ownership is separate from row protection:
    /// chat removal may tombstone a request after its optimistic row and
    /// protection metadata have already been purged.
    private var activeTextOperationChatsByTemp: [Int64: String] = [:]
    /// Group-mention sends put display text ("@Ann") in the temp row but wire
    /// text ("@<digits>") on the bus; echo reconciliation matches either form
    /// via this snapshot taken at send time.
    private var wireTextByTemp: [Int64: String] = [:]
    /// Attachment work is owned by the installed runtime generation. A
    /// replacement invalidates both file-load continuations and in-flight
    /// upload results before they can mutate the replacement session.
    private var attachmentGeneration: UInt64 = 0
    private var nextAttachmentOperationID: UInt64 = 0
    private var activeAttachmentOperationID: UInt64?

    private struct ChatSwitchMeasurement {
        let chatKey: String
        let operation: PerformanceSignpostLifecycle.Operation
    }
    private struct ReadyChatSwitchMeasurement {
        let measurement: ChatSwitchMeasurement
        let renderVersion: UInt64
    }
    private var activeChatSwitchMeasurement: ChatSwitchMeasurement?
    private var readyChatSwitchMeasurement: ReadyChatSwitchMeasurement?

    var apiClient: APIClient? { api }

    init(
        runtimeClient: AppRuntimeClient? = nil,
        contactSleep: @escaping @MainActor (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        },
        reconnectSleep: @escaping @MainActor (TimeInterval) async -> Void = { delay in
            try? await Task.sleep(for: .seconds(delay))
        },
        sidecar: SidecarManager = SidecarManager(),
        attachmentLoad: @escaping @Sendable (URL, Int64) async throws -> Data = { url, maxBytes in
            try await AttachmentLoader.load(url: url, maxBytes: maxBytes)
        },
        dockBadgeSink: @escaping @MainActor (String?) -> Void = { label in
            NSApplication.shared.dockTile.badgeLabel = label
        },
        pendingMessageTimestamp: @escaping @MainActor () -> Int64 = {
            Int64(Date().timeIntervalSince1970)
        },
        performanceSignposts: PerformanceSignpostLifecycle? = nil
    ) {
        self.performanceSignposts = performanceSignposts ?? PerformanceSignposts.sharedLifecycle
        self.performanceSignposts.beginLaunch()
        self.sidecar = sidecar
        self.runtimeClient = runtimeClient
        api = runtimeClient?.api
        connectionRefresh = ConnectionRefreshCoordinator(sleep: contactSleep)
        self.reconnectSleep = reconnectSleep
        self.attachmentLoad = attachmentLoad
        self.dockBadgeSink = dockBadgeSink
        self.pendingMessageTimestamp = pendingMessageTimestamp
        if let runtimeClient { connectionRefresh.install(runtimeClient) }
    }

    func boot() {
        sidecar.start()
        // Watch sidecar phase; (re)connect clients when running.
        sidecar.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                if case .running = phase {
                    self?.connectIfNeeded()
                } else {
                    self?.cancelForUnavailableSidecar()
                }
            }
            .store(in: &cancellables) // a sink must be retained to stay alive
        observeWake()
    }

    /// Toast auto-dismiss: 4 s, restarted on every write; `toast = nil`
    /// re-enters didSet but the nil guard stops the loop there.
    private func scheduleToastDismiss() {
        toastDismissTask?.cancel()
        guard toast != nil else { return }
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func connectIfNeeded() {
        guard let base = sidecar.apiBase, let token = sidecar.authToken, api == nil else { return }
        let api = APIClient(base: base, token: token)
        let client = AppRuntimeClient(api: api)
        installRuntimeClient(client)
        startConnectionRefresh(.initial, client: client)
        startPolling()
    }

    func installRuntimeClient(_ client: AppRuntimeClient) {
        invalidateAttachmentOperations()
        invalidateTextSendOperations()
        connectionRefresh.install(client)
        runtimeClient = client
        api = client.api
    }

    func cancelForUnavailableSidecar() {
        invalidateAttachmentOperations()
        invalidateTextSendOperations()
        connectionRefresh.cancel()
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        _ = wsLifecycle.replaceConnection()
        lastWSActivityAt = nil
        stopPolling()
        guard let staleClient = runtimeClient else { return }
        runtimeClient = nil
        api = nil
        Task { await staleClient.disconnectEvents() }
    }

    /// (Re)establishes the event stream. A dropped socket reconnects with
    /// capped backoff and refetches state — per the protocol, WS events are
    /// hints and a reconnect means a possible seq gap.
    private var wsReconnectAttempts = 0
    private var wsLifecycle = WebSocketLifecycle()
    private var wsReconnectTask: Task<Void, Never>?

    private func connectWS(_ client: AppRuntimeClient) async {
        guard isCurrentRefreshClient(client) else { return }
        let generation = wsLifecycle.replaceConnection()
        lastWSActivityAt = nil
        await client.connectEvents { [weak self] event in
            Task { @MainActor in
                guard let self, self.wsLifecycle.acceptsActivity(for: generation) else { return }
                self.lastWSActivityAt = Date()
                self.wsReconnectAttempts = 0
                self.apply(event)
            }
        } onHeartbeat: { [weak self] in
            Task { @MainActor in
                guard let self, self.wsLifecycle.acceptsActivity(for: generation) else { return }
                self.lastWSActivityAt = Date()
                self.wsReconnectAttempts = 0
            }
        } onDisconnect: { [weak self] in
            Task { @MainActor in self?.scheduleWSReconnect(for: generation) }
        } onGap: { [weak self] in
            // Events were dropped server-side on a live socket: refetch per
            // the protocol's seq-gap contract. Pings keep arriving, so the
            // 15 s fallback poll would never notice.
            Task { @MainActor in
                guard let self,
                      self.wsLifecycle.acceptsActivity(for: generation),
                      self.isCurrentRefreshClient(client) else { return }
                _ = self.startConnectionRefresh(.reconnect, client: client)
            }
        }
        guard isCurrentRefreshClient(client) else { return }
    }

    @discardableResult
    func startConnectionRefresh(_ reason: ConnectionRefreshReason,
                                client: AppRuntimeClient,
                                epoch: ConnectionRefreshEpoch? = nil) -> Task<Void, Never> {
        connectionRefresh.start(reason, client: client, epoch: epoch, step: { [weak self] step, capturedClient, epoch in
            guard let self, !Task.isCancelled, self.runtimeClient === capturedClient,
                  self.connectionRefresh.isCurrent(capturedClient) else { return .cancelled }
            switch step {
            case .session:
                _ = await self.refreshSession(capturedClient, includeChats: false)
                return self.isCurrentRefreshClient(capturedClient) ? .success : .cancelled
            case .events:
                await self.connectWS(capturedClient)
                return self.isCurrentRefreshClient(capturedClient) ? .success : .cancelled
            case .chats:
                let source: ChatRefreshSource = reason == .initial ? .initial : .reconnect
                let result = await self.refreshChats(
                    capturedClient,
                    filter: self.chatFilter,
                    source: source,
                    authoritativeEpoch: epoch
                )
                switch result {
                case .succeeded: return .success
                case .failed: return .chatFetchFailed
                case .queued, .cancelled: return .cancelled
                }
            case .openTranscript:
                guard let chat = self.selectedChat,
                      self.isCurrentRefreshClient(capturedClient) else { return .success }
                let page = self.performanceSignposts.beginMessagePage()
                var pageOutcome = PerformanceSignpostLifecycle.Outcome.cancelled
                defer { self.performanceSignposts.endMessagePage(page, outcome: pageOutcome) }
                do {
                    let response = try await capturedClient.messages(chat: chat)
                    guard self.isCurrentRefreshClient(capturedClient) else { return .cancelled }
                    self.mergeMessages(response.messages, into: chat)
                    pageOutcome = .completed
                } catch {
                    pageOutcome = Task.isCancelled ? .cancelled : .failed
                }
                return .success
            }
        }, finished: { [weak self] capturedClient in
            guard reason == .initial, let self,
                  self.isCurrentRefreshClient(capturedClient),
                  self.screen == .login, self.qrCode == nil,
                  self.connectionState == "logged_out" || self.connectionState == "linking"
            else { return }
            await self.startLogin(capturedClient)
        })
    }

    private func isCurrentRefreshClient(_ client: AppRuntimeClient) -> Bool {
        !Task.isCancelled && runtimeClient === client && connectionRefresh.isCurrent(client)
    }

    private func scheduleWSReconnect(for generation: UInt64) {
        guard wsLifecycle.acceptsActivity(for: generation) else { return }
        lastWSActivityAt = nil
        guard runtimeClient != nil, connectionState != "logged_out",
              wsLifecycle.shouldScheduleReconnect(for: generation)
        else { return }
        let refreshEpoch = connectionRefresh.beginReconnectBackoff()
        let delay = min(Double(wsReconnectAttempts), 5) * 1.5 + 0.5
        wsReconnectAttempts += 1
        wsReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconnectSleep(delay)
            guard !Task.isCancelled,
                  self.wsLifecycle.acceptsActivity(for: generation),
                  let client = self.runtimeClient,
                  self.connectionRefresh.isCurrent(client)
            else { return }
            self.wsReconnectTask = nil
            self.connectionRefresh.endReconnectBackoff(refreshEpoch)
            self.startConnectionRefresh(.reconnect, client: client, epoch: refreshEpoch)
        }
    }

    // MARK: event application (ordered by arrival; idempotent patches)

    private func apply(_ event: CoreEvent) {
        switch event {
        case .connectionChanged(let state, _):
            handleConnectionState(state)
        case .qr(let code, _):
            sidecar.handleSleepSignal(.qr)
            qrCode = code
            screen = .login
        case .syncProgress(let stage, let progress):
            syncProgress = stage == "done" ? nil : progress
            sidecar.handleSleepSignal(.syncProgress(stage: stage))
            scheduleSyncDrivenRefresh()
        case .messageReceived(let m):
            reconcileTempIfEcho(m)
            let tracksIncomingVisibility = m.chat_jid == selectedChat && !m.from_me
            if tracksIncomingVisibility {
                performanceSignposts.beginIncoming(rowID: m.id, chatKey: m.chat_jid)
            }
            let upsertResult = upsert(m, in: m.chat_jid)
            if tracksIncomingVisibility, upsertResult != .inserted {
                performanceSignposts.cancelVisibleRow(rowID: m.id)
            }
            bumpChat(with: m)
            if !m.from_me && m.chat_jid != selectedChat {
                notify(m)
            }
            if sidebarTab == .inbox {
                scheduleInboxRefresh()
            }
        case .messageUpdated(let m):
            // Coalesced: receipt/reaction/edit storms in busy groups arrive
            // as bursts of events for the same rows — buffer and commit once
            // per window instead of one array write + render pass each.
            bufferRowUpdate(m)
        case .chatUpdated(let c):
            readCommitAction.observe(c.jid, unreadCount: c.unread_count)
            if let i = chats.firstIndex(where: { $0.jid == c.jid }) {
                // Identical row → no state write, no re-render churn. The
                // work/star flags participate: chat.updated is the ONLY
                // echo after "Mark as Work Group"/"Star" actions.
                let cur = chats[i]
                guard cur.display_name != c.display_name
                    || cur.last_message_ts != c.last_message_ts
                    || cur.last_preview != c.last_preview
                    || cur.unread_count != c.unread_count
                    || cur.mentioned_unread != c.mentioned_unread
                    || cur.is_pinned != c.is_pinned
                    || cur.is_muted != c.is_muted
                    || cur.is_starred != c.is_starred
                    || cur.is_work != c.is_work else { break }
                chats[i] = c
            } else {
                chats.insert(c, at: 0)
            }
            mergeLID(c)
            sortChats()
            // Filtered views drop rows that stopped matching (e.g. a chat
            // was just read while the Unread filter is active).
            if chatFilter == "unread" && c.unread_count == 0 {
                chats.removeAll { $0.jid == c.jid }
            } else if chatFilter == "mentions" && c.mentioned_unread == 0 {
                chats.removeAll { $0.jid == c.jid }
            }
        case .chatRemoved(let jid):
            // A chat row folded into another (LID→phone merge) or dropped
            // server-side: purge the stale copy or it shows as a duplicate
            // thread next to its twin.
            let logicalAliases = logicalChatAliases(for: jid)
            tombstoneTextSendOperations(in: logicalAliases)
            chats.removeAll { $0.jid == jid }
            messagesByChat.removeValue(forKey: jid)
            for alias in logicalAliases {
                optimisticRowsByChat.removeValue(forKey: alias)
            }
            protectedOptimisticChatsByTemp = protectedOptimisticChatsByTemp.filter {
                !logicalAliases.contains($0.value)
            }
            provisionalEchoesByTemp = provisionalEchoesByTemp.filter {
                !logicalAliases.contains($0.value.echo.chat_jid)
                    && !logicalAliases.contains($0.value.removedTemp.chat_jid)
            }
            transcriptRetention.remove(jid)
            if selectedChat == jid {
                selectedChat = nil
            }
            enforceTranscriptRetention()
        case .contactsUpdated:
            // A contact name changed server-side (phone contact saved/renamed,
            // push name). Reload the name map now — without this push the
            // transcript kept showing raw phone numbers until the 5-minute
            // timer happened to fire.
            scheduleContactNamesReload()
        case .inboxChanged:
            // Work-inbox membership moved (done/snooze/star/chat flag on the
            // core). Hint only: refetch when the tab is what the user sees.
            if sidebarTab == .inbox {
                scheduleInboxRefresh()
            }
        case .mediaUpdated(let rowID, let chat, let media):
            // The event carries the full media meta — patch the row in place
            // instead of refetching a 50-message page for one row. Same
            // coalescing window as receipts (media progress arrives in bursts).
            if var list = messagesByChat[chat],
               let i = list.firstIndex(where: { $0.id == rowID }) {
                var m = list[i]
                m.media = media
                pendingRowUpdates[m.id] = m
                scheduleRowUpdateFlush()
            }
        case .reaction:
            // Reactions also arrive as message.updated; nothing extra here.
            break
        case .ping:
            break
        }
        if event.affectsDockBadge { updateDockBadge() }
    }

    func handleConnectionState(_ state: String) {
        connectionState = state
        adoptSessionState(state)
        if state == "logged_out" {
            sidecar.handleSleepSignal(.logout)
            screen = .login
            // A stale qrCode would keep LoginView in the QR branch, which
            // has no buttons — the dead code must drop with the session.
            qrCode = nil
            clearSessionData()
        } else if state == "connected", let client = runtimeClient {
            scheduleContactNameRefreshes(for: client)
        }
    }

    // MARK: row-update coalescing (receipts / reactions / edits / media)

    /// Newest full Message per rowid — later events in the window replace
    /// earlier ones, so the flush applies only the final state.
    private var pendingRowUpdates: [Int64: Message] = [:]
    private var rowUpdateFlushTask: Task<Void, Never>?
    /// Receipts/edits are allowed ~120 ms of latency (imperceptible); a
    /// 200-receipt burst then costs ONE array write + render pass instead of
    /// 200. Incoming messages bypass this entirely (apply → upsert directly).
    private var lastRowUpdateFlush: Date?

    private func bufferRowUpdate(_ m: Message) {
        pendingRowUpdates[m.id] = m
        scheduleRowUpdateFlush()
    }

    /// Leading-edge flush when idle (first event applies fast), trailing
    /// window while bursts continue — same shape as scheduleSyncDrivenRefresh.
    private func scheduleRowUpdateFlush() {
        rowUpdateFlushTask?.cancel()
        rowUpdateFlushTask = Task { @MainActor in
            if let last = lastRowUpdateFlush {
                let wait = 0.12 - Date().timeIntervalSince(last)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            guard !Task.isCancelled else { return }
            flushRowUpdates()
        }
    }

    private func flushRowUpdates() {
        guard !pendingRowUpdates.isEmpty else { return }
        let updates = pendingRowUpdates
        pendingRowUpdates = [:]
        lastRowUpdateFlush = Date()
        // One array rebuild + ONE publish per chat per window — a 200-receipt
        // burst lands as a single state write, not two hundred.
        var byChat: [String: [Int64: Message]] = [:]
        for m in updates.values {
            byChat[m.chat_jid, default: [:]][m.id] = m
        }
        for (chat, rows) in byChat {
            guard var list = messagesByChat[chat] else { continue }
            for (rowID, m) in rows {
                if let i = list.firstIndex(where: { $0.id == rowID }) {
                    if list[i] == m { continue } // unchanged row: no invalidation churn
                    list[i] = m
                } else {
                    list.append(m)
                    MessageTimelineOrder.sort(&list)
                }
            }
            messagesByChat[chat] = trimmedTranscript(list, for: chat)
        }
    }

    /// Coalesced chat refresh for sync progress: at most one /chats round
    /// trip per second, trailing edge — the final "done" always refreshes.
    private func scheduleSyncDrivenRefresh() {
        syncRefreshTask?.cancel()
        syncRefreshTask = Task { @MainActor in
            if let last = lastSyncDrivenRefresh {
                let wait = 1.0 - Date().timeIntervalSince(last)
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            guard !Task.isCancelled else { return }
            lastSyncDrivenRefresh = Date()
            await refreshChats(source: .sync)
        }
    }

    private enum UpsertResult {
        case inserted
        case updated
        case ignored
    }

    @discardableResult
    private func upsert(_ m: Message, in chat: String, allowCreate: Bool = false) -> UpsertResult {
        guard messagesByChat[chat] != nil || chat == selectedChat || m.id < 0 || allowCreate else {
            return .ignored
        }
        let createsTranscript = messagesByChat[chat] == nil
        var list = messagesByChat[chat] ?? []
        let result: UpsertResult
        if let i = list.firstIndex(where: { $0.id == m.id }) {
            if list[i] == m { return .ignored } // unchanged row: no invalidation churn
            list[i] = m
            result = .updated
        } else if m.id > 0,
                  list.contains(where: { sameDurableIdentity($0, m) }) {
            // A duplicate durable echo can carry a repeated protocol ID even
            // when its row ID differs. Keep the already-authoritative row and
            // never append a second copy.
            return .ignored
        } else {
            list.append(m)
            MessageTimelineOrder.sort(&list)
            result = .inserted
        }
        messagesByChat[chat] = trimmedTranscript(list, for: chat)
        if createsTranscript { touchTranscript(chat) }
        return result
    }

    /// Core normalizes learned PN/LID sender twins before rows reach Swift.
    /// Within that canonical stream, incoming group senders remain distinct;
    /// `from_me` is authoritative for our own multi-device sender variants.
    private func sameDurableIdentity(_ lhs: Message, _ rhs: Message) -> Bool {
        guard lhs.id > 0, rhs.id > 0,
              lhs.chat_jid == rhs.chat_jid,
              !lhs.message_id.isEmpty,
              lhs.message_id == rhs.message_id else { return false }
        if lhs.from_me || rhs.from_me {
            return lhs.from_me && rhs.from_me
        }
        return lhs.sender_jid == rhs.sender_jid
    }

    private func trimmedTranscript(_ rows: [Message], for chat: String) -> [Message] {
        guard chat != selectedChat, rows.count > 300 else { return rows }
        return TranscriptWindowPolicy.retained(rows)
    }

    private func touchTranscript(_ chat: String) {
        transcriptRetention.touch(chat)
        enforceTranscriptRetention()
    }

    private func enforceTranscriptRetention() {
        let protected = Set(optimisticRowsByChat.compactMap { chat, count in
            count > 0 ? chat : nil
        })
        let victims = transcriptRetention.evictionCandidates(
            loaded: Set(messagesByChat.keys),
            active: selectedChat,
            protected: protected
        )
        guard !victims.isEmpty else { return }
        var retained = messagesByChat
        for victim in victims {
            retained.removeValue(forKey: victim)
        }
        messagesByChat = retained
        let victimSet = Set(victims)
        provisionalEchoesByTemp = provisionalEchoesByTemp.filter {
            !victimSet.contains($0.value.echo.chat_jid)
        }
    }

    private func beginOptimisticProtection(for temp: Message) {
        guard temp.id < 0,
              protectedOptimisticChatsByTemp.updateValue(temp.chat_jid, forKey: temp.id) == nil
        else { return }
        let chat = temp.chat_jid
        optimisticRowsByChat[chat, default: 0] += 1
        if messagesByChat[chat] != nil {
            touchTranscript(chat)
        } else {
            enforceTranscriptRetention()
        }
    }

    @discardableResult
    private func finishOptimisticProtection(forTempID tempID: Int64) -> Bool {
        guard let chat = protectedOptimisticChatsByTemp.removeValue(forKey: tempID),
              let count = optimisticRowsByChat[chat] else { return false }
        if count > 1 {
            optimisticRowsByChat[chat] = count - 1
        } else {
            optimisticRowsByChat.removeValue(forKey: chat)
        }
        return true
    }

    /// Direct-chat payloads expose the canonical phone JID plus its LID twin.
    /// A removal for either spelling tombstones operations for the same
    /// logical chat without deleting the canonical twin's durable history.
    private func logicalChatAliases(for chat: String) -> Set<String> {
        var aliases: Set<String> = [chat]
        if let lid = knownChatLIDs[chat] {
            aliases.insert(lid)
        }
        for (phone, lid) in knownChatLIDs where lid == chat {
            aliases.insert(phone)
        }
        return aliases
    }

    /// Remove only operations that were live when the authoritative removal
    /// arrived. Temporary IDs never repeat during this AppState lifetime, so
    /// a late continuation cannot touch a newer send in the same chat.
    private func tombstoneTextSendOperations(in chats: Set<String>) {
        let tempIDs = Set(activeTextOperationChatsByTemp.compactMap { tempID, chat in
            chats.contains(chat) ? tempID : nil
        }).union(protectedOptimisticChatsByTemp.compactMap { tempID, chat in
            chats.contains(chat) ? tempID : nil
        })
        guard !tempIDs.isEmpty else { return }

        activeTextOperationChatsByTemp = activeTextOperationChatsByTemp.filter {
            !tempIDs.contains($0.key)
        }
        wireTextByTemp = wireTextByTemp.filter { !tempIDs.contains($0.key) }
        var retained = messagesByChat
        var removedRows = false
        for chat in chats where retained[chat] != nil {
            let rows = retained[chat] ?? []
            let withoutTombstoned = rows.filter { !tempIDs.contains($0.id) }
            guard withoutTombstoned.count != rows.count else { continue }
            retained[chat] = trimmedTranscript(withoutTombstoned, for: chat)
            removedRows = true
        }
        if removedRows { messagesByChat = retained }
        for tempID in tempIDs {
            performanceSignposts.cancelVisibleRow(rowID: tempID)
            _ = finishOptimisticProtection(forTempID: tempID)
        }
        provisionalEchoesByTemp = provisionalEchoesByTemp.filter {
            !tempIDs.contains($0.key)
                && !chats.contains($0.value.echo.chat_jid)
                && !chats.contains($0.value.removedTemp.chat_jid)
        }
        enforceTranscriptRetention()
    }

    /// Invalidates every continuation owned by the previous runtime/session.
    /// Temporary IDs are monotonic for the AppState lifetime, so removing only
    /// negative rows cannot collide with a later account's sends.
    private func invalidateTextSendOperations(removeRows: Bool = true) {
        textSendGeneration &+= 1
        let instrumentedTempIDs = Set(activeTextOperationChatsByTemp.keys)
            .union(protectedOptimisticChatsByTemp.keys)
            .union(provisionalEchoesByTemp.keys)
        for tempID in instrumentedTempIDs {
            performanceSignposts.cancelVisibleRow(rowID: tempID)
        }
        let hadOwnership = !activeTextOperationChatsByTemp.isEmpty
            || !protectedOptimisticChatsByTemp.isEmpty
            || !provisionalEchoesByTemp.isEmpty
        var removedRows = false
        if removeRows {
            var retained = messagesByChat
            for (chat, rows) in messagesByChat {
                let withoutOptimistic = rows.filter { $0.id >= 0 }
                guard withoutOptimistic.count != rows.count else { continue }
                retained[chat] = trimmedTranscript(withoutOptimistic, for: chat)
                removedRows = true
            }
            if removedRows { messagesByChat = retained }
        }
        optimisticRowsByChat = [:]
        activeTextOperationChatsByTemp = [:]
        wireTextByTemp = [:]
        protectedOptimisticChatsByTemp = [:]
        provisionalEchoesByTemp = [:]
        if removeRows && (removedRows || hadOwnership) {
            enforceTranscriptRetention()
        }
    }

    private func claimTextSendOperation(_ temp: Message, generation: UInt64,
                                        client: AppRuntimeClient) -> Bool {
        guard !Task.isCancelled,
              textSendGeneration == generation,
              runtimeClient === client,
              connectionRefresh.isCurrent(client),
              activeTextOperationChatsByTemp[temp.id] == temp.chat_jid
        else { return false }
        activeTextOperationChatsByTemp.removeValue(forKey: temp.id)
        wireTextByTemp.removeValue(forKey: temp.id)
        return true
    }

    /// A cancelled/stale continuation may remove only its exact monotonic temp
    /// and ownership bookkeeping. It never publishes its result, changes a
    /// chat preview, or surfaces a toast into the current session.
    private func discardTextSend(_ temp: Message) {
        performanceSignposts.cancelVisibleRow(rowID: temp.id)
        var changed = activeTextOperationChatsByTemp.removeValue(forKey: temp.id) != nil
        if wireTextByTemp.removeValue(forKey: temp.id) != nil { changed = true }
        if provisionalEchoesByTemp.removeValue(forKey: temp.id) != nil { changed = true }
        if var list = messagesByChat[temp.chat_jid] {
            let originalCount = list.count
            list.removeAll { $0.id == temp.id }
            if list.count != originalCount {
                messagesByChat[temp.chat_jid] = trimmedTranscript(list, for: temp.chat_jid)
                changed = true
            }
        }
        if finishOptimisticProtection(forTempID: temp.id) { changed = true }
        guard changed else { return }
        pruneFinalizedProvisionalEchoes(in: temp.chat_jid)
        enforceTranscriptRetention()
    }

    /// Merges a fetched page into a chat without dropping rows that arrived
    /// via WS (or optimistic sends) while the fetch was in flight: keep the
    /// fetched rows plus any local-only newer/temp rows.
    private func mergeMessages(_ page: [Message], into chat: String) {
        let existing = messagesByChat[chat] ?? []
        let pageIDs = Set(page.map(\.id))
        let newest = page.max(by: MessageTimelineOrder.precedes)
        let extras = existing.filter { row in
            row.id < 0 || (!pageIDs.contains(row.id)
                && (newest.map { MessageTimelineOrder.precedes($0, row) } ?? true))
        }
        var merged = page + extras
        MessageTimelineOrder.sort(&merged)
        messagesByChat[chat] = trimmedTranscript(merged, for: chat)
        touchTranscript(chat)
    }

    /// A WS echo of an own message proves the send (or a timed-out one)
    /// actually landed: drop the matching optimistic temp row so a failed
    /// HTTP response can't leave a duplicate "✗" bubble (and a retry that
    /// would double-send). Matches on chat + text (the echo's message_id is
    /// unknowable client-side before the ack).
    private func reconcileTempIfEcho(_ m: Message) {
        guard m.from_me, m.id > 0, var list = messagesByChat[m.chat_jid] else { return }
        let durableAlreadyPresent = list.contains {
            $0.id > 0 && ($0.id == m.id || sameDurableIdentity($0, m))
        }
        guard !durableAlreadyPresent else { return }

        guard consumeTempCandidate(for: m, from: &list) else { return }
        messagesByChat[m.chat_jid] = trimmedTranscript(list, for: m.chat_jid)
        pruneFinalizedProvisionalEchoes(in: m.chat_jid)
        enforceTranscriptRetention()
    }

    /// Removes one deterministic candidate for an echo. Evidence is needed
    /// whenever at least one same-text candidate remains and any candidate in
    /// that ambiguous set still has an HTTP callback capable of identifying
    /// the exact durable owner. Otherwise the chosen assignment is final.
    @discardableResult
    private func consumeTempCandidate(for echo: Message, from list: inout [Message]) -> Bool {
        guard let index = tempCandidateIndex(in: list, text: echo.text) else { return false }
        let temp = list.remove(at: index)
        performanceSignposts.cancelVisibleRow(rowID: temp.id)
        let tempIsActive = activeTextOperationChatsByTemp[temp.id] == temp.chat_jid
        // Removed provisional owners are still same-signature candidates.
        // Ignoring them makes a crossed echo irreversible before an exact
        // HTTP result can identify which failed sibling actually landed.
        let provisionalSiblings = provisionalEchoesByTemp.values.filter {
            $0.removedTemp.chat_jid == temp.chat_jid
                && ($0.removedTemp.text == echo.text
                    || wireTextByTemp[$0.removedTemp.id] == echo.text)
        }
        let hasSibling = list.contains {
            $0.id < 0 && ($0.text == echo.text || wireTextByTemp[$0.id] == echo.text)
        } || !provisionalSiblings.isEmpty
        let hasActiveSibling = provisionalSiblings.contains {
            activeTextOperationChatsByTemp[$0.removedTemp.id] == $0.removedTemp.chat_jid
        } || list.contains {
            $0.id < 0 && ($0.text == echo.text || wireTextByTemp[$0.id] == echo.text)
                && activeTextOperationChatsByTemp[$0.id] == $0.chat_jid
        }
        if hasSibling && (tempIsActive || hasActiveSibling) {
            provisionalEchoesByTemp[temp.id] = ProvisionalEchoOwnership(
                echo: echo,
                removedTemp: temp
            )
        } else {
            _ = finishOptimisticProtection(forTempID: temp.id)
        }
        return true
    }

    /// Failed-candidate evidence remains useful only while a same-text HTTP
    /// callback is outstanding. Build the active-text set once so pruning is
    /// stable O(n), including active temps currently represented by evidence
    /// rather than a transcript row.
    private func pruneFinalizedProvisionalEchoes(in chat: String) {
        guard let rows = messagesByChat[chat] else {
            provisionalEchoesByTemp = provisionalEchoesByTemp.filter {
                $0.value.echo.chat_jid != chat
            }
            return
        }
        var activeTexts = Set<String?>()
        for row in rows
            where row.id < 0 && activeTextOperationChatsByTemp[row.id] == row.chat_jid {
            activeTexts.insert(row.text)
            if let wire = wireTextByTemp[row.id] { activeTexts.insert(wire) }
        }
        for (tempID, ownership) in provisionalEchoesByTemp
            where ownership.echo.chat_jid == chat
                && activeTextOperationChatsByTemp[tempID] == ownership.removedTemp.chat_jid {
            activeTexts.insert(ownership.removedTemp.text)
            if let wire = wireTextByTemp[tempID] { activeTexts.insert(wire) }
        }
        let finalized = provisionalEchoesByTemp.compactMap { tempID, ownership in
            ownership.echo.chat_jid == chat && !activeTexts.contains(ownership.echo.text) ? tempID : nil
        }
        for tempID in finalized {
            provisionalEchoesByTemp.removeValue(forKey: tempID)
            _ = finishOptimisticProtection(forTempID: tempID)
        }
    }

    /// Terminal/failed rows win over active operations. Within either class the
    /// maximum negative ID is the oldest send because IDs monotonically
    /// decrease (-1, -2, ...). The scan is linear in the bounded transcript.
    private func tempCandidateIndex(in list: [Message], text: String?) -> Int? {
        var oldestTerminal: Int?
        var oldestActive: Int?
        for index in list.indices where list[index].id < 0 {
            let row = list[index]
            // Mention sends echo in wire form ("@<digits>") while the temp
            // row shows the display label — match either via the wire
            // snapshot taken at send time.
            guard row.text == text || wireTextByTemp[row.id] == text else { continue }
            let target = activeTextOperationChatsByTemp[row.id] == nil
                ? oldestTerminal
                : oldestActive
            if let target {
                if row.id <= list[target].id { continue }
            }
            if activeTextOperationChatsByTemp[row.id] == nil {
                oldestTerminal = index
            } else {
                oldestActive = index
            }
        }
        return oldestTerminal ?? oldestActive
    }

    private var refreshScheduled = false

    // MARK: chat ordering

    /// Recency ordering: newest last message first (jid DESC breaks
    /// timestamps shared by many chats, matching the server's keyset
    /// cursor). Focus Mode hoists work contacts and work groups above
    /// everything else; both buckets keep the same recency order inside.
    private func sortChats() {
        chats.sort { a, b in
            if focusMode {
                let aWork = (a.is_work ?? false) || (a.is_starred ?? false)
                let bWork = (b.is_work ?? false) || (b.is_starred ?? false)
                if aWork != bWork { return aWork }
            }
            let at = a.last_message_ts ?? 0
            let bt = b.last_message_ts ?? 0
            return at > bt || (at == bt && a.jid > b.jid)
        }
    }

    /// Toggling Focus Mode re-ranks the sidebar (work chats jump to the
    /// top or drop back into recency order) and recomputes the badge,
    /// which counts only work chats while it is on.
    func toggleFocusMode() {
        focusMode.toggle()
        sortChats()
        updateDockBadge()
    }

    /// Whether a live message may keep/insert its chat row under the active
    /// filter (filtered views only show matching chats).
    private func passesChatFilter(_ m: Message) -> Bool {
        switch chatFilter {
        case "unread": return !m.from_me
        case "mentions": return m.has_mention && !m.from_me
        default: return true
        }
    }

    private func bumpChat(with m: Message) {
        if let i = chats.firstIndex(where: { $0.jid == m.chat_jid }) {
            if chats[i].lid == nil, let lid = knownChatLIDs[m.chat_jid] {
                chats[i].lid = lid
            }
            chats[i].last_message_ts = m.timestamp
            chats[i].last_preview = m.text ?? (m.media?.kind.capitalized ?? "")
        } else if passesChatFilter(m) {
            if let known = serverChats[m.chat_jid] {
                // Known to the server but not in the visible window yet.
                var c = known
                c.last_message_ts = m.timestamp
                c.last_preview = m.text ?? (m.media?.kind.capitalized ?? "")
                chats.insert(c, at: 0)
            } else {
                // Truly unseen chat: minimal row + fetch the authoritative one.
                chats.insert(Chat(jid: m.chat_jid,
                                  kind: m.chat_jid.hasSuffix("@g.us") ? "group" : "direct",
                                  display_name: m.chat_jid, last_message_ts: m.timestamp,
                                  last_preview: m.text ?? (m.media?.kind.capitalized ?? ""),
                                  unread_count: 1, mentioned_unread: 0,
                                  is_pinned: false, is_muted: false), at: 0)
                scheduleServerRefresh()
            }
        }
        sortChats()
    }

    /// Known @lid twin per chat jid. Server stamps it on chat payloads when
    /// the lid map knows it; the cache keeps the last known value so a
    /// payload that momentarily lacks it (event before map learn) doesn't
    /// make the header identifier flicker away.
    private var knownChatLIDs: [String: String] = [:]

    private func mergeLID(_ c: Chat) {
        if let lid = c.lid, !lid.isEmpty, lid != c.jid {
            knownChatLIDs[c.jid] = lid
        }
    }

    func lid(forChat jid: String) -> String? { knownChatLIDs[jid] }

    /// Last full chat list from the server — name source for unseen chats.
    /// Plain var: no view observes it; publishing it invalidated the whole
    /// tree on every refresh for nothing.
    private(set) var serverChats: [String: Chat] = [:]

    private func scheduleServerRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            refreshScheduled = false
            guard !Task.isCancelled else { return }
            await refreshChats(source: .server)
        }
    }

    // MARK: actions

    func startLogin() async {
        guard let client = runtimeClient else { return }
        await startLogin(client)
    }

    private func startLogin(_ client: AppRuntimeClient) async {
        guard isCurrentRefreshClient(client) else { return }
        do {
            try await client.startLink()
            guard isCurrentRefreshClient(client) else { return }
            connectionState = "linking"
        } catch {
            guard isCurrentRefreshClient(client) else { return }
            toast = error.localizedDescription
        }
    }

    /// Paired-session states mean the main UI is valid — transition from
    /// the login screen no matter which path learned the state (REST poll
    /// or WS event). Without this a failed first /session left the app on
    /// "Connecting…" forever.
    private func adoptSessionState(_ state: String) {
        if state == "connected" || state == "connecting" || state == "offline" {
            if screen == .login { screen = .main }
            if qrCode != nil { qrCode = nil }
        }
    }

    /// Drops all account-scoped state. Logout wipes the core DB — ids never
    /// repeat (AUTOINCREMENT), but every id-keyed cache must still go or a
    /// stale entry surfaces the PREVIOUS account's content after re-link.
    private func clearSessionData() {
        performanceSignposts.clearPending()
        activeChatSwitchMeasurement = nil
        readyChatSwitchMeasurement = nil
        invalidateAttachmentOperations()
        invalidateTextSendOperations(removeRows: false)
        connectionRefresh.cancelWorkKeepingClient()
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        contactNamesReloadTask?.cancel()
        contactNamesReloadTask = nil
        lastWSActivityAt = nil
        chats = []
        messagesByChat = [:]
        transcriptRetention.reset()
        optimisticRowsByChat = [:]
        protectedOptimisticChatsByTemp = [:]
        provisionalEchoesByTemp = [:]
        selectedChat = nil
        lastOpenedChat = nil
        mediaImages = [:]
        mediaImageBytes = [:]
        mediaBusy = []
        chatMembers = [:]
        chatMembersFetchedAt = [:]
        contactNames = [:]
        // The core DB is wiped on logout; ids never repeat (AUTOINCREMENT),
        // but cached attributed strings keyed by id|text|version would
        // still collide with the next account's fresh ids — invalidate now,
        // not on the first /contacts load.
        contactNamesVersion += 1
        previewImage = nil
        pendingPasteImage = nil
        mentionTargets = [:]
        chatsNextCursor = nil
        serverChats = [:]
        inbox = nil
        notificationChats = [:]
        lastContactsLoad = nil
        syncProgress = nil
        unreadBoundaries = [:]
        readCommitAction = ReadCommitAction()
        previewLoadCoordinator = PreviewLoadCoordinator()
        draftStore = [:]
        mentionTargetStore = [:]
        mentionGenerations = ChatMentionGenerationStore()
        replyStore.clear()
        pendingRowUpdates = [:]
        rowUpdateFlushTask?.cancel()
        rowUpdateFlushTask = nil
        updateDockBadge()
    }

    @discardableResult
    func refreshSession(includeChats: Bool = true) async -> Bool {
        guard let client = runtimeClient else { return false }
        return await refreshSession(client, includeChats: includeChats, chatSource: .session)
    }

    @discardableResult
    private func refreshSession(_ client: AppRuntimeClient,
                                includeChats: Bool,
                                chatSource: ChatRefreshSource = .session) async -> Bool {
        guard isCurrentRefreshClient(client) else { return false }
        guard let s = try? await client.sessionInfo(), isCurrentRefreshClient(client) else { return false }

        connectionState = s.state
        if s.state == "logged_out" {
            sidecar.handleSleepSignal(.logout)
        } else if s.qr != nil {
            sidecar.handleSleepSignal(.qr)
        } else if let sync = s.sync {
            sidecar.handleSleepSignal(.syncProgress(stage: sync.stage))
        }
        if let acc = s.account { ownJIDValue = acc }
        adoptSessionState(s.state)
        if s.state == "connected" { scheduleContactNameRefreshes(for: client) }
        if includeChats && (s.state == "connected" || s.state == "connecting" || s.state == "offline") {
            let result = await refreshChats(
                client,
                filter: chatFilter,
                source: chatSource
            )
            return result == .succeeded || result == .queued
        } else if let qr = s.qr {
            qrCode = qr.code
        }
        return true
    }

    @discardableResult
    func refreshChats() async -> Bool {
        await refreshChats(source: .chats)
    }

    @discardableResult
    private func refreshChats(source: ChatRefreshSource) async -> Bool {
        guard let client = runtimeClient else { return false }
        let result = await refreshChats(client, filter: chatFilter, source: source)
        return result == .succeeded || result == .queued
    }

    @discardableResult
    private func refreshChats(_ client: AppRuntimeClient,
                              filter: String,
                              source: ChatRefreshSource,
                              authoritativeEpoch: ConnectionRefreshEpoch? = nil) async -> ChatRefreshResult {
        await connectionRefresh.runChat(
            client: client,
            filter: filter,
            source: source,
            authoritativeEpoch: authoritativeEpoch
        ) { [weak self] capturedClient, lease in
            guard let self, self.isCurrentRefreshClient(capturedClient) else { return .cancelled }
            let syncRefresh = lease.source == .sync
                ? self.performanceSignposts.beginSyncRefresh()
                : nil
            var syncOutcome = PerformanceSignpostLifecycle.Outcome.cancelled
            defer {
                if lease.source == .sync {
                    self.performanceSignposts.endSyncRefresh(syncRefresh, outcome: syncOutcome)
                }
            }
            do {
                let response = try await capturedClient.chats(filter: lease.filter)
                guard self.connectionRefresh.accepts(lease, for: capturedClient),
                      self.isCurrentRefreshClient(capturedClient) else { return .cancelled }
                self.applyChatsResponse(response, requestFilter: lease.filter)
                self.updateDockBadge()
                syncOutcome = .completed
                return .succeeded
            } catch {
                guard self.connectionRefresh.accepts(lease, for: capturedClient),
                      self.isCurrentRefreshClient(capturedClient) else { return .cancelled }
                syncOutcome = Task.isCancelled ? .cancelled : .failed
                return .failed
            }
        }
    }

    private func applyChatsResponse(_ response: ChatsResponse, requestFilter: String, page: Bool = false) {
            for c in response.chats {
                mergeLID(c)
                readCommitAction.observe(c.jid, unreadCount: c.unread_count)
            }
            if requestFilter == "all" {
                if page {
                    // Continuation page: extend the server-authoritative
                    // map, never shrink it back to just this page.
                    for c in response.chats { serverChats[c.jid] = c }
                } else {
                    serverChats = Dictionary(uniqueKeysWithValues: response.chats.map { ($0.jid, $0) })
                }
                chatsNextCursor = response.next_cursor
            } else {
                chatsNextCursor = nil
            }
            // A response remains valid for its captured request, but only the
            // matching visible filter may consume it. The coordinator starts
            // one latest-filter trailing request when these differ.
            guard chatFilter == requestFilter else { return }
            chatsLoaded = true
            if requestFilter == "all" {
                // Merge: the server page wins, except for local rows that are
                // newer (a message landed while the fetch was in flight) or
                // absent from the page but known locally.
                var byJID = Dictionary(uniqueKeysWithValues: response.chats.map { ($0.jid, $0) })
                for local in chats {
                    if let server = byJID[local.jid] {
                        let localTS = local.last_message_ts ?? 0
                        let serverTS = server.last_message_ts ?? 0
                        if localTS > serverTS || local.unread_count > server.unread_count {
                            byJID[local.jid] = local
                        }
                    } else {
                        byJID[local.jid] = local
                    }
                }
                chats = Array(byJID.values)
            } else {
                // Filtered views (unread/mentions) are server-authoritative:
                // merging local extras would resurrect chats the filter
                // just excluded.
                chats = response.chats
            }
            sortChats()
    }

    /// Contact names power transcript sender labels (server-side resolution
    /// handles chat titles; bubbles resolve locally).
    /// Contact names power transcript sender labels (server-side resolution
    /// handles chat titles; bubbles resolve locally). version bumps on every
    /// reload so mention-label caches can invalidate.
    private(set) var contactNamesVersion = 0

    /// Keyset continuation for the chat list (nil = all chats loaded).
    @Published private(set) var chatsNextCursor: String?
    private var loadingMoreChats = false

    /// Fetches the next chat-list page when the sidebar reaches the end of
    /// the loaded window — accounts with more chats than one page would
    /// otherwise be unreachable from the sidebar (search excepted).
    func loadMoreChats() async {
        guard chatFilter == "all", let cursor = chatsNextCursor,
              let api, let captured = runtimeClient, !loadingMoreChats else { return }
        loadingMoreChats = true
        defer { loadingMoreChats = false }
        if let response = try? await api.chats(limit: 199, cursor: cursor, filter: "all") {
            guard isCurrentRefreshClient(captured) else { return }
            applyChatsResponse(response, requestFilter: "all", page: true)
        }
    }

    func loadContacts(force: Bool = false) async {
        guard let client = runtimeClient else { return }
        await loadContacts(client, force: force)
    }

    private func loadContacts(_ client: AppRuntimeClient, force: Bool = false) async {
        guard isCurrentRefreshClient(client) else { return }
        if !force, let last = lastContactsLoad, Date().timeIntervalSince(last) < 300 { return }
        if let list = try? await client.contacts(), isCurrentRefreshClient(client) {
            var map: [String: String] = [:]
            for c in list {
                let name = [c.full_name, c.push_name, c.business_name]
                    .compactMap { $0 }.first { !$0.isEmpty }
                if let name { map[c.jid] = name }
            }
            contactNames = map
            contactNamesVersion += 1
            lastContactsLoad = Date()
        }
    }

    /// The phone's address book (contact-list app state) can land after the
    /// initial load. Two forced follow-ups cover that sync window.
    /// Debounced forced name-map reload for contacts.updated events (they
    /// can arrive in bursts while app-state sync replays).
    private var contactNamesReloadTask: Task<Void, Never>?

    private func scheduleContactNamesReload() {
        contactNamesReloadTask?.cancel()
        guard let client = runtimeClient else { return }
        contactNamesReloadTask = Task { [weak self, weak client] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let client,
                  self.connectionState == "connected",
                  self.isCurrentRefreshClient(client) else { return }
            await self.loadContacts(client, force: true)
        }
    }

    private func scheduleContactNameRefreshes(for client: AppRuntimeClient) {
        guard connectionState == "connected", isCurrentRefreshClient(client) else { return }
        connectionRefresh.activateContactsIfNeeded(for: client, isConnected: connectionState == "connected") { [weak self] capturedClient in
            guard let self, self.connectionState == "connected",
                  self.isCurrentRefreshClient(capturedClient) else { return }
            await self.loadContacts(capturedClient, force: true)
        }
    }

    func nameFor(_ jid: String) -> String {
        if let n = contactNames[jid], !n.isEmpty { return n }
        return Self.prettyJID(jid)
    }

    // MARK: bare mention-token resolution (previews / quotes / notifications)

    /// Group mention texts arrive with raw numeric tokens ("@66061428912159")
    /// while the transcript resolves them through the message's
    /// mentioned_jids. Chat-list previews, quoted lines and notifications
    /// carry ONLY the raw text — this resolver maps the number back to the
    /// contact name via a user-part → name index built from the contact
    /// directory (rebuilt only when contacts reload).
    private static let bareMentionRE = try? NSRegularExpression(pattern: "@([0-9]{7,20})")

    private var userPartNamesCache: [String: String] = [:]
    private var userPartNamesBuiltAt = -1

    private var userPartNames: [String: String] {
        if userPartNamesBuiltAt == contactNamesVersion {
            return userPartNamesCache
        }
        var map: [String: String] = [:]
        for (jid, name) in contactNames {
            // Skip fallback labels ("+62…", "•••1234") — mapping a raw
            // number to another raw number helps nobody.
            guard !name.isEmpty, !name.hasPrefix("+"), !name.hasPrefix("•••"),
                  name != "WhatsApp" else { continue }
            map[String(jid.prefix(while: { $0 != "@" }))] = name
        }
        userPartNamesCache = map
        userPartNamesBuiltAt = contactNamesVersion
        return map
    }

    /// Replaces "@<number>" tokens with "@Name" where the contact directory
    /// knows the number. Tokens that stay unknown are left untouched.
    func resolveBareMentionTokens(in text: String) -> String {
        guard let re = Self.bareMentionRE, text.contains("@") else { return text }
        let names = userPartNames
        guard !names.isEmpty else { return text }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        var replaced = false
        for m in matches {
            let start = m.range.location + 1
            let user = ns.substring(with: NSRange(location: start, length: m.range.length - 1))
            guard let name = names[user] else { continue }
            if m.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            }
            result += "@" + name
            cursor = m.range.location + m.range.length
            replaced = true
        }
        guard replaced else { return text }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }

    /// Human fallback for JIDs without a stored name: never surfaces raw
    /// identifiers like "97260054569119:7@lid" or "0@s.whatsapp.net".
    static func prettyJID(_ jid: String) -> String {
        if jid.hasPrefix("0@") { return "WhatsApp" }
        var user = jid.prefix(while: { $0 != "@" })
        if let c = user.lastIndex(where: { $0 == ":" }) { user = user[user.startIndex..<c] }
        let isLID = jid.hasSuffix("@lid")
        if isLID && user.count > 4 { return "•••" + user.suffix(4) }
        return "+" + user
    }

    /// Chat whose state (media cache, mentions) the per-chat stores currently
    /// reflect. selectedChat is written by the List binding before previewChat()
    /// runs, so cleanup must compare against this, not selectedChat.
    private var lastOpenedChat: String?
    private var readCommitAction = ReadCommitAction()
    private var previewLoadCoordinator = PreviewLoadCoordinator()

    private func cancelChatSwitchMeasurement(for chatKey: String) {
        if let active = activeChatSwitchMeasurement, active.chatKey == chatKey {
            performanceSignposts.endChatSwitch(
                chatKey: chatKey,
                operation: active.operation,
                outcome: .cancelled
            )
            activeChatSwitchMeasurement = nil
        }
        if let ready = readyChatSwitchMeasurement,
           ready.measurement.chatKey == chatKey {
            performanceSignposts.endChatSwitch(
                chatKey: chatKey,
                operation: ready.measurement.operation,
                outcome: .cancelled
            )
            readyChatSwitchMeasurement = nil
        }
    }

    private func finishChatSwitchFetch(
        _ measurement: ChatSwitchMeasurement?,
        outcome: PerformanceSignpostLifecycle.Outcome
    ) {
        guard let measurement else { return }
        switch outcome {
        case .completed:
            guard activeChatSwitchMeasurement?.operation == measurement.operation else { return }
            selectedMessagePageRenderVersion &+= 1
            readyChatSwitchMeasurement = ReadyChatSwitchMeasurement(
                measurement: measurement,
                renderVersion: selectedMessagePageRenderVersion
            )
        case .cancelled, .failed:
            performanceSignposts.endChatSwitch(
                chatKey: measurement.chatKey,
                operation: measurement.operation,
                outcome: outcome
            )
            if activeChatSwitchMeasurement?.operation == measurement.operation {
                activeChatSwitchMeasurement = nil
            }
            if readyChatSwitchMeasurement?.measurement.operation == measurement.operation {
                readyChatSwitchMeasurement = nil
            }
        }
    }

    /// Called after the page-arrival publication reaches MessageList and its
    /// queued main-run-loop callback. This is a view-update scheduling proxy,
    /// not evidence that Core Animation presented a frame.
    func selectedMessagePageDidReachViewUpdateProxy(
        chatJID: String,
        renderVersion: UInt64
    ) {
        guard let ready = readyChatSwitchMeasurement,
              ready.measurement.chatKey == chatJID,
              ready.renderVersion == renderVersion,
              selectedChat == chatJID else { return }
        performanceSignposts.endChatSwitch(
            chatKey: chatJID,
            operation: ready.measurement.operation,
            outcome: .completed
        )
        if activeChatSwitchMeasurement?.operation == ready.measurement.operation {
            activeChatSwitchMeasurement = nil
        }
        readyChatSwitchMeasurement = nil
    }

    /// Chat-list scheduling proxy used for signpost correlation. Instruments
    /// owns the actual first-presented-frame measurement.
    func loadedChatListDidReachRunLoopProxy() {
        performanceSignposts.endLaunchAtLoadedChatListRunLoopProxy()
    }

    /// SwiftUI onAppear proxy for row scheduling; no frame-presentation claim.
    func messageRowDidAppearProxy(rowID: Int64) {
        performanceSignposts.endVisibleRow(rowID: rowID)
    }

    private func switchOpenedChat(to chat: String) {
        if lastOpenedChat != chat {
            mediaImages.removeAll(keepingCapacity: false) // bound decoded-image RAM per chat
            mediaImageBytes.removeAll()
            // Drafts and mention targets swap per chat (returning restores).
            if let prev = lastOpenedChat {
                mentionTargetStore[prev] = mentionTargets
                if let rows = messagesByChat[prev], rows.count > 300 {
                    messagesByChat[prev] = TranscriptWindowPolicy.retained(rows)
                }
            }
            mentionTargets = mentionTargetStore[chat] ?? [:]
            lastOpenedChat = chat
        }
    }

    func previewChat(_ chat: String, anchorMessageID: String? = nil) async {
        let request = previewLoadCoordinator.request(
            chatJID: chat,
            anchorMessageID: anchorMessageID
        )
        if let anchorMessageID = request.anchorMessageID {
            pendingAnchor = PendingAnchor(chatJID: chat, messageID: anchorMessageID)
        } else if pendingAnchor?.chatJID != chat {
            pendingAnchor = nil
        }
        switchOpenedChat(to: chat)
        selectedChat = chat
        await loadPreview(request)
    }

    /// The List binding owns selection changes. Its observer only asks for a
    /// page for the still-selected chat, so delayed selection work cannot
    /// overwrite a newer selection or discard an explicit anchor.
    func loadSelectedChat(_ chat: String) async {
        guard selectedChat == chat else { return }
        switchOpenedChat(to: chat)
        guard let request = previewLoadCoordinator.selectionRequest(chatJID: chat) else { return }
        await loadPreview(request)
    }

    /// Row click drives selection AND recovers an empty transcript. Two gaps
    /// force this: an AppKit gesture race can drop the List binding's
    /// selection write (the tap then must restore it or the transcript never
    /// switches), and a tap on the already-selected chat fires no selection
    /// change, so a dropped or failed page load would otherwise leave an
    /// empty transcript with no same-row recovery. A populated transcript
    /// skips the fetch — one physical click must not double-load — and the
    /// PreviewLoadCoordinator coalesces the tap-driven load against the
    /// selection observer's still-running task.
    func openChatRow(_ chat: String, source: ChatOpenSource) async {
        if selectedChat != chat {
            selectedChat = chat
        }
        if (messagesByChat[chat] ?? []).isEmpty {
            await loadSelectedChat(chat)
        }
        await commitRead(chat, source: source)
    }

    private func loadPreview(_ request: PreviewLoadRequest) async {
        guard previewLoadCoordinator.claim(request) else { return }
        defer { previewLoadCoordinator.finish(request) }
        // This exact operation owns cleanup if the request's runtime becomes
        // stale. Accepted coordinator reuse (A→B→A) deliberately resolves the
        // latest matching selection after the await instead.
        let requestMeasurement = activeChatSwitchMeasurement.flatMap {
            $0.chatKey == request.chatJID ? $0 : nil
        }
        guard let client = runtimeClient, isCurrentRefreshClient(client) else {
            finishChatSwitchFetch(requestMeasurement, outcome: .cancelled)
            return
        }
        let page = performanceSignposts.beginMessagePage()
        do {
            let res = try await client.messages(chat: request.chatJID)
            guard isCurrentRefreshClient(client),
                  previewLoadCoordinator.isCurrent(request),
                  selectedChat == request.chatJID else {
                performanceSignposts.endMessagePage(page, outcome: .cancelled)
                finishChatSwitchFetch(requestMeasurement, outcome: .cancelled)
                return
            }
            mergeMessages(res.messages, into: request.chatJID)
            performanceSignposts.endMessagePage(page, outcome: .completed)
            // Resolve ownership after the await. The coordinator can reuse a
            // claimed A request across A→B→A while selection creates a fresh
            // interval; that latest interval owns the accepted response.
            let currentMeasurement = activeChatSwitchMeasurement.flatMap {
                $0.chatKey == request.chatJID ? $0 : nil
            }
            finishChatSwitchFetch(currentMeasurement, outcome: .completed)
        } catch {
            let outcome = Task.isCancelled
                ? PerformanceSignpostLifecycle.Outcome.cancelled
                : .failed
            performanceSignposts.endMessagePage(page, outcome: outcome)
            guard isCurrentRefreshClient(client),
                  previewLoadCoordinator.isCurrent(request),
                  selectedChat == request.chatJID else {
                finishChatSwitchFetch(requestMeasurement, outcome: .cancelled)
                return
            }
            let currentMeasurement = activeChatSwitchMeasurement.flatMap {
                $0.chatKey == request.chatJID ? $0 : nil
            }
            finishChatSwitchFetch(currentMeasurement, outcome: outcome)
        }
        guard previewLoadCoordinator.isCurrent(request), selectedChat == request.chatJID else { return }
        let liveUnreadCount = readCommitAction.value(for: request.chatJID)
            ?? chats.first(where: { $0.jid == request.chatJID })?.unread_count
            ?? serverChats[request.chatJID]?.unread_count
        if let liveUnreadCount, liveUnreadCount > 0 {
            readCommitAction.observe(request.chatJID, unreadCount: liveUnreadCount)
        }
        unreadBoundaries[request.chatJID] = UnreadBoundaryPolicy.refresh(
            existing: unreadBoundaries[request.chatJID],
            liveUnreadCount: liveUnreadCount,
            messages: messagesByChat[request.chatJID] ?? []
        )
        if request.chatJID.hasSuffix("@g.us") {
            Task { await loadMembers(for: request.chatJID) }
        }
    }

    func commitRead(_ chat: String, source: ChatOpenSource) async {
        guard source.acknowledgesRead, let client = runtimeClient,
              isCurrentRefreshClient(client) else { return }
        let fallbackUnread = chats.first(where: { $0.jid == chat })?.unread_count
            ?? serverChats[chat]?.unread_count
            ?? 0
        let unread = readCommitAction.value(for: chat) ?? fallbackUnread
        unreadBoundaries[chat] = UnreadBoundaryPolicy.refresh(
            existing: unreadBoundaries[chat],
            liveUnreadCount: unread,
            messages: messagesByChat[chat] ?? []
        )
        let result = await readCommitAction.commit(
            chatJID: chat,
            source: source,
            fallbackUnreadCount: fallbackUnread,
            request: { try await client.markRead(chat: chat) },
            onSuccess: {
                if let index = self.chats.firstIndex(where: { $0.jid == chat }) {
                    self.chats[index].unread_count = 0
                    self.chats[index].mentioned_unread = 0
                }
                if var backing = self.serverChats[chat] {
                    backing.unread_count = 0
                    backing.mentioned_unread = 0
                    self.serverChats[chat] = backing
                }
            }
        )
        switch result {
        case .succeeded:
            updateDockBadge()
        case .failed:
            toast = "Mark read failed: \(readCommitAction.lastErrorDescription ?? "unknown error")"
        case .skipped:
            break
        }
    }

    func open(_ chat: String, anchorMessageID: String? = nil,
              source: ChatOpenSource) async {
        await previewChat(chat, anchorMessageID: anchorMessageID)
        await commitRead(chat, source: source)
    }

    func showInbox() {
        sidebarTab = .inbox
        Task { await refreshInbox() }
    }

    /// ⌘J: open the next chat with unread messages; fall back to the inbox.
    /// Uses the FULL chat set (serverChats), not the visible list — under an
    /// Unread/Mentions filter the visible array hides most unread chats, and
    /// ⌘J would fall through to the inbox while real unread remained.
    func jumpNextUnread() async {
        let pool: [Chat]
        if chatFilter == "all" {
            pool = chats
        } else {
            // Local rows may be newer than the last full page (a message
            // landed mid-filter); take the max unread per JID from both.
            var byJID = serverChats
            for c in chats { byJID[c.jid] = c }
            pool = Array(byJID.values)
        }
        let unread = pool.filter { $0.unread_count > 0 }
        guard let next = unread.first(where: { $0.jid != selectedChat }) ?? unread.first else {
            showInbox()
            return
        }
        sidebarTab = .chats
        await previewChat(next.jid)
    }

    func loadOlderMessages(for chat: String) async {
        guard let api, let list = messagesByChat[chat],
              let oldest = list.first else { return }
        // Capture before the await: a logout/sidecar restart mid-fetch must
        // not merge an old-account page into the fresh session.
        let capturedClient = runtimeClient
        // messages are stored oldest→newest; page "before" the oldest
        let page = performanceSignposts.beginMessagePage()
        var pageOutcome = PerformanceSignpostLifecycle.Outcome.cancelled
        defer { performanceSignposts.endMessagePage(page, outcome: pageOutcome) }
        let res: MessagesResponse
        do {
            res = try await api.messages(
                chat: chat,
                before: "\(oldest.timestamp),\(oldest.id)"
            )
        } catch {
            pageOutcome = Task.isCancelled ? .cancelled : .failed
            return
        }
        guard !Task.isCancelled, let capturedClient,
              isCurrentRefreshClient(capturedClient) else {
            pageOutcome = .cancelled
            return
        }
        guard !res.messages.isEmpty else {
            pageOutcome = .completed
            return
        }
        // Re-read after the await: WS rows appended mid-fetch must
        // survive the prepend.
        let current = messagesByChat[chat] ?? []
        let merged = MessageTimelineOrder.mergingOlderPage(res.messages, into: current)
        let retained = trimmedTranscript(merged, for: chat)
        messagesByChat[chat] = retained
        touchTranscript(chat)
        unreadBoundaries[chat] = UnreadBoundaryPolicy.refresh(
            existing: unreadBoundaries[chat],
            liveUnreadCount: readCommitAction.value(for: chat),
            messages: retained
        )
        pageOutcome = .completed
    }

    // MARK: sending (optimistic UI)

    /// Optimistic send: the bubble appears instantly as pending, the wire
    /// round trip happens behind it, and reconciliation replaces the temp
    /// row with the durable one (WS echo of the same message dedups by id).
    func send(_ text: String, in chatJID: String) async {
        await deliver(text, in: chatJID, reply: nil)
    }

    func sendReply(_ text: String, in chatJID: String) async {
        let target = replyStore.take(for: chatJID)
        await deliver(text, in: chatJID, reply: target)
    }

    // MARK: mentions

    /// Loads (or refreshes) a group's member list into chatMembers. The
    /// core serves its DB cache instantly; the network refreshes it at most
    /// once per 10 minutes per group.
    func loadMembers(for chatJID: String) async {
        guard chatJID.hasSuffix("@g.us"), let api, let captured = runtimeClient else { return }
        if let members = try? await api.groupMembers(chat: chatJID) {
            guard isCurrentRefreshClient(captured) else { return }
            chatMembers[chatJID] = members
            chatMembersFetchedAt[chatJID] = Date()
        }
    }

    /// Members of a group chat for autocomplete; empty for direct chats.
    /// Roster cache lifetime: past this the panel/autocomplete refetch in
    /// the background (mirrors the core's per-group network throttle).
    private static let memberCacheTTL: TimeInterval = 10 * 60
    private var chatMembersFetchedAt: [String: Date] = [:]

    func mentionCandidates(for chatJID: String) async -> [APIClient.GroupMember] {
        guard chatJID.hasSuffix("@g.us") else { return [] }
        if let cached = chatMembers[chatJID], !cached.isEmpty {
            let fresh = chatMembersFetchedAt[chatJID].map { Date().timeIntervalSince($0) < Self.memberCacheTTL } ?? false
            if fresh {
                return cached
            }
            await loadMembers(for: chatJID) // stale: refresh, fall back to old on failure
            return chatMembers[chatJID] ?? cached
        }
        await loadMembers(for: chatJID)
        return chatMembers[chatJID] ?? []
    }

    /// Display label used for an @mention of a member (contact name, else
    /// the member's own recorded name, else a readable phone form).
    func mentionLabel(for jid: String, fallback: String?) -> String {
        let named = nameFor(jid)
        if !named.hasPrefix("+") { return named }
        if let fallback, !fallback.isEmpty, !fallback.hasPrefix("+") { return fallback }
        return named
    }

    /// Context-menu "Mention": record the target and poke the composer.
    func insertMention(from message: Message) {
        guard message.chat_jid.hasSuffix("@g.us"), !message.from_me else { return }
        let label = mentionLabel(for: message.sender_jid, fallback: nil)
        setMentionTarget(message.sender_jid, label: label, for: message.chat_jid)
        pendingMentionInsert = label
    }

    func setMentionTarget(_ jid: String, label: String, for chatJID: String) {
        if lastOpenedChat == chatJID {
            mentionTargets[jid] = label
        } else {
            var targets = mentionTargetStore[chatJID] ?? [:]
            targets[jid] = label
            mentionTargetStore[chatJID] = targets
        }
        mentionGenerations.rearm(chatJID)
    }

    /// ⌘V routing (replaces the system Edit ▸ Paste command): in the
    /// composer, a clipboard image becomes the attachment; anything else —
    /// or any other focus target — falls through to the standard text paste
    /// via the responder chain.
    @discardableResult
    func handlePaste() -> Bool {
        let attachment = composerFieldFocused ? Self.pastedFileURL() : nil
        guard PasteRoutingPolicy.route(
            composerFocused: composerFieldFocused,
            hasAttachment: attachment != nil
        ) == .attachment, let attachment else {
            return false
        }
        pendingPasteImage = attachment
        return true
    }

    /// MIME type for an attachment from its extension: UTType lookup with an
    /// octet-stream fallback — the Go core maps unknowns to a document.
    static func mime(forExtension ext: String) -> String {
        guard !ext.isEmpty,
              let ut = UTType(filenameExtension: ext.lowercased()),
              let mime = ut.preferredMIMEType else {
            return "application/octet-stream"
        }
        return mime
    }

    /// Resolves a clipboard attachment to a file URL: a copied FILE (Finder)
    /// is used as-is whatever its type; raw image bytes (PNG, or TIFF
    /// converted to PNG — the screenshot format) are written to a temp
    /// file. An attachment wins over text when both are present (WhatsApp
    /// Web convention). Returns nil when the clipboard carries neither.
    static func pastedFileURL() -> URL? {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], let url = urls.first {
            return url
        }
        let data: Data
        if let png = pb.data(forType: .png) {
            data = png
        } else if let tiff = pb.data(forType: .tiff),
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) {
            data = png
        } else {
            return nil
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-paste-\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    /// Nick tap: route a profile request to the chat's member panel.
    func openProfileRequest(for jid: String, in chatJID: String) {
        guard chatJID.hasSuffix("@g.us") else { return }
        profileRequest = ProfileRequest(chatJID: chatJID, jid: jid)
    }

    /// Mentions still present in the draft text (user may have deleted one).
    /// Token-boundary matching: "@Ann" must not fire for the text "@Anna".
    func activeMentions(in text: String) -> [String] {
        mentionTargets.compactMap { jid, label in
            containsMentionToken(text, label: label) ? jid : nil
        }
    }

    private func containsMentionToken(_ text: String, label: String) -> Bool {
        var searchStart = text.startIndex
        while let r = text.range(of: "@\(label)", range: searchStart..<text.endIndex) {
            let afterOK = r.upperBound == text.endIndex ||
                          !isWordChar(text[r.upperBound])
            // `index(before:)` is only valid when the match is NOT at the
            // string's start — evaluating it eagerly crashed (SIGILL in
            // Release) on drafts that open with "@name …".
            let beforeOK = r.lowerBound == text.startIndex
                || !isWordChar(text[text.index(before: r.lowerBound)])
            if afterOK && beforeOK { return true }
            searchStart = r.upperBound
        }
        return false
    }

    private func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Mention tokens must carry identity digits in LID-space groups (the
    /// receiver binds the highlight from "@<digits>", not from display
    /// labels); receivers render the digits as the name. Display labels are
    /// replaced right before sending, so the composer keeps its friendly
    /// "@Name" text while the wire gets the bindable token.
    private func wireMentionText(_ text: String, chat: String, mentioned: [String],
                                 targets: [String: String]) -> String {
        guard chat.hasSuffix("@g.us"), chat.contains("-"), !mentioned.isEmpty else { return text }
        var out = text
        for jid in mentioned {
            guard let label = targets[jid],
                  let member = chatMembers[chat]?.first(where: { $0.jid == jid }) else { continue }
            let token = "@\(label)"
            if let r = out.range(of: token) {
                let after = r.upperBound
                let afterOK = after == out.endIndex || !isWordChar(out[after])
                if afterOK {
                    out.replaceSubrange(r, with: "@" + member.mentionDigits)
                }
            }
        }
        return out
    }

    private func deliver(_ text: String, in chat: String, reply: Message?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = runtimeClient, isCurrentRefreshClient(client),
              !trimmed.isEmpty else { return }
        let generation = textSendGeneration
        let activeTargets = lastOpenedChat == chat ? mentionTargets : (mentionTargetStore[chat] ?? [:])
        let mentionGeneration = mentionGenerations.generation(for: chat)
        let mentioned = activeTargets.compactMap { jid, label in
            containsMentionToken(trimmed, label: label) ? jid : nil
        }
        let wireText = wireMentionText(trimmed, chat: chat, mentioned: mentioned,
                                       targets: activeTargets)
        let temp = makePendingMessage(chat: chat, text: trimmed, reply: reply)
        activeTextOperationChatsByTemp[temp.id] = chat
        if wireText != trimmed {
            wireTextByTemp[temp.id] = wireText
        }
        beginOptimisticProtection(for: temp)
        let tracksOptimisticVisibility = chat == selectedChat
        if tracksOptimisticVisibility {
            performanceSignposts.beginOptimistic(rowID: temp.id, chatKey: chat)
        }
        let upsertResult = upsert(temp, in: chat)
        if tracksOptimisticVisibility, upsertResult != .inserted {
            performanceSignposts.cancelVisibleRow(rowID: temp.id)
        }
        bumpChat(with: temp)
        do {
            let m = try await client.sendText(
                chat: chat,
                text: wireText,
                replyTo: reply.map { ($0.message_id, $0.sender_jid) },
                mentionedJIDs: mentioned
            )
            guard claimTextSendOperation(temp, generation: generation, client: client) else {
                discardTextSend(temp)
                return
            }
            reconcilePending(temp, with: m, in: chat)
            bumpChat(with: m)
            if mentionGenerations.isCurrent(mentionGeneration, for: chat) {
                mentionTargetStore[chat] = [:]
                if lastOpenedChat == chat { mentionTargets.removeAll() }
            }
        } catch {
            guard claimTextSendOperation(temp, generation: generation, client: client) else {
                discardTextSend(temp)
                return
            }
            markPendingFailed(temp, in: chat)
            toast = "Send failed: \(error.localizedDescription)"
        }
    }

    /// Retry a failed optimistic row: drop the failed bubble, then re-send
    /// with the original reply context preserved.
    func retrySend(_ m: Message) async {
        let chat = m.chat_jid
        guard RetryOwnershipPolicy.chat(for: m) == chat, let text = m.text else { return }
        if var list = messagesByChat[chat] {
            activeTextOperationChatsByTemp.removeValue(forKey: m.id)
            wireTextByTemp.removeValue(forKey: m.id)
            provisionalEchoesByTemp.removeValue(forKey: m.id)
            list.removeAll { $0.id == m.id }
            messagesByChat[chat] = trimmedTranscript(list, for: chat)
            _ = finishOptimisticProtection(forTempID: m.id)
            pruneFinalizedProvisionalEchoes(in: chat)
            enforceTranscriptRetention()
        }
        var reply: Message?
        if let id = m.reply_to_id, !id.isEmpty {
            reply = Message(id: 0, message_id: id, chat_jid: chat,
                            sender_jid: m.reply_to_sender ?? "", from_me: false,
                            timestamp: 0, kind: "text", text: m.quoted_text,
                            reply_to_id: nil, reply_to_sender: nil, quoted_text: nil,
                            has_mention: false, receipt_status: nil, revoked: false,
                            forwarded: nil, edited_ts: nil, raw_kind: nil, media: nil, reactions: nil)
        }
        await deliver(text, in: chat, reply: reply)
    }

    private func makePendingMessage(chat: String, text: String, reply: Message?) -> Message {
        let id = nextTempMessageID
        nextTempMessageID -= 1
        return Message(
            id: id,
            message_id: "pending-\(id)",
            chat_jid: chat,
            sender_jid: ownJIDValue ?? "me",
            from_me: true,
            timestamp: pendingMessageTimestamp(),
            kind: "text",
            text: text,
            reply_to_id: reply?.message_id,
            reply_to_sender: reply?.sender_jid,
            quoted_text: reply.map { $0.text ?? $0.media?.kind.capitalized ?? "" },
            has_mention: false,
            receipt_status: "pending",
            revoked: false,
            forwarded: nil,
            edited_ts: nil,
            raw_kind: nil,
            media: nil,
            reactions: nil
        )
    }

    /// Swap the optimistic row for the durable one. Removes any row carrying
    /// the real message_id first so the WS echo can't leave a duplicate.
    private func reconcilePending(_ temp: Message, with m: Message, in chat: String) {
        performanceSignposts.cancelVisibleRow(rowID: temp.id)
        guard var list = messagesByChat[chat] else {
            provisionalEchoesByTemp.removeValue(forKey: temp.id)
            _ = finishOptimisticProtection(forTempID: temp.id)
            enforceTranscriptRetention()
            return
        }

        // The HTTP ack can instead identify an echo provisionally owned by a
        // different temp. Restore that removed owner exactly: it may already
        // be definitively failed, or may still own an outstanding callback.
        // Restore before redistributing this temp's different echo so every
        // active indistinguishable owner participates in ambiguity accounting.
        if let confirmed = provisionalEchoesByTemp.first(where: {
            $0.key != temp.id && sameDurableIdentity($0.value.echo, m)
        }) {
            provisionalEchoesByTemp.removeValue(forKey: confirmed.key)
            let displaced = confirmed.value.removedTemp
            if !list.contains(where: { $0.id == displaced.id }) {
                list.append(displaced)
            }
            beginOptimisticProtection(for: displaced)
        }

        // An echo was provisionally attached to this temp because same-text
        // sends carry no client correlation ID. A different exact HTTP ack
        // proves that assignment wrong, so move the echo onto the oldest
        // remaining eligible temp before applying the acknowledged row.
        if let ownership = provisionalEchoesByTemp.removeValue(forKey: temp.id),
           !sameDurableIdentity(ownership.echo, m) {
            _ = consumeTempCandidate(for: ownership.echo, from: &list)
        }

        list.removeAll { $0.id == temp.id || sameDurableIdentity($0, m) }
        list.append(m)
        MessageTimelineOrder.sort(&list)
        messagesByChat[chat] = trimmedTranscript(list, for: chat)
        _ = finishOptimisticProtection(forTempID: temp.id)
        pruneFinalizedProvisionalEchoes(in: chat)
        enforceTranscriptRetention()
    }

    private func markPendingFailed(_ temp: Message, in chat: String) {
        if let ownership = provisionalEchoesByTemp[temp.id] {
            var failed = ownership.removedTemp
            failed.receipt_status = "failed"
            provisionalEchoesByTemp[temp.id] = ProvisionalEchoOwnership(
                echo: ownership.echo,
                removedTemp: failed
            )
            pruneFinalizedProvisionalEchoes(in: chat)
            enforceTranscriptRetention()
            return
        }
        if var list = messagesByChat[chat],
           let i = list.firstIndex(where: { $0.id == temp.id }) {
            list[i].receipt_status = "failed"
            messagesByChat[chat] = trimmedTranscript(list, for: chat)
        }
        pruneFinalizedProvisionalEchoes(in: chat)
        enforceTranscriptRetention()
    }

    /// Sends a user-picked image with the composer draft as its caption.
    /// Picking (NSOpenPanel) lives in the composer; this only uploads.
    /// Returns true when sent — the composer clears draft + attachment then.
    @discardableResult
    func sendAttachment(url: URL, caption: String, in chatJID: String) async -> Bool {
        guard let client = runtimeClient else { return false }
        let generation = attachmentGeneration
        let replyOperation = replyStore.mediaSendOperation(for: chatJID)
        let reply = replyOperation.map {
            (id: $0.message.message_id, sender: $0.message.sender_jid)
        }
        let mime = Self.mime(forExtension: url.pathExtension)
        let filename = url.lastPathComponent
        guard let operationID = beginAttachmentOperation(
            generation: generation,
            client: client
        ) else { return false }
        defer { finishAttachmentOperation(operationID, generation: generation) }

        let data: Data
        do {
            data = try await attachmentLoad(url, AttachmentLoader.maximumByteCount)
        } catch let error as AttachmentReadError {
            guard acceptsAttachmentWork(
                operationID: operationID,
                generation: generation,
                client: client
            ) else {
                return false
            }
            toast = error.isTooLarge ? "File too large (max 20 MB)" : "Cannot read file"
            return false
        } catch is CancellationError {
            return false
        } catch {
            guard acceptsAttachmentWork(
                operationID: operationID,
                generation: generation,
                client: client
            ) else {
                return false
            }
            toast = "Cannot read file"
            return false
        }
        guard acceptsAttachmentWork(
            operationID: operationID,
            generation: generation,
            client: client
        ) else { return false }

        do {
            let message = try await client.sendMedia(
                chat: chatJID,
                data: data,
                mime: mime,
                filename: filename,
                caption: caption,
                replyTo: reply
            )
            guard acceptsAttachmentWork(
                operationID: operationID,
                generation: generation,
                client: client
            ) else { return false }
            upsert(message, in: chatJID, allowCreate: true)
            touchTranscript(chatJID)
            bumpChat(with: message)
            replyStore.completeMediaSend(replyOperation, for: chatJID)
            return true
        } catch {
            guard acceptsAttachmentWork(
                operationID: operationID,
                generation: generation,
                client: client
            ) else { return false }
            toast = "Send image failed: \(error.localizedDescription)"
        }
        return false
    }

    private func acceptsAttachmentWork(
        operationID: UInt64? = nil,
        generation: UInt64,
        client: AppRuntimeClient
    ) -> Bool {
        let ownsOperation = operationID.map { activeAttachmentOperationID == $0 } ?? true
        return !Task.isCancelled
            && attachmentGeneration == generation
            && runtimeClient === client
            && connectionRefresh.isCurrent(client)
            && ownsOperation
    }

    private func beginAttachmentOperation(
        generation: UInt64,
        client: AppRuntimeClient
    ) -> UInt64? {
        guard activeAttachmentOperationID == nil,
              acceptsAttachmentWork(generation: generation, client: client) else { return nil }
        nextAttachmentOperationID &+= 1
        let operationID = nextAttachmentOperationID
        activeAttachmentOperationID = operationID
        sendingMedia = true
        return operationID
    }

    private func finishAttachmentOperation(_ operationID: UInt64, generation: UInt64) {
        guard attachmentGeneration == generation,
              activeAttachmentOperationID == operationID else { return }
        activeAttachmentOperationID = nil
        sendingMedia = false
    }

    private func invalidateAttachmentOperations() {
        attachmentGeneration &+= 1
        activeAttachmentOperationID = nil
        sendingMedia = false
    }

    // MARK: media

    /// Click-to-load: fetch bytes (downloading on the core if needed) and
    /// decode a downsampled bubble preview off the main actor — a sync
    /// ImageIO decode here stuttered the UI on Intel. Bubbles render at
    /// ≤220×200 pt, so 480 px covers 2× retina; full pixels never enter
    /// memory (R6 budget discipline).
    func ensureMedia(_ message: Message) async {
        guard !mediaBusy.contains(message.id), message.media != nil else { return }
        mediaBusy.insert(message.id)
        defer { mediaBusy.remove(message.id) }
        guard let captured = runtimeClient else { return }

        var msg = message
        if msg.media?.state != "downloaded" {
            guard let fetched = try? await apiClient?.mediaDownload(rowID: message.id),
                  fetched.media?.state == "downloaded" else { return }
            guard isCurrentRefreshClient(captured) else { return }
            msg = fetched
            upsert(msg, in: msg.chat_jid)
        }
        guard let client = apiClient,
              let (data, _) = try? await client.mediaData(rowID: message.id) else { return }
        let decode = Task.detached(priority: .userInitiated) {
            Self.downsampledImage(data: data, maxPixel: 480)
        }
        if let decoded = await decode.value {
            // A logout/restart mid-download must not write this session's
            // image bytes into the replacement session's caches.
            guard isCurrentRefreshClient(captured) else { return }
            mediaImages[message.id] = decoded.image
            mediaImageBytes[message.id] = decoded.bytes
            trimMediaImages(maxBytes: Self.mediaCacheByteBudget)
        }
    }

    /// Tap-to-preview: re-fetch the bytes and decode a large render off-main
    /// (the bubble's 480 px image would look soft at sheet size).
    func openPreview(_ message: Message) async {
        let kind = message.media?.kind
        guard kind == "image" || kind == "sticker" else { return }
        guard let captured = runtimeClient else { return }
        if let img = mediaImages[message.id] {
            previewImage = (img, message) // instant, upgraded below
        }
        guard let client = apiClient,
              let (data, _) = try? await client.mediaData(rowID: message.id) else { return }
        let decode = Task.detached(priority: .userInitiated) {
            Self.downsampledImage(data: data, maxPixel: 900)
        }
        if let decoded = await decode.value {
            guard isCurrentRefreshClient(captured) else { return }
            previewImage = (decoded.image, message)
        }
    }

    /// Save media bytes to disk: fetch from the core, save panel (defaults
    /// to ~/Downloads), write, reveal in Finder. Shared by the non-image
    /// bubble action and the image-preview Save button.
    func saveMediaToDisk(_ message: Message) async {
        guard let client = apiClient,
              let media = message.media,
              let (data, _) = try? await client.mediaData(rowID: message.id) else {
            toast = "Media fetch failed"
            return
        }
        guard let dest = await Self.chooseSaveDestination(
            filename: media.filename, kind: media.kind, mime: media.mime, rowID: message.id
        ) else { return }
        do {
            try data.write(to: dest)
            toast = "Saved \(dest.lastPathComponent)"
            NSWorkspace.shared.selectFile(dest.path, inFileViewerRootedAtPath: dest.deletingLastPathComponent().path)
        } catch {
            toast = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Pure filename policy (unit-tested): the stored filename wins; the
    /// fallback is "<Kind>-<rowid>" with an extension derived from the
    /// stored MIME via UTType — never from the HTTP Content-Type, whose
    /// pathExtension is always "".
    nonisolated static func suggestedSaveName(filename: String?, kind: String, mime: String, rowID: Int64) -> String {
        let provided = filename.flatMap { $0.isEmpty ? nil : $0 }?
            .replacingOccurrences(of: "/", with: "_")
        let fallback = "\(kind.capitalized)-\(rowID)"
        let nameExt = provided.map { ($0 as NSString).pathExtension } ?? ""
        let ext = !nameExt.isEmpty
            ? nameExt
            : Self.fileExtension(forMIME: mime)
        let base = ((provided ?? fallback) as NSString).deletingPathExtension
        return nameExt.isEmpty ? "\(base).\(ext)" : (provided ?? fallback)
    }

    /// UTType answers "jpeg" for image/jpeg on this OS; WhatsApp's
    /// convention (and the unit tests) expect ".jpg". Everything else
    /// derives from the stored MIME; unknown MIME falls back to "bin".
    nonisolated private static func fileExtension(forMIME mime: String) -> String {
        if mime.lowercased() == "image/jpeg" { return "jpg" }
        return UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
    }

    @MainActor
    static func chooseSaveDestination(filename: String?, kind: String, mime: String, rowID: Int64) async -> URL? {
        let panel: NSSavePanel = {
            let p = NSSavePanel()
            p.title = "Save Media"
            p.nameFieldStringValue = suggestedSaveName(filename: filename, kind: kind, mime: mime, rowID: rowID)
            p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            return p
        }()
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
              await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.url
    }

    /// Decoded-image RAM budget: ~48 MB of bitmaps, evicting oldest-media
    /// entries (rowids grow with recency) first. A count-only cap let 240
    /// × 720 px bitmaps accumulate to hundreds of MB.
    private static let mediaCacheByteBudget = 48 << 20
    private var mediaImageBytes: [Int64: Int] = [:]

    private func trimMediaImages(maxBytes: Int) {
        var total = mediaImageBytes.values.reduce(0, +)
        guard total > maxBytes else { return }
        for id in mediaImageBytes.keys.sorted(by: <) {
            guard total > maxBytes else { break }
            total -= mediaImageBytes[id] ?? 0
            mediaImages.removeValue(forKey: id)
            mediaImageBytes.removeValue(forKey: id)
        }
    }

    /// Sendable box: a decoded image crossing from the detached decode task
    /// to the main actor. Safe because the NSImage is backed by an immutable
    /// CGImage and never mutated after creation.
    struct DecodedImage: @unchecked Sendable {
        nonisolated let image: NSImage
        nonisolated let bytes: Int
    }

    /// ImageIO downsample: decode straight to target size, skip full-res.
    /// Returns the decoded image and its rough RGBA byte cost for the cache
    /// budget. nonisolated: callable from detached decode tasks (statics of
    /// a @MainActor class would otherwise inherit main-actor isolation).
       nonisolated static func downsampledImage(data: Data, maxPixel: CGFloat) -> DecodedImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        return DecodedImage(image: img, bytes: cg.width * cg.height * 4)
    }

    // MARK: work inbox

    func refreshInbox() async {
        guard let api, let captured = runtimeClient else { return }
        guard let fresh = try? await api.inbox() else {
            // A stale failure (post-logout, sidecar restart) must not wipe
            // the visible inbox with nil.
            return
        }
        guard isCurrentRefreshClient(captured) else { return }
        inbox = fresh
    }

    /// Patches a loaded transcript row's work state locally, immediately —
    /// the WS `message.updated` echo re-affirms it later. Relying on the echo
    /// alone meant a socket hiccup left a successful Done with zero visible
    /// reaction.
    private func patchWorkState(chatJID: String, rowID: Int64,
                                done: Bool? = nil, starred: Bool? = nil) {
        guard var list = messagesByChat[chatJID],
              let i = list.firstIndex(where: { $0.id == rowID }) else { return }
        if let done { list[i].done = done }
        if let starred { list[i].starred = starred }
        messagesByChat[chatJID] = list
    }

    /// Work-state actions: POST + optimistic row patch + toast on BOTH
    /// success and failure — an action must never complete silently.
    @discardableResult
    func markDone(_ m: Message, done: Bool = true) async -> Bool {
        guard let api else { return false }
        do {
            try await api.setMessageDone(rowID: m.id, done: done)
            patchWorkState(chatJID: m.chat_jid, rowID: m.id, done: done)
            toast = done ? "✓ Done" : "Reopened — back in the inbox"
            return true
        } catch {
            toast = "Done failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func starMessage(_ m: Message) async -> Bool {
        let star = !(m.starred ?? false)
        guard let api else { return false }
        do {
            try await api.setMessageStar(rowID: m.id, starred: star)
            patchWorkState(chatJID: m.chat_jid, rowID: m.id, starred: star)
            toast = star ? "★ Starred" : "Unstarred"
            return true
        } catch {
            toast = "Star failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func snoozeMessage(rowID: Int64, until: Int64, label: String) async -> Bool {
        guard let api else { return false }
        do {
            try await api.setMessageSnooze(rowID: rowID, until: until)
            toast = "Snoozed — \(label)"
            return true
        } catch {
            toast = "Snooze failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Conversation-level bulk actions: one Done (or Snooze) clears the
    /// whole chat's pending items — a busy group is one row to handle.
    @discardableResult
    func markConversationDone(_ conv: InboxConversation, done: Bool = true) async -> Bool {
        guard let api else { return false }
        do {
            try await api.setChatDone(jid: conv.chat_jid, done: done)
            toast = done ? "✓ \(conversationLabel(conv)) — \(conv.count) item\(conv.count == 1 ? "" : "s") done"
                         : "Reopened \(conversationLabel(conv))"
            await refreshInbox()
            return true
        } catch {
            toast = "Done failed: \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    func snoozeConversation(_ conv: InboxConversation, until: Int64, label: String) async -> Bool {
        guard let api else { return false }
        do {
            try await api.setChatSnooze(jid: conv.chat_jid, until: until)
            toast = "Snoozed \(conversationLabel(conv)) — \(label)"
            await refreshInbox()
            return true
        } catch {
            toast = "Snooze failed: \(error.localizedDescription)"
            return false
        }
    }

    private func conversationLabel(_ conv: InboxConversation) -> String {
        conv.chat_name.isEmpty ? AppState.prettyJID(conv.chat_jid) : conv.chat_name
    }

    /// Debounced /inbox refetch for live events (new message, inbox.changed).
    /// The core emits hints; the fetch is the truth — one per burst is enough.
    private var inboxRefreshTask: Task<Void, Never>?

    func scheduleInboxRefresh() {
        inboxRefreshTask?.cancel()
        inboxRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.refreshInbox()
        }
    }

    /// Next 09:00 local (today while before 9 am, else tomorrow) — the
    /// "snooze until tomorrow" target. Calendar math lives client-side; the
    /// core stores the absolute deadline.
    nonisolated static func nextMorning(from now: Date = Date()) -> Int64 {
        let cal = Calendar.current
        let today9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: now) ?? now
        let target = today9 > now ? today9 : (cal.date(byAdding: .day, value: 1, to: today9) ?? today9)
        return Int64(target.timeIntervalSince1970)
    }

    /// Snooze deadline helpers shared by the transcript and inbox UIs.
    /// Computed per call — a cached `let` would drift stale over a long run.
    static var snoozeOneHour: Int64 { Int64(Date().timeIntervalSince1970) + 3600 }
    static func snoozeNextWeek(from now: Date = Date()) -> Int64 {
        Int64(now.addingTimeInterval(7 * 24 * 3600).timeIntervalSince1970)
    }

    // MARK: notification click-through

    /// message_id → chat for posted notifications, consumed on click. Bounded:
    /// only the newest 200 mappings are kept.
    private(set) var notificationChats: [String: String] = [:]

    func openChat(fromNotification messageID: String) async {
        guard let chat = notificationChats[messageID] else { return }
        notificationChats.removeValue(forKey: messageID)
        sidebarTab = .chats
        if chatFilter != "all" {
            await applyFilter("all")
        }
        await open(chat, source: .notification)
    }

    // MARK: wa.me / whatsapp:// inbound links

    /// Handles a `whatsapp://send?phone=<digits>&text=<prefill>` URL (the
    /// wa.me "Continue to Chat" continuation) for either registered scheme.
    /// Unknown chats get a minimal local row — the server row appears on
    /// first send. `text=` lands in the composer as a focused draft.
    func handleWhatsAppLink(_ url: URL) async {
        guard let comp = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = comp.queryItems ?? []
        let phone = items.first(where: { $0.name == "phone" })?.value ?? ""
        let digits = phone.filter(\.isNumber)
        guard !digits.isEmpty else { return }
        let jid = digits + "@s.whatsapp.net"

        if chats.first(where: { $0.jid == jid }) == nil && serverChats[jid] == nil {
            chats.insert(Chat(jid: jid, kind: "direct", display_name: "+" + digits,
                              last_message_ts: 0, last_preview: "", unread_count: 0,
                              mentioned_unread: 0, is_pinned: false, is_muted: false),
                         at: 0)
        }
        sidebarTab = .chats
        if chatFilter != "all" {
            await applyFilter("all")
        }
        await open(jid, source: .deepLink)
        if let text = items.first(where: { $0.name == "text" })?.value,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftStore[jid] = text
            composerFocusRequest += 1
        }
    }

    /// Copies `https://wa.me/<digits>` for a direct chat to the pasteboard.
    func copyWaMeLink(forChat jid: String) {
        let digits = jid.prefix(while: { $0 != "@" })
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("https://wa.me/\(digits)", forType: .string)
        toast = "wa.me link copied"
    }

    func applyFilter(_ f: String) async {
        chatFilter = f
        chatsLoaded = false // spinner while the filtered page is in flight
        await refreshChats(source: .filter)
    }

    // MARK: search (⌘K)

    func runSearch(_ q: String) async -> SearchResponse? {
        guard let api, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try? await api.search(q)
    }

    func jump(toChat jid: String, anchorMessageID: String? = nil) async {
        searchOpen = false
        // The picker must not lie about the filter: switching to "all"
        // needs the matching list, not yesterday's filtered one.
        if chatFilter != "all" {
            await applyFilter("all")
        }
        if chats.first(where: { $0.jid == jid }) == nil {
            await refreshChats(source: .chats)
        }
        await open(jid, anchorMessageID: anchorMessageID, source: .search)
    }

    func logout() async {
        await logout(restartSidecar: { [sidecar] in sidecar.restartNow() })
    }

    /// Testable production boundary for logout invalidation. The app supplies
    /// the real sidecar restart; runtime tests supply a no-op after exercising
    /// the same endpoint, disconnect, cancellation, and state-clear path.
    func logout(restartSidecar: @MainActor () -> Void) async {
        sidecar.handleSleepSignal(.logout)
        cancelRuntimeForLogout()
        // No client means the sidecar is down/restarting — leaving without
        // touching the screen would look like a logout while the core is
        // still paired with data intact.
        guard let client = runtimeClient else {
            screen = .login
            return
        }
        do {
            try await client.logout()
        } catch {
            // The core wipe failed — say so instead of silently pretending.
            // Local state is still cleared below: the core either gets
            // wiped by the fresh sidecar start or the device stays linked
            // server-side, which the toast warns about.
            toast = "Log out failed on the core — the device may still be linked. Retry if in doubt."
        }
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        _ = wsLifecycle.replaceConnection()
        lastWSActivityAt = nil
        await client.disconnectEvents()
        runtimeClient = nil
        api = nil
        stopPolling()
        clearSessionData()
        restartSidecar() // fresh core with wiped data
        screen = .login
    }

    func cancelRuntimeForLogout() {
        invalidateAttachmentOperations()
        invalidateTextSendOperations()
        connectionRefresh.cancel()
        contactNamesReloadTask?.cancel()
        contactNamesReloadTask = nil
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        _ = wsLifecycle.replaceConnection()
        lastWSActivityAt = nil
    }

    // MARK: plumbing

    /// Poll fallback while WS is unproven in M2 dev (removed once WS is
    /// verified against the core in a long session).
    var ownJID: String? { ownJIDValue }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                _ = await self?.runRecoveryPoll(now: Date())
            }
        }
    }

    @discardableResult
    func runRecoveryPoll(now: Date) async -> RecoveryPollAction {
        guard let client = runtimeClient, isCurrentRefreshClient(client) else { return .suppressed }
        let action = connectionRefresh.recoveryPollAction(
            now: now,
            lastActivityAt: lastWSActivityAt,
            connectionState: connectionState
        )
        switch action {
        case .recoveryChat:
            _ = await refreshChats(client, filter: chatFilter, source: .recovery)
        case .deferredRecovery:
            // Preserve the one-shot token until a dedicated request can
            // actually start, but still route this intent through the bounded
            // pending slot owned by the chat coordinator.
            _ = await refreshChats(client, filter: chatFilter, source: .recovery)
        case .fallback:
            _ = await refreshSession(client, includeChats: true, chatSource: .poll)
            await refreshInbox()
        case .suppressed:
            break
        }
        return action
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let client = self.runtimeClient else { return }
                _ = await self.refreshSession(client, includeChats: true, chatSource: .wake)
            }
        }
    }

    private func updateDockBadge() {
        // Count over the FULL chat set: under an Unread/Mentions filter the
        // visible `chats` array is a subset and the badge would under-report.
        let pool: [Chat]
        if chatFilter == "all" {
            pool = chats // already the full merged set by construction
        } else {
            var byJID = serverChats
            for c in chats where (byJID[c.jid]?.unread_count ?? 0) < c.unread_count {
                byJID[c.jid] = c // local live bump newer than the last page
            }
            pool = Array(byJID.values)
        }
        let counted = focusMode
            ? pool.filter { ($0.is_work ?? false) || ($0.is_starred ?? false) }
            : pool
        let unread = counted.reduce(0) { $0 + $1.unread_count }
        dockBadgeSink(unread > 0 ? "\(unread)" : nil)
    }

    /// Sender label for the transcript nick column: the full display name
    /// (long names wrap to a second line in the fixed column, they are not
    /// truncated to the first word).
    func ircNick(for m: Message) -> String {
        if m.from_me { return "me" }
        let name = nameFor(m.sender_jid)
        return name.isEmpty ? "?" : name
    }

    func isWorkChat(_ jid: String) -> Bool {
        guard let c = chats.first(where: { $0.jid == jid }) else { return false }
        return (c.is_work ?? false) || (c.is_starred ?? false)
    }

    /// Stable per-person key for nick coloring: the contact NAME when known
    /// (a person keeps their name across LID and phone JIDs, so their color
    /// stays identical no matter which JID form a row carries), else the JID
    /// (deterministic hash — same color every session until logout wipes it).
    func nickColorKey(for jid: String) -> String {
        let name = nameFor(jid)
        if !name.hasPrefix("+"), !name.hasPrefix("•••"), name != "WhatsApp", !name.isEmpty {
            return name
        }
        return jid
    }

    private func notify(_ m: Message) {
        if focusMode && !isWorkChat(m.chat_jid) {
            return // Focus Mode: non-work chats stay silent
        }
        if let c = chats.first(where: { $0.jid == m.chat_jid }), c.is_muted {
            return // muted chats never notify, focus mode or not
        }
        let content = UNMutableNotificationContent()
        let chatName = chats.first(where: { $0.jid == m.chat_jid })?.display_name ?? m.chat_jid
        content.title = chatName
        content.body = resolveBareMentionTokens(in: m.text ?? "📷 Media")
        // Click-through: remember which conversation this notification is for.
        notificationChats[m.message_id] = m.chat_jid
        if notificationChats.count > 200 {
            notificationChats.removeValue(forKey: notificationChats.keys.first ?? "")
        }
        let req = UNNotificationRequest(identifier: m.message_id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}


enum SidebarTab: String {
    case chats, inbox
}
