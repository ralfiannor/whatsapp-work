import AppKit
import Combine
import Foundation

enum PasteRoute: Equatable {
    case attachment
    case responder
}

enum PasteRoutingPolicy {
    static func route(composerFocused: Bool, hasAttachment: Bool) -> PasteRoute {
        composerFocused && hasAttachment ? .attachment : .responder
    }
}

enum ChatOpenSource: CaseIterable {
    case keyboardSelection, enter, mouse, transcriptFocus, composerFocus
    case selectionChange
    case search, inbox, notification, deepLink

    var acknowledgesRead: Bool { self != .keyboardSelection }
}

/// DM read-receipt suppression is a privacy setting; group chats always
/// send (their receipts are invisible to senders anyway).
enum ReadReceiptPolicy {
    static func shouldSendReceipt(chatJID: String, suppressDMReceipts: Bool) -> Bool {
        chatJID.hasSuffix("@g.us") || !suppressDMReceipts
    }
}

struct ReadCommitGate {
    private var inFlight: Set<String> = []

    mutating func begin(_ chatJID: String, unreadCount: Int) -> Bool {
        guard unreadCount > 0, !inFlight.contains(chatJID) else { return false }
        inFlight.insert(chatJID)
        return true
    }

    mutating func finish(_ chatJID: String) {
        inFlight.remove(chatJID)
    }
}

struct LiveUnreadState {
    private var counts: [String: Int] = [:]

    mutating func observe(_ chatJID: String, unreadCount: Int) {
        counts[chatJID] = unreadCount
    }

    func value(for chatJID: String) -> Int? {
        counts[chatJID]
    }

    func count(for chatJID: String) -> Int {
        counts[chatJID, default: 0]
    }

    mutating func markReadSucceeded(_ chatJID: String) {
        counts[chatJID] = 0
    }
}

struct PreviewLoadRequest: Equatable {
    fileprivate let id: Int
    let chatJID: String
    let anchorMessageID: String?

    static func == (lhs: PreviewLoadRequest, rhs: PreviewLoadRequest) -> Bool {
        lhs.id == rhs.id && lhs.chatJID == rhs.chatJID
    }
}

struct PreviewLoadCoordinator {
    private struct State {
        var request: PreviewLoadRequest
        var claimed = false
    }

    private var nextID = 0
    private var selectedRequestID: Int?
    private var requests: [String: State] = [:]
    private var suppressedSelectionLoads: Set<String> = []

    mutating func request(chatJID: String, anchorMessageID: String?) -> PreviewLoadRequest {
        suppressedSelectionLoads.removeAll()
        let request = activate(chatJID: chatJID, anchorMessageID: anchorMessageID)
        suppressedSelectionLoads.insert(chatJID)
        return request
    }

    mutating func selectionRequest(chatJID: String) -> PreviewLoadRequest? {
        if suppressedSelectionLoads.remove(chatJID) != nil { return nil }
        suppressedSelectionLoads.removeAll()
        return activate(chatJID: chatJID, anchorMessageID: nil)
    }

    private mutating func activate(
        chatJID: String,
        anchorMessageID: String?
    ) -> PreviewLoadRequest {
        if var state = requests[chatJID] {
            if state.request.anchorMessageID == nil, let anchorMessageID {
                state.request = PreviewLoadRequest(
                    id: state.request.id,
                    chatJID: chatJID,
                    anchorMessageID: anchorMessageID
                )
                requests[chatJID] = state
            }
            selectedRequestID = state.request.id
            return state.request
        }
        nextID += 1
        let request = PreviewLoadRequest(
            id: nextID,
            chatJID: chatJID,
            anchorMessageID: anchorMessageID
        )
        requests[chatJID] = State(request: request)
        selectedRequestID = request.id
        return request
    }

    mutating func claim(_ request: PreviewLoadRequest) -> Bool {
        guard var state = requests[request.chatJID], state.request == request,
              !state.claimed else { return false }
        state.claimed = true
        requests[request.chatJID] = state
        return true
    }

    func isCurrent(_ request: PreviewLoadRequest) -> Bool {
        selectedRequestID == request.id && requests[request.chatJID]?.request == request
    }

    mutating func finish(_ request: PreviewLoadRequest) {
        guard requests[request.chatJID]?.request == request else { return }
        requests.removeValue(forKey: request.chatJID)
    }
}

struct UnreadBoundary: Equatable {
    let rowID: Int64?
    let count: Int
}

/// Canonical oldest-to-newest transcript order. WhatsApp timestamps are only
/// second-granular, so the SQLite row ID is the required deterministic tie
/// breaker everywhere a production message array is assembled.
enum MessageTimelineOrder {
    static func precedes(_ lhs: Message, _ rhs: Message) -> Bool {
        lhs.timestamp < rhs.timestamp
            || (lhs.timestamp == rhs.timestamp && lhs.id < rhs.id)
    }

    static func ordered(_ messages: [Message]) -> [Message] {
        guard messages.count > 1 else { return messages }
        for index in messages.indices.dropFirst() {
            let previous = messages.index(before: index)
            if precedes(messages[index], messages[previous]) {
                return messages.sorted(by: precedes)
            }
        }
        return messages
    }

    /// REST pages are newest-first; retained transcripts are canonical
    /// oldest-first. Merge in O(page + window), letting fetched durable rows
    /// own duplicate IDs and preserving every local negative row.
    static func mergingOlderPage(_ descendingPage: [Message], into current: [Message]) -> [Message] {
        let page = Array(descendingPage.reversed())
        let pageIDs = Set(page.map(\.id))
        var merged: [Message] = []
        merged.reserveCapacity(page.count + current.count)
        var older = 0
        var newer = 0
        while older < page.count && newer < current.count {
            let row = current[newer]
            if row.id >= 0 && pageIDs.contains(row.id) {
                newer += 1
            } else if precedes(row, page[older]) {
                merged.append(row)
                newer += 1
            } else {
                merged.append(page[older])
                older += 1
            }
        }
        merged.append(contentsOf: page[older...])
        for row in current[newer...] where row.id < 0 || !pageIDs.contains(row.id) {
            merged.append(row)
        }
        return merged
    }

    static func sort(_ messages: inout [Message]) {
        messages.sort(by: precedes)
    }
}

enum ReadCommitResult: Equatable {
    case skipped, succeeded, failed
}

@MainActor
final class ReadCommitAction {
    private var gate = ReadCommitGate()
    private var unread = LiveUnreadState()
    private(set) var lastErrorDescription: String?

    func observe(_ chatJID: String, unreadCount: Int) {
        unread.observe(chatJID, unreadCount: unreadCount)
    }

    func value(for chatJID: String) -> Int? {
        unread.value(for: chatJID)
    }

    func commit(
        chatJID: String,
        source: ChatOpenSource,
        fallbackUnreadCount: Int,
        request: () async throws -> Void,
        onSuccess: () -> Void
    ) async -> ReadCommitResult {
        guard source.acknowledgesRead else { return .skipped }
        let unreadCount = unread.value(for: chatJID) ?? fallbackUnreadCount
        unread.observe(chatJID, unreadCount: unreadCount)
        guard gate.begin(chatJID, unreadCount: unreadCount) else { return .skipped }
        defer { gate.finish(chatJID) }
        do {
            try await request()
            unread.markReadSucceeded(chatJID)
            lastErrorDescription = nil
            onSuccess()
            return .succeeded
        } catch {
            lastErrorDescription = error.localizedDescription
            return .failed
        }
    }
}

enum UnreadBoundaryPolicy {
    static func resolve(unreadCount: Int, messages: [Message]) -> UnreadBoundary? {
        guard unreadCount > 0 else { return nil }
        // Production arrays are already canonical; `ordered` verifies that
        // in O(n) and only falls back to sorting malformed/test input.
        let ordered = MessageTimelineOrder.ordered(messages)
        let incomingCount = ordered.reduce(into: 0) { count, message in
            if !message.from_me { count += 1 }
        }
        guard incomingCount >= unreadCount else {
            return .init(rowID: nil, count: unreadCount)
        }
        var incomingToSkip = incomingCount - unreadCount
        for message in ordered where !message.from_me {
            if incomingToSkip == 0 {
                return .init(rowID: message.id, count: unreadCount)
            }
            incomingToSkip -= 1
        }
        return .init(rowID: nil, count: unreadCount)
    }

    /// Re-resolves a session boundary as more rows arrive. Once a boundary
    /// has been captured, its historical count wins over the live counter:
    /// `/read` legitimately zeroes live state before a delayed preview or a
    /// duplicate focus action finishes.
    static func refresh(
        existing: UnreadBoundary?,
        liveUnreadCount: Int?,
        messages: [Message]
    ) -> UnreadBoundary? {
        let count = existing?.count ?? liveUnreadCount ?? 0
        guard count > 0 else { return existing }
        return resolve(unreadCount: count, messages: messages)
    }
}

enum UnreadMarkerPresentation: Equatable {
    case row(rowID: Int64, count: Int)
    case boundedTop(label: String, actionTitle: String)
}

enum UnreadMarkerPresenter {
    static func presentation(
        for boundary: UnreadBoundary?,
        loadedMessageCount: Int
    ) -> UnreadMarkerPresentation? {
        guard let boundary else { return nil }
        if let rowID = boundary.rowID {
            return .row(rowID: rowID, count: boundary.count)
        }
        return .boundedTop(
            label: "\(boundary.count) unread · showing latest \(loadedMessageCount)",
            actionTitle: "Load Earlier"
        )
    }

}

/// One place deciding whether a scroll-to-top event may fetch the next older
/// page. Extracted from the view so the trigger wiring (scroll monitor,
/// button) all passes through the same rules. Unread-heavy chats are
/// included: the transition-based trigger loads one page per reach-top, so
/// there is no eager chain to guard against anymore.
enum AutomaticTopPagingDecision {
    static func shouldLoad(jumping: Bool,
                           loadingOlder: Bool,
                           messageCount: Int) -> Bool {
        guard !jumping, !loadingOlder else { return false }
        // A short first page means the whole history is already loaded.
        guard messageCount >= 50 else { return false }
        return true
    }
}

struct ChatReplySendOperation: Equatable {
    let message: Message
    fileprivate let chatJID: String
    fileprivate let generation: Int
}

struct ChatReplyStore {
    private struct Entry {
        let message: Message
        let generation: Int
    }

    private var replies: [String: Entry] = [:]
    private var generations: [String: Int] = [:]

    func reply(for chatJID: String) -> Message? {
        guard let entry = replies[chatJID], entry.message.chat_jid == chatJID else { return nil }
        return entry.message
    }

    mutating func set(_ message: Message, for chatJID: String) {
        let generation = nextGeneration(for: chatJID)
        guard message.chat_jid == chatJID else {
            replies.removeValue(forKey: chatJID)
            return
        }
        replies[chatJID] = Entry(message: message, generation: generation)
    }

    mutating func take(for chatJID: String) -> Message? {
        let message = reply(for: chatJID)
        clear(chatJID)
        return message
    }

    /// Peek for a media send without consuming the banner. The generation
    /// makes a later success conditional on this exact target still being
    /// current after the upload await.
    func mediaSendOperation(for chatJID: String) -> ChatReplySendOperation? {
        guard let entry = replies[chatJID], entry.message.chat_jid == chatJID else { return nil }
        return ChatReplySendOperation(
            message: entry.message,
            chatJID: chatJID,
            generation: entry.generation
        )
    }

    @discardableResult
    mutating func completeMediaSend(
        _ operation: ChatReplySendOperation?,
        for chatJID: String
    ) -> Bool {
        guard let operation,
              operation.chatJID == chatJID,
              let entry = replies[chatJID],
              entry.generation == operation.generation,
              entry.message == operation.message else { return false }
        _ = nextGeneration(for: chatJID)
        replies.removeValue(forKey: chatJID)
        return true
    }

    mutating func clear(_ chatJID: String? = nil) {
        if let chatJID {
            _ = nextGeneration(for: chatJID)
            replies.removeValue(forKey: chatJID)
        } else {
            for key in Array(replies.keys) {
                _ = nextGeneration(for: key)
            }
            replies.removeAll()
        }
    }

    private mutating func nextGeneration(for chatJID: String) -> Int {
        generations[chatJID, default: 0] += 1
        return generations[chatJID, default: 0]
    }
}

enum RetryOwnershipPolicy {
    static func chat(for message: Message) -> String? {
        guard message.from_me, message.receipt_status == "failed",
              let text = message.text, !text.isEmpty else { return nil }
        return message.chat_jid
    }
}

enum MentionInsertionPolicy {
    static func owningChat(forMemberJID: String, in groupChatJID: String) -> String? {
        guard groupChatJID.hasSuffix("@g.us"), groupChatJID != forMemberJID else { return nil }
        return groupChatJID
    }
}

@MainActor
struct MemberMentionActionRouter {
    private let setMentionTarget: (_ memberJID: String, _ label: String, _ chatJID: String) -> Void
    private let queueInsertion: (_ label: String) -> Void

    init(
        setMentionTarget: @escaping (_ memberJID: String, _ label: String, _ chatJID: String) -> Void,
        queueInsertion: @escaping (_ label: String) -> Void
    ) {
        self.setMentionTarget = setMentionTarget
        self.queueInsertion = queueInsertion
    }

    func fromMemberRow(memberJID: String, label: String, groupChatJID: String) {
        insert(memberJID: memberJID, label: label, groupChatJID: groupChatJID)
    }

    func fromMemberContextMenu(memberJID: String, label: String, groupChatJID: String) {
        insert(memberJID: memberJID, label: label, groupChatJID: groupChatJID)
    }

    func fromProfile(memberJID: String, label: String, groupChatJID: String) {
        insert(memberJID: memberJID, label: label, groupChatJID: groupChatJID)
    }

    private func insert(memberJID: String, label: String, groupChatJID: String) {
        guard let owningChat = MentionInsertionPolicy.owningChat(
            forMemberJID: memberJID,
            in: groupChatJID
        ) else { return }
        setMentionTarget(memberJID, label, owningChat)
        queueInsertion(label)
    }
}

struct ChatMentionGenerationStore {
    private var generations: [String: Int] = [:]

    func generation(for chatJID: String) -> Int {
        generations[chatJID, default: 0]
    }

    @discardableResult
    mutating func rearm(_ chatJID: String) -> Int {
        generations[chatJID, default: 0] += 1
        return generations[chatJID, default: 0]
    }

    func isCurrent(_ generation: Int, for chatJID: String) -> Bool {
        self.generation(for: chatJID) == generation
    }
}

struct ComposerMediaSendOperation: Equatable {
    let chatJID: String
    let draft: String
    let attachmentURL: URL
    fileprivate let generation: Int
    fileprivate let submissionID: UInt64
}

struct ComposerMediaSendCompletion: Equatable {
    let clearsOwnerDraft: Bool
    let clearsVisibleDraft: Bool
    let clearsVisibleAttachment: Bool

    init(clearsOwnerDraft: Bool, clearsVisibleDraft: Bool,
         clearsVisibleAttachment: Bool = false) {
        self.clearsOwnerDraft = clearsOwnerDraft
        self.clearsVisibleDraft = clearsVisibleDraft
        self.clearsVisibleAttachment = clearsVisibleAttachment
    }
}

/// Tracks which exact chat-owned composition an asynchronous media send
/// represents. A completion may clear the owner's stored caption while a
/// different chat is visible, but it may mutate the shared ComposerBar state
/// only while that same draft is displayed. Navigation can remove the
/// attachment while preserving the draft, so those clear decisions are separate.
struct ComposerMediaSendTracker {
    private var generations: [String: Int] = [:]
    private var nextSubmissionID: UInt64 = 0
    private var activeSubmissionID: UInt64?

    var isSubmitting: Bool { activeSubmissionID != nil }

    mutating func begin(
        chatJID: String,
        draft: String,
        attachmentURL: URL
    ) -> ComposerMediaSendOperation? {
        guard activeSubmissionID == nil else { return nil }
        nextSubmissionID &+= 1
        let submissionID = nextSubmissionID
        activeSubmissionID = submissionID
        generations[chatJID, default: 0] += 1
        return ComposerMediaSendOperation(
            chatJID: chatJID,
            draft: draft,
            attachmentURL: attachmentURL,
            generation: generations[chatJID, default: 0],
            submissionID: submissionID
        )
    }

    mutating func noteCompositionChanged(for chatJID: String) {
        generations[chatJID, default: 0] += 1
    }

    mutating func completion(
        for operation: ComposerMediaSendOperation,
        succeeded: Bool,
        ownerDraft: String?,
        visibleChatJID: String,
        visibleDraft: String,
        visibleAttachmentURL: URL?
    ) -> ComposerMediaSendCompletion {
        guard activeSubmissionID == operation.submissionID else {
            return ComposerMediaSendCompletion(
                clearsOwnerDraft: false,
                clearsVisibleDraft: false
            )
        }
        activeSubmissionID = nil
        guard succeeded else {
            return ComposerMediaSendCompletion(
                clearsOwnerDraft: false,
                clearsVisibleDraft: false
            )
        }
        let ownsCurrentComposition = generations[operation.chatJID] == operation.generation
            && (ownerDraft ?? "") == operation.draft
        guard ownsCurrentComposition else {
            return ComposerMediaSendCompletion(
                clearsOwnerDraft: false,
                clearsVisibleDraft: false
            )
        }
        let isDraftDisplayed = visibleChatJID == operation.chatJID
            && visibleDraft == operation.draft
        return ComposerMediaSendCompletion(
            clearsOwnerDraft: true,
            clearsVisibleDraft: isDraftDisplayed,
            clearsVisibleAttachment: isDraftDisplayed && visibleAttachmentURL == operation.attachmentURL
        )
    }
}

struct ComposerMediaSubmitRequest: Equatable {
    let chatJID: String
    let attachmentURL: URL
    let caption: String
}

struct ComposerMediaCompositionSnapshot: Equatable {
    let ownerDraft: String?
    let visibleChatJID: String
    let visibleDraft: String
    let visibleAttachmentURL: URL?
}

struct ComposerMediaSubmitOutcome: Equatable {
    let accepted: Bool
    let succeeded: Bool
    let completion: ComposerMediaSendCompletion
}

/// Owns the complete attachment-submit lifecycle used by ComposerBar. The
/// synchronous reservation happens before `send` can reach the detached file
/// loader, so queued button/keyboard actions cannot advance composition state
/// or allocate a second attachment buffer.
@MainActor
final class ComposerMediaSubmitAction: ObservableObject {
    @Published private(set) var isSubmitting = false
    private var tracker = ComposerMediaSendTracker()

    func noteCompositionChanged(for chatJID: String) {
        tracker.noteCompositionChanged(for: chatJID)
    }

    func submit(
        chatJID: String,
        draft: String,
        attachmentURL: URL,
        caption: String,
        send: @MainActor (ComposerMediaSubmitRequest) async -> Bool,
        completionState: @MainActor () -> ComposerMediaCompositionSnapshot
    ) async -> ComposerMediaSubmitOutcome {
        guard let operation = tracker.begin(
            chatJID: chatJID,
            draft: draft,
            attachmentURL: attachmentURL
        ) else {
            return ComposerMediaSubmitOutcome(
                accepted: false,
                succeeded: false,
                completion: ComposerMediaSendCompletion(
                    clearsOwnerDraft: false,
                    clearsVisibleDraft: false
                )
            )
        }

        isSubmitting = true
        let request = ComposerMediaSubmitRequest(
            chatJID: operation.chatJID,
            attachmentURL: operation.attachmentURL,
            caption: caption
        )
        let succeeded = await send(request)
        let snapshot = completionState()
        let completion = tracker.completion(
            for: operation,
            succeeded: succeeded,
            ownerDraft: snapshot.ownerDraft,
            visibleChatJID: snapshot.visibleChatJID,
            visibleDraft: snapshot.visibleDraft,
            visibleAttachmentURL: snapshot.visibleAttachmentURL
        )
        isSubmitting = tracker.isSubmitting
        return ComposerMediaSubmitOutcome(
            accepted: true,
            succeeded: succeeded,
            completion: completion
        )
    }
}

@MainActor
struct ResponderActionDispatcher {
    enum Action {
        case cut, copy, paste, pasteAndMatchStyle

        var selector: Selector {
            switch self {
            case .cut: Selector(("cut:"))
            case .copy: Selector(("copy:"))
            case .paste: Selector(("paste:"))
            case .pasteAndMatchStyle: Selector(("pasteAsPlainText:"))
            }
        }
    }

    private let sender: (Selector) -> Bool

    init(sender: @escaping (Selector) -> Bool = {
        NSApp.sendAction($0, to: nil, from: nil)
    }) {
        self.sender = sender
    }

    @discardableResult
    func perform(_ action: Action) -> Bool {
        sender(action.selector)
    }
}
