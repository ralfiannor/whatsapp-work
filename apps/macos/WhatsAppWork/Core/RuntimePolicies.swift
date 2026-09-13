import Foundation

enum WebSocketFreshnessPolicy {
    static let freshInterval: TimeInterval = 60

    static func shouldPoll(now: Date, lastActivityAt: Date?,
                           connectionState: String) -> Bool {
        guard connectionState == "connected", let lastActivityAt else { return true }
        return now.timeIntervalSince(lastActivityAt) >= freshInterval
    }
}

/// AppState owns one current socket generation. Callbacks from an older
/// generation cannot refresh state or schedule another reconnect.
struct WebSocketLifecycle {
    private(set) var generation: UInt64 = 0
    private var reconnectScheduled = false

    mutating func replaceConnection() -> UInt64 {
        generation &+= 1
        reconnectScheduled = false
        return generation
    }

    func acceptsActivity(for generation: UInt64) -> Bool {
        self.generation == generation
    }

    mutating func shouldScheduleReconnect(for generation: UInt64) -> Bool {
        guard self.generation == generation, !reconnectScheduled else { return false }
        reconnectScheduled = true
        return true
    }
}

enum ConnectionRefreshReason: Equatable {
    case initial
    case reconnect
}

enum ConnectionRefreshStep: Equatable {
    case session
    case events
    case chats
    case openTranscript
}

enum ConnectionRefreshPlan {
    static func steps(for reason: ConnectionRefreshReason) -> [ConnectionRefreshStep] {
        switch reason {
        case .initial:
            // openTranscript included: a sidecar crash-restart reconnects to
            // a core that already ingested offline catch-up — events emitted
            // before our WS resubscribes are gone, so the open chat must be
            // refetched with the list (AGENTS reconnect contract).
            [.session, .events, .chats, .openTranscript]
        case .reconnect:
            [.events, .session, .chats, .openTranscript]
        }
    }
}

enum ContactFollowUpPolicy {
    static let delays: [TimeInterval] = [45, 180]
}

/// Bounds a non-open transcript without losing local optimistic rows.
/// Input is already in canonical timeline order; this two-pass filter keeps
/// that order while selecting the newest durable rows in O(n).
enum TranscriptWindowPolicy {
    static func retained(_ rows: [Message], limit: Int = 300) -> [Message] {
        let limit = max(0, limit)
        guard rows.count > limit else { return rows }

        let localCount = rows.reduce(into: 0) { count, row in
            if row.id < 0 { count += 1 }
        }
        let durableBudget = max(0, limit - localCount)
        var durableToSkip = max(0, rows.count - localCount - durableBudget)
        var retained: [Message] = []
        retained.reserveCapacity(max(localCount, limit))
        for row in rows {
            if row.id < 0 {
                retained.append(row)
            } else if durableToSkip > 0 {
                durableToSkip -= 1
            } else {
                retained.append(row)
            }
        }
        return retained
    }
}

/// Deterministic least-recently-used ordering for loaded transcript arrays.
/// AppState calls `evictionCandidates` after every touch, so both the cache
/// and this metadata stay bounded together. Pending optimistic chats and the
/// active chat are skipped even when that temporarily leaves the cache above
/// its normal limit.
struct TranscriptRetention {
    let limit: Int
    private var oldestFirst: [String] = []

    init(limit: Int = 10) {
        self.limit = max(0, limit)
    }

    var trackedCount: Int { oldestFirst.count }

    mutating func touch(_ chatJID: String) {
        oldestFirst.removeAll { $0 == chatJID }
        oldestFirst.append(chatJID)
    }

    mutating func remove(_ chatJID: String) {
        oldestFirst.removeAll { $0 == chatJID }
    }

    mutating func reset() {
        oldestFirst.removeAll(keepingCapacity: false)
    }

    mutating func evictionCandidates(
        loaded: Set<String>,
        active: String?,
        protected: Set<String>
    ) -> [String] {
        oldestFirst.removeAll { !loaded.contains($0) }
        let tracked = Set(oldestFirst)
        // Production always touches before loading. The deterministic repair
        // keeps the value safe when restoring or tests supply preloaded keys.
        oldestFirst.append(contentsOf: loaded.subtracting(tracked).sorted())

        var remaining = loaded
        var victims: [String] = []
        for chat in oldestFirst where remaining.count > limit {
            guard chat != active,
                  !protected.contains(chat),
                  remaining.contains(chat) else { continue }
            victims.append(chat)
            remaining.remove(chat)
        }
        if !victims.isEmpty {
            let removed = Set(victims)
            oldestFirst.removeAll { removed.contains($0) }
        }
        return victims
    }
}

extension CoreEvent {
    /// Only events that can change unread membership invalidate the dock
    /// badge. This switch is intentionally exhaustive: a new event case must
    /// make an explicit classification decision before production builds.
    var affectsDockBadge: Bool {
        switch self {
        case .messageReceived(let message):
            !message.from_me
        case .chatUpdated, .chatRemoved:
            true
        case .connectionChanged, .qr, .syncProgress, .messageUpdated,
             .contactsUpdated, .inboxChanged, .reaction, .mediaUpdated, .ping:
            false
        }
    }
}

enum SleepPreventionSignal {
    case spawn
    case qr
    case syncProgress(stage: String)
    case capExpired
    case termination
    case logout
}

struct SleepPreventionPolicy {
    private(set) var active = false
    private var capReached = false

    @discardableResult
    mutating func apply(_ signal: SleepPreventionSignal) -> Bool {
        switch signal {
        case .syncProgress(let stage):
            if stage == "done" {
                active = false
                capReached = false
            } else if !capReached {
                active = true
            }
        case .capExpired:
            if active {
                active = false
                capReached = true
            }
        case .spawn, .qr, .termination, .logout:
            active = false
            capReached = false
        }
        return active
    }
}

enum AttachmentReadError: Error, Equatable {
    case unreadable
    case tooLarge(actual: Int64, limit: Int64)

    var isTooLarge: Bool {
        if case .tooLarge = self { return true }
        return false
    }
}

/// Sendable filesystem boundary used by the attachment loader. The live
/// operations are synchronous by necessity, but `AttachmentLoader.load`
/// always runs the whole boundary in one detached operation.
struct AttachmentFileAccess: Sendable {
    let startSecurityScopedAccess: @Sendable (URL) -> Bool
    let stopSecurityScopedAccess: @Sendable (URL) -> Void
    let resourceFileSize: @Sendable (URL) throws -> Int64
    let readData: @Sendable (URL) throws -> Data

    static let live = AttachmentFileAccess(
        startSecurityScopedAccess: { $0.startAccessingSecurityScopedResource() },
        stopSecurityScopedAccess: { $0.stopAccessingSecurityScopedResource() },
        resourceFileSize: { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else { throw AttachmentReadError.unreadable }
            return Int64(size)
        },
        readData: { try Data(contentsOf: $0, options: .mappedIfSafe) }
    )
}

enum AttachmentLoader {
    static let maximumByteCount: Int64 = 20 << 20

    /// Production entry point. Cancellation is forwarded to the detached
    /// operation; synchronous file reads cannot be interrupted mid-syscall,
    /// so `read` also checks cancellation immediately after the byte load.
    static func load(
        url: URL,
        maxBytes: Int64 = maximumByteCount,
        fileAccess: AttachmentFileAccess = .live
    ) async throws -> Data {
        let task = Task.detached(priority: .userInitiated) {
            try read(url: url, maxBytes: maxBytes, fileAccess: fileAccess)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Synchronous core kept internal for deterministic boundary testing.
    /// Callers in production use `load`, never this method on an actor.
    static func read(
        url: URL,
        maxBytes: Int64 = maximumByteCount,
        fileAccess: AttachmentFileAccess = .live
    ) throws -> Data {
        try Task.checkCancellation()
        let hasSecurityScope = fileAccess.startSecurityScopedAccess(url)
        defer {
            if hasSecurityScope { fileAccess.stopSecurityScopedAccess(url) }
        }

        let declaredSize: Int64
        do {
            declaredSize = try fileAccess.resourceFileSize(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AttachmentReadError.unreadable
        }
        guard declaredSize >= 0 else { throw AttachmentReadError.unreadable }
        guard declaredSize <= maxBytes else {
            throw AttachmentReadError.tooLarge(actual: declaredSize, limit: maxBytes)
        }

        try Task.checkCancellation()
        let data: Data
        do {
            data = try fileAccess.readData(url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AttachmentReadError.unreadable
        }
        try Task.checkCancellation()

        let actualSize = Int64(data.count)
        guard actualSize <= maxBytes else {
            throw AttachmentReadError.tooLarge(actual: actualSize, limit: maxBytes)
        }
        return data
    }
}

enum ConnectionRefreshStepResult {
    case success
    case chatFetchFailed
    case cancelled
}

enum ChatRefreshSource: Equatable {
    case initial
    case reconnect
    case session
    case chats
    case poll
    case wake
    case filter
    case sync
    case server
    case recovery

    /// These sources assert that state may have changed after an already
    /// running HTTP snapshot began. Public duplicate observers (`session`
    /// and `chats`) make no such claim and may join a compatible lease.
    fileprivate var advancesFreshnessIntent: Bool {
        switch self {
        case .poll, .wake, .filter, .sync, .server, .recovery:
            true
        case .initial, .reconnect, .session, .chats:
            false
        }
    }
}

enum ChatRefreshResult: Equatable {
    case succeeded
    case failed
    case queued
    case cancelled
}

enum RecoveryPollAction: Equatable {
    case recoveryChat
    case deferredRecovery
    case fallback
    case suppressed
}

struct ConnectionRefreshEpoch: Equatable {
    fileprivate let value: UInt64
}

struct ChatRefreshLease: Equatable {
    fileprivate let operationID: UInt64
    fileprivate let clientGeneration: UInt64
    fileprivate let chatEpoch: UInt64
    fileprivate let startIntentWatermark: UInt64
    let filter: String
    let source: ChatRefreshSource
    fileprivate let authoritativeEpoch: ConnectionRefreshEpoch?
}

/// Narrow type-erased boundary for the async operations used by the runtime
/// refresh lifecycle. AppState remains the state sink; tests can drive the
/// same endpoint calls without constructing URLSession or a sidecar.
@MainActor
final class AppRuntimeClient {
    typealias ConnectEvents = @MainActor (
        @escaping (CoreEvent) -> Void,
        @escaping () -> Void,
        @escaping () -> Void,
        @escaping () -> Void
    ) async -> Void
    typealias SendMedia = @MainActor (
        String,
        Data,
        String,
        String,
        String,
        (id: String, sender: String)?
    ) async throws -> Message
    typealias SendText = @MainActor (
        String,
        String,
        (id: String, sender: String)?,
        [String]
    ) async throws -> Message

    let api: APIClient?
    private let sessionInfoOperation: @MainActor () async throws -> SessionInfo
    private let chatsOperation: @MainActor (String) async throws -> ChatsResponse
    private let contactsOperation: @MainActor () async throws -> [Contact]
    private let startLinkOperation: @MainActor () async throws -> Void
    private let logoutOperation: @MainActor () async throws -> Void
    private let messagesOperation: @MainActor (String) async throws -> MessagesResponse
    private let sendTextOperation: SendText
    private let markReadOperation: @MainActor (String) async throws -> Void
    private let sendMediaOperation: SendMedia
    private let connectEventsOperation: ConnectEvents
    private let disconnectEventsOperation: @MainActor () async -> Void

    init(
        api: APIClient? = nil,
        sessionInfo: @escaping @MainActor () async throws -> SessionInfo,
        chats: @escaping @MainActor (String) async throws -> ChatsResponse,
        contacts: @escaping @MainActor () async throws -> [Contact],
        startLink: @escaping @MainActor () async throws -> Void,
        logout: @escaping @MainActor () async throws -> Void,
        messages: @escaping @MainActor (String) async throws -> MessagesResponse,
        sendText: @escaping SendText = { _, _, _, _ in
            throw URLError(.unsupportedURL)
        },
        markRead: @escaping @MainActor (String) async throws -> Void = { _ in
            throw URLError(.unsupportedURL)
        },
        sendMedia: @escaping SendMedia = { _, _, _, _, _, _ in
            throw URLError(.unsupportedURL)
        },
        connectEvents: @escaping ConnectEvents,
        disconnectEvents: @escaping @MainActor () async -> Void
    ) {
        self.api = api
        sessionInfoOperation = sessionInfo
        chatsOperation = chats
        contactsOperation = contacts
        startLinkOperation = startLink
        logoutOperation = logout
        messagesOperation = messages
        sendTextOperation = sendText
        markReadOperation = markRead
        sendMediaOperation = sendMedia
        connectEventsOperation = connectEvents
        disconnectEventsOperation = disconnectEvents
    }

    convenience init(api: APIClient) {
        self.init(
            api: api,
            sessionInfo: { try await api.sessionInfo() },
            // 199 = the server's max page; the sidebar's load-more follows
            // the cursor beyond it (accounts with 300+ chats).
            chats: { filter in try await api.chats(limit: 199, filter: filter) },
            contacts: { try await api.contacts() },
            startLink: { try await api.startLink() },
            logout: { try await api.logout() },
            messages: { chat in try await api.messages(chat: chat) },
            sendText: { chat, text, replyTo, mentionedJIDs in
                try await api.send(
                    chat: chat,
                    text: text,
                    replyTo: replyTo,
                    mentionedJids: mentionedJIDs
                )
            },
            markRead: { chat in try await api.markRead(chat: chat) },
            sendMedia: { chat, data, mime, filename, caption, replyTo in
                try await api.sendMedia(
                    chat: chat,
                    data: data,
                    mime: mime,
                    filename: filename,
                    caption: caption,
                    replyTo: replyTo
                )
            },
            connectEvents: { onEvent, onHeartbeat, onDisconnect, onGap in
                await api.connectEvents(
                    onEvent: onEvent,
                    onHeartbeat: onHeartbeat,
                    onDisconnect: onDisconnect,
                    onGap: onGap
                )
            },
            disconnectEvents: { await api.disconnectEvents() }
        )
    }

    func sessionInfo() async throws -> SessionInfo { try await sessionInfoOperation() }
    func chats(filter: String) async throws -> ChatsResponse { try await chatsOperation(filter) }
    func contacts() async throws -> [Contact] { try await contactsOperation() }
    func startLink() async throws { try await startLinkOperation() }
    func logout() async throws { try await logoutOperation() }
    func messages(chat: String) async throws -> MessagesResponse { try await messagesOperation(chat) }
    func sendText(chat: String, text: String,
                  replyTo: (id: String, sender: String)?,
                  mentionedJIDs: [String]) async throws -> Message {
        try await sendTextOperation(chat, text, replyTo, mentionedJIDs)
    }
    func markRead(chat: String) async throws { try await markReadOperation(chat) }
    func sendMedia(chat: String, data: Data, mime: String, filename: String,
                   caption: String,
                   replyTo: (id: String, sender: String)?) async throws -> Message {
        try await sendMediaOperation(chat, data, mime, filename, caption, replyTo)
    }

    func connectEvents(onEvent: @escaping (CoreEvent) -> Void,
                       onHeartbeat: @escaping () -> Void = {},
                       onDisconnect: @escaping () -> Void = {},
                       onGap: @escaping () -> Void = {}) async {
        await connectEventsOperation(onEvent, onHeartbeat, onDisconnect, onGap)
    }

    func disconnectEvents() async { await disconnectEventsOperation() }
}

/// Owns the one authoritative refresh task for an API client. AppState
/// supplies the API operations, keeping this lifecycle boundary deterministic
/// under test without coupling policies to URLSession or SwiftUI state.
@MainActor
final class ConnectionRefreshCoordinator<Client: AnyObject> {
    typealias Step = @MainActor (
        ConnectionRefreshStep,
        Client,
        ConnectionRefreshEpoch
    ) async -> ConnectionRefreshStepResult
    typealias LegacyStep = @MainActor (
        ConnectionRefreshStep,
        Client
    ) async -> ConnectionRefreshStepResult
    typealias Finished = @MainActor (Client) async -> Void
    typealias ContactLoad = @MainActor (Client) async -> Void
    typealias ChatOperation = @MainActor (
        Client,
        ChatRefreshLease
    ) async -> ChatRefreshResult
    typealias Sleep = @MainActor (TimeInterval) async -> Void

    private struct Authority {
        let epoch: ConnectionRefreshEpoch
    }

    private struct PendingChat {
        let filter: String
        let source: ChatRefreshSource
        let intentWatermark: UInt64
        let operation: ChatOperation
    }

    private struct ActiveChat {
        let lease: ChatRefreshLease
        let task: Task<ChatRefreshResult, Never>
    }

    private weak var client: Client?
    private var clientGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var reconnectBackoffActive = false
    private var chatEpoch: UInt64 = 0
    private var nextChatOperationID: UInt64 = 0
    private var latestIntentWatermark: UInt64 = 0
    private var requiredAuthority: Authority?
    private var activeChat: ActiveChat?
    private var pendingChat: PendingChat?
    private var contactTasks: [Task<Void, Never>] = []
    private var contactsStartedForGeneration: UInt64?
    private var recoveryAttemptAvailable = false
    private(set) var recoveryNeeded = false

    private let sleep: Sleep

    init(sleep: @escaping Sleep = { delay in
        try? await Task.sleep(for: .seconds(delay))
    }) {
        self.sleep = sleep
    }

    var isRefreshing: Bool { refreshTask != nil }
    var coalescesExternalChatRefresh: Bool {
        isRefreshing || reconnectBackoffActive || requiredAuthority != nil
    }

    func isCurrent(_ client: Client) -> Bool {
        self.client === client
    }

    func install(_ client: Client) {
        cancel()
        self.client = client
        clientGeneration &+= 1
    }

    func cancel() {
        cancelRefresh()
        cancelChatOperation(clearActiveSlot: true)
        reconnectBackoffActive = false
        contactTasks.forEach { $0.cancel() }
        contactTasks.removeAll()
        contactsStartedForGeneration = nil
        client = nil
        recoveryNeeded = false
        recoveryAttemptAvailable = false
    }

    /// Invalidates current work while retaining client ownership for an
    /// event-driven logged-out -> re-link transition on the same REST client.
    func cancelWorkKeepingClient() {
        cancelRefresh()
        cancelChatOperation(clearActiveSlot: false)
        reconnectBackoffActive = false
        contactTasks.forEach { $0.cancel() }
        contactTasks.removeAll()
        contactsStartedForGeneration = nil
        recoveryNeeded = false
        recoveryAttemptAvailable = false
    }

    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration &+= 1
    }

    private func cancelChatOperation(clearActiveSlot: Bool) {
        chatEpoch &+= 1
        requiredAuthority = nil
        pendingChat = nil
        activeChat?.task.cancel()
        if clearActiveSlot { activeChat = nil }
    }

    private func reserveAuthority(_: ConnectionRefreshReason) -> ConnectionRefreshEpoch {
        cancelRefresh()
        chatEpoch &+= 1
        let epoch = ConnectionRefreshEpoch(value: chatEpoch)
        requiredAuthority = Authority(epoch: epoch)
        pendingChat = nil
        // Keep the slot until the invalidated operation actually returns.
        // The authoritative request waits for this task before starting, so
        // one API generation never has two observable /chats calls at once.
        activeChat?.task.cancel()
        return epoch
    }

    @discardableResult
    func beginReconnectBackoff() -> ConnectionRefreshEpoch {
        reconnectBackoffActive = true
        return reserveAuthority(.reconnect)
    }

    func endReconnectBackoff(_ epoch: ConnectionRefreshEpoch? = nil) {
        guard epoch == nil || requiredAuthority?.epoch == epoch else { return }
        reconnectBackoffActive = false
    }

    func accepts(_ lease: ChatRefreshLease, for client: Client) -> Bool {
        isCurrent(client)
            && lease.clientGeneration == clientGeneration
            && lease.chatEpoch == chatEpoch
            && activeChat?.lease.operationID == lease.operationID
    }

    /// The sole producer for `/chats`. Compatible observers join the current
    /// task; a freshness claim newer than its lease replaces one bounded
    /// trailing intent even when the filter matches. A reconnect authority
    /// blocks routine work until its post-gap request has drained the invalid
    /// pre-gap task and started in the reserved epoch.
    func runChat(client: Client,
                 filter: String,
                 source: ChatRefreshSource,
                 authoritativeEpoch: ConnectionRefreshEpoch? = nil,
                 operation: @escaping ChatOperation) async -> ChatRefreshResult {
        guard isCurrent(client) else { return .cancelled }
        if source.advancesFreshnessIntent { latestIntentWatermark &+= 1 }
        let intent = PendingChat(
            filter: filter,
            source: source,
            intentWatermark: latestIntentWatermark,
            operation: operation
        )

        if let authoritativeEpoch {
            guard requiredAuthority?.epoch == authoritativeEpoch else { return .cancelled }
            while let active = activeChat {
                if active.lease.authoritativeEpoch == authoritativeEpoch,
                   active.lease.filter == filter {
                    return await active.task.value
                }
                active.task.cancel()
                _ = await active.task.value
                guard isCurrent(client), requiredAuthority?.epoch == authoritativeEpoch else {
                    return .cancelled
                }
            }
            return await beginChat(intent, client: client, authoritativeEpoch: authoritativeEpoch).value
        }

        if let active = activeChat {
            if active.lease.clientGeneration == clientGeneration,
               active.lease.chatEpoch == chatEpoch,
               active.lease.filter == filter {
                if source.advancesFreshnessIntent {
                    // The matching endpoint started before this freshness
                    // claim. Replace the one bounded trailing slot instead
                    // of treating an older snapshot as satisfying it.
                    pendingChat = intent
                    return .queued
                }
                // An observer may join, but it cannot erase a freshness
                // claim that postdates this lease. Older/incompatible work
                // remains latest-key coalesced as before.
                if (pendingChat?.intentWatermark ?? 0) <= active.lease.startIntentWatermark {
                    pendingChat = nil
                }
                return await active.task.value
            }
            pendingChat = intent
            return .queued
        }

        if requiredAuthority != nil {
            pendingChat = intent
            return .queued
        }

        return await beginChat(intent, client: client, authoritativeEpoch: nil).value
    }

    private func beginChat(_ pending: PendingChat,
                           client: Client,
                           authoritativeEpoch: ConnectionRefreshEpoch?) -> Task<ChatRefreshResult, Never> {
        if pending.source == .recovery, authoritativeEpoch == nil,
           recoveryNeeded, recoveryAttemptAvailable {
            // Spend the one-shot only when this intent actually becomes the
            // endpoint owner. Queued/joined recovery intents spend nothing.
            recoveryAttemptAvailable = false
        }
        nextChatOperationID &+= 1
        let lease = ChatRefreshLease(
            operationID: nextChatOperationID,
            clientGeneration: clientGeneration,
            chatEpoch: chatEpoch,
            startIntentWatermark: latestIntentWatermark,
            filter: pending.filter,
            source: pending.source,
            authoritativeEpoch: authoritativeEpoch
        )
        let task: Task<ChatRefreshResult, Never> = Task { [weak self, weak client] in
            guard let self, let client else { return ChatRefreshResult.cancelled }
            let result = await pending.operation(client, lease)
            return self.finishChat(lease, result: result)
        }
        activeChat = ActiveChat(lease: lease, task: task)
        return task
    }

    private func finishChat(_ lease: ChatRefreshLease,
                            result: ChatRefreshResult) -> ChatRefreshResult {
        guard activeChat?.lease.operationID == lease.operationID else { return .cancelled }
        let accepted = lease.clientGeneration == clientGeneration && lease.chatEpoch == chatEpoch
        let finalResult = accepted ? result : .cancelled
        activeChat = nil

        if let authority = lease.authoritativeEpoch,
           requiredAuthority?.epoch == authority {
            requiredAuthority = nil
            reconnectBackoffActive = false
            if let pending = pendingChat,
               pending.filter == lease.filter,
               pending.intentWatermark <= lease.startIntentWatermark {
                // An intent queued before this authoritative endpoint began
                // is covered by its snapshot. A post-start intent survives.
                pendingChat = nil
            }
        }
        if finalResult == .succeeded { recordChatRefreshSucceeded() }

        if requiredAuthority == nil, let pending = pendingChat, let client {
            pendingChat = nil
            _ = beginChat(pending, client: client, authoritativeEpoch: nil)
        }
        return finalResult
    }

    private func finishAuthorityIfNeeded(_ epoch: ConnectionRefreshEpoch) {
        guard requiredAuthority?.epoch == epoch else { return }
        requiredAuthority = nil
        reconnectBackoffActive = false
        if activeChat == nil, let pending = pendingChat, let client {
            pendingChat = nil
            _ = beginChat(pending, client: client, authoritativeEpoch: nil)
        }
    }

    @discardableResult
    func start(_ reason: ConnectionRefreshReason, client: Client,
               epoch suppliedEpoch: ConnectionRefreshEpoch? = nil,
               step: @escaping Step,
               finished: @escaping Finished = { _ in }) -> Task<Void, Never> {
        cancelRefresh()
        let epoch: ConnectionRefreshEpoch
        if let suppliedEpoch {
            guard isCurrent(client), requiredAuthority?.epoch == suppliedEpoch else { return Task {} }
            epoch = suppliedEpoch
        } else {
            epoch = reserveAuthority(reason)
        }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let task = Task { [weak self, weak client] in
            guard let self, let client else { return }
            for refreshStep in ConnectionRefreshPlan.steps(for: reason) {
                guard !Task.isCancelled, self.isCurrent(client),
                      self.refreshGeneration == generation else { return }
                let result = await step(refreshStep, client, epoch)
                guard !Task.isCancelled, self.isCurrent(client),
                      self.refreshGeneration == generation else { return }
                if refreshStep == .chats, result == .chatFetchFailed {
                    self.recoveryNeeded = true
                    self.recoveryAttemptAvailable = true
                }
                if refreshStep == .chats { self.finishAuthorityIfNeeded(epoch) }
                guard result != .cancelled else { return }
            }
            guard !Task.isCancelled, self.isCurrent(client),
                  self.refreshGeneration == generation else { return }
            await finished(client)
            guard !Task.isCancelled, self.isCurrent(client),
                  self.refreshGeneration == generation else { return }
            self.refreshTask = nil
        }
        refreshTask = task
        return task
    }

    @discardableResult
    func start(_ reason: ConnectionRefreshReason, client: Client,
               step: @escaping LegacyStep,
               finished: @escaping Finished = { _ in }) -> Task<Void, Never> {
        start(reason, client: client, step: { refreshStep, capturedClient, _ in
            await step(refreshStep, capturedClient)
        }, finished: finished)
    }

    func activateContactsIfNeeded(for client: Client, isConnected: Bool,
                                  load: @escaping ContactLoad) {
        guard isConnected, isCurrent(client), contactsStartedForGeneration != clientGeneration else { return }
        contactsStartedForGeneration = clientGeneration
        contactTasks.append(Task { [weak self, weak client] in
            guard let self, let client,
                  !Task.isCancelled, self.isCurrent(client) else { return }
            await load(client)
            guard !Task.isCancelled, self.isCurrent(client) else { return }
        })
        for delay in ContactFollowUpPolicy.delays {
            contactTasks.append(Task { [weak self, weak client] in
                guard let self, let client,
                      !Task.isCancelled, self.isCurrent(client) else { return }
                await self.sleep(delay)
                guard !Task.isCancelled, self.isCurrent(client) else { return }
                await load(client)
                guard !Task.isCancelled, self.isCurrent(client) else { return }
            })
        }
    }

    /// A failed authoritative fetch earns one later fallback attempt even if
    /// the WebSocket is fresh. Repeated failures do not turn into a poll loop.
    func recoveryPollAction(now: Date, lastActivityAt: Date?,
                            connectionState: String) -> RecoveryPollAction {
        if recoveryNeeded, recoveryAttemptAvailable {
            guard !isRefreshing, requiredAuthority == nil, activeChat == nil else {
                return .deferredRecovery
            }
            recoveryAttemptAvailable = false
            return .recoveryChat
        }
        return WebSocketFreshnessPolicy.shouldPoll(
            now: now,
            lastActivityAt: lastActivityAt,
            connectionState: connectionState
        ) ? .fallback : .suppressed
    }

    private func recordChatRefreshSucceeded() {
        recoveryNeeded = false
        recoveryAttemptAvailable = false
    }
}
