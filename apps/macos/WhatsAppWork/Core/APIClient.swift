// APIClient speaks the core's localhost HTTP+WS contract
// (docs/protocol.md). Bearer token comes from the sidecar handshake and is
// never persisted. Events are hints; REST is the source of truth.
import Foundation

// MARK: - Wire models (mirror core/internal/core/types.go JSON tags)

struct Chat: Codable, Identifiable, Equatable {
    var id: String { jid }
    let jid: String
    let kind: String
    let display_name: String
    var last_message_ts: Int64?
    var last_preview: String?
    var unread_count: Int
    var mentioned_unread: Int
    var is_pinned: Bool
    let is_muted: Bool
    var is_starred: Bool?
    var is_work: Bool?
    /// Peer's @lid twin (direct chats); stamped server-side from the lid map.
    var lid: String?
}

struct MessageMedia: Codable, Equatable {
    let id: String
    let kind: String
    let mime: String
    let size: Int64
    var filename: String?
    var state: String
    var local_path: String?
}

struct Message: Codable, Identifiable, Equatable {
    let id: Int64
    let message_id: String
    let chat_jid: String
    let sender_jid: String
    let from_me: Bool
    let timestamp: Int64
    let kind: String
    var text: String?
    var reply_to_id: String?
    var reply_to_sender: String?
    var quoted_text: String?
    let has_mention: Bool
    var mentioned_jids: [String]?
    var receipt_status: String?
    let revoked: Bool
    var forwarded: Bool?
    var edited_ts: Int64?
    // Local work-inbox state (LEFT JOIN on message reads). Optional: cores
    // from before this field existed omit them.
    var starred: Bool?
    var done: Bool?
    var raw_kind: String?
    var media: MessageMedia?
    var reactions: [Reaction]?
}

struct Reaction: Codable, Equatable {
    let reactor_jid: String
    let emoji: String
}

struct InboxItem: Codable, Identifiable, Equatable {
    var id: String { message_id }
    let message_id: String
    let rowid: Int64
    let chat_jid: String
    let chat_name: String
    let sender_jid: String
    let timestamp: Int64
    var text: String?
    let has_mention: Bool
    let starred: Bool
}

/// One actionable conversation: the chat plus a digest of its pending items.
struct InboxConversation: Codable, Identifiable, Equatable {
    var id: String { chat_jid }
    let chat_jid: String
    let chat_name: String
    let kind: String
    let is_work: Bool
    let is_starred: Bool
    let last_message_id: String
    let last_rowid: Int64
    let last_sender_jid: String
    var last_text: String?
    let last_kind: String
    let last_timestamp: Int64
    let has_mention: Bool
    let count: Int
}

struct InboxCounts: Codable, Equatable {
    let total: Int
    let mentions: Int
    let direct: Int
    let work: Int
}

struct Inbox: Codable, Equatable {
    var mentions: [InboxConversation]
    var direct_messages: [InboxConversation]
    var work_groups: [InboxConversation]
    var starred_chats: [Chat]
    var done_recent: [InboxItem]
    let counts: InboxCounts

    // Tolerate JSON nulls for empty sections (older cores emit null slices).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mentions = try c.decodeIfPresent([InboxConversation].self, forKey: .mentions) ?? []
        direct_messages = try c.decodeIfPresent([InboxConversation].self, forKey: .direct_messages) ?? []
        work_groups = try c.decodeIfPresent([InboxConversation].self, forKey: .work_groups) ?? []
        starred_chats = try c.decodeIfPresent([Chat].self, forKey: .starred_chats) ?? []
        done_recent = try c.decodeIfPresent([InboxItem].self, forKey: .done_recent) ?? []
        counts = try c.decode(InboxCounts.self, forKey: .counts)
    }
}

struct ChatsResponse: Codable { let chats: [Chat]; let next_cursor: String? }
struct MessagesResponse: Codable { let messages: [Message]; let next_cursor: String? }

struct SessionInfo: Codable {
    let state: String
    var account: String?
    var qr: QRInfo?
    var sync: SyncInfo?
    struct QRInfo: Codable { let code: String; let expires_ts: Int64 }
    struct SyncInfo: Codable { let stage: String; let progress: Double }
}

struct SearchResponse: Codable {
	struct Hit: Codable, Identifiable {
		var id: Int64 { rowid }
		let rowid: Int64
		let message_id: String?
		let chat_jid: String
		let timestamp: Int64
		let kind: String
		let snippet: String
	}
    let messages: [Hit]
    let chats: [Chat]
    let contacts: [Contact]
}

struct Contact: Codable, Identifiable, Equatable {
    var id: String { jid }
    let jid: String
    var full_name: String?
    var push_name: String?
    var business_name: String?
}

struct APIError: Codable {
    struct Inner: Codable { let code: String; let message: String }
    let error: Inner
}

// MARK: - Events

enum CoreEvent: Equatable {
    case connectionChanged(state: String, reason: String?)
    case qr(code: String, expires: Int64)
    case syncProgress(stage: String, progress: Double)
    case messageReceived(Message)
    case messageUpdated(Message)
    case chatUpdated(Chat)
    case chatRemoved(String)
    case contactsUpdated(changed: Int?)
    case inboxChanged(reason: String?)
    case reaction(rowid: Int64, emoji: String)
    case mediaUpdated(rowid: Int64, chat: String, media: MessageMedia)
    case ping

    private struct ConnPayload: Decodable { let state: String; var reason: String? }
    private struct QRPayload: Decodable { let code: String; let expires_ts: Int64 }
    private struct SyncPayload: Decodable { let stage: String; let progress: Double }
    private struct MsgPayload: Decodable { let message: Message }
    private struct ChatPayload: Decodable { let chat: Chat }
    private struct RemovedPayload: Decodable { let jid: String }

    /// The old dictionary cast treated a missing, null, or non-object `data`
    /// value as `{}`. Keep that behavior for payloads containing only optional
    /// fields while still rejecting an object whose field has the wrong type.
    private struct ContactsUpdatedPayload: Decodable {
        var changed: Int?

        private enum CodingKeys: String, CodingKey { case changed }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                changed = nil
                return
            }
            changed = try container.decodeIfPresent(Int.self, forKey: .changed)
        }
    }

    private struct InboxChangedPayload: Decodable {
        var reason: String?

        private enum CodingKeys: String, CodingKey { case reason }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
                reason = nil
                return
            }
            reason = try container.decodeIfPresent(String.self, forKey: .reason)
        }
    }

    private struct ReactionPayload: Decodable { let message_rowid: Int64; var emoji: String? }
    private struct MediaPayload: Decodable {
        let message_rowid: Int64
        var chat_jid: String?
        var media: MessageMedia?
    }

    private struct Envelope: Decodable {
        let event: CoreEvent?

        private enum CodingKeys: String, CodingKey { case type, data }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let type = try container.decode(String.self, forKey: .type)
            switch type {
            case "connection.changed":
                let value = try container.decode(ConnPayload.self, forKey: .data)
                event = .connectionChanged(state: value.state, reason: value.reason)
            case "session.qr":
                let value = try container.decode(QRPayload.self, forKey: .data)
                event = .qr(code: value.code, expires: value.expires_ts)
            case "sync.progress":
                let value = try container.decode(SyncPayload.self, forKey: .data)
                event = .syncProgress(stage: value.stage, progress: value.progress)
            case "message.received":
                event = .messageReceived(try container.decode(MsgPayload.self, forKey: .data).message)
            case "message.updated":
                event = .messageUpdated(try container.decode(MsgPayload.self, forKey: .data).message)
            case "chat.updated":
                event = .chatUpdated(try container.decode(ChatPayload.self, forKey: .data).chat)
            case "chat.removed":
                event = .chatRemoved(try container.decode(RemovedPayload.self, forKey: .data).jid)
            case "contacts.updated":
                let value = try container.decodeIfPresent(ContactsUpdatedPayload.self, forKey: .data)
                event = .contactsUpdated(changed: value?.changed)
            case "inbox.changed":
                let value = try container.decodeIfPresent(InboxChangedPayload.self, forKey: .data)
                event = .inboxChanged(reason: value?.reason)
            case "reaction.received":
                let value = try container.decode(ReactionPayload.self, forKey: .data)
                event = .reaction(rowid: value.message_rowid, emoji: value.emoji ?? "")
            case "media.updated":
                let value = try container.decode(MediaPayload.self, forKey: .data)
                event = .mediaUpdated(rowid: value.message_rowid,
                                      chat: value.chat_jid ?? "",
                                      media: value.media ?? Self.emptyMedia)
            case "ping":
                event = .ping
            default:
                event = nil
            }
        }

        private static let emptyMedia = MessageMedia(
            id: "",
            kind: "",
            mime: "",
            size: 0,
            filename: nil,
            state: "not_downloaded",
            local_path: nil
        )
    }

    /// Decodes one WS frame with one typed JSON parse.
    static func decode(text: String) -> CoreEvent? {
        guard let data = text.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        return envelope.event
    }
}

// MARK: - Client

enum WebSocketFrame: Sendable {
    case text(String)
    case binary(Data)
}

/// The production socket boundary. Keeping receive/send/cancel together makes
/// terminal handling serial and gives tests a deterministic transport seam.
protocol WebSocketEventTask: AnyObject, Sendable {
    func start() async
    func receive() async throws -> WebSocketFrame
    func send(text: String) async throws
    func cancel() async
}

final class URLSessionWebSocketEventTask: WebSocketEventTask, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func start() async {
        task.resume()
    }

    func receive() async throws -> WebSocketFrame {
        switch try await task.receive() {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: return .binary(Data())
        }
    }

    func send(text: String) async throws {
        try await task.send(.string(text))
    }

    func cancel() async {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// A single reader for one socket. A pong is sent before the next receive is
/// armed; any terminal error cancels that exact task and reports once.
actor WebSocketEventPump {
    private let task: any WebSocketEventTask
    private let onEvent: (CoreEvent) async -> Void
    private let onHeartbeat: () async -> Void
    private let onDisconnect: () async -> Void
    private let onGap: () async -> Void
    private var terminal = false
    private var loopTask: Task<Void, Never>?
    /// Last envelope seq seen on this socket; a jump means the server-side
    /// dispatcher dropped events for us — the client must refetch.
    private var lastSeq: Int64?

    init(task: any WebSocketEventTask,
         onEvent: @escaping (CoreEvent) async -> Void,
         onHeartbeat: @escaping () async -> Void,
         onDisconnect: @escaping () async -> Void,
         onGap: @escaping () async -> Void = {}) {
        self.task = task
        self.onEvent = onEvent
        self.onHeartbeat = onHeartbeat
        self.onDisconnect = onDisconnect
        self.onGap = onGap
    }

    @discardableResult
    func start() async -> Task<Void, Never> {
        if let loopTask { return loopTask }
        if terminal { return Task {} }
        await task.start()
        if terminal { return Task {} }
        let loopTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }
        self.loopTask = loopTask
        return loopTask
    }

    func stop() async {
        guard !terminal else { return }
        terminal = true
        await task.cancel()
        loopTask?.cancel()
        loopTask = nil
    }

    private func receiveLoop() async {
        while !terminal, !Task.isCancelled {
            do {
                let frame = try await task.receive()
                guard !terminal, !Task.isCancelled else { return }
                guard case .text(let text) = frame else { continue }

                // Seq advances for EVERY envelope, ping included — and
                // crucially for frames whose event type we don't decode
                // yet: skipping them here would make every later event
                // look like a gap (spurious reconnect-refresh churn).
                if let seq = Self.envelopeSeq(text) {
                    if let lastSeq, seq > lastSeq + 1 {
                        await onGap()
                    }
                    lastSeq = seq
                }

                guard let event = CoreEvent.decode(text: text) else { continue }

                if case .ping = event {
                    do {
                        try await task.send(text: #"{"type":"pong"}"#)
                        guard !terminal, !Task.isCancelled else { return }
                        await onHeartbeat()
                    } catch {
                        await terminate()
                    }
                } else {
                    await onEvent(event)
                }
            } catch {
                await terminate()
            }
        }
        loopTask = nil
    }

    private func terminate() async {
        guard !terminal else { return }
        terminal = true
        await task.cancel()
        await onDisconnect()
        loopTask = nil
    }

    /// Minimal probe for the envelope's seq without a full event decode
    /// (the pump checks gaps before dispatch, ping envelopes included).
    private static func envelopeSeq(_ text: String) -> Int64? {
        struct Probe: Decodable { let seq: Int64? }
        guard let data = text.data(using: .utf8),
              let probe = try? JSONDecoder().decode(Probe.self, from: data)
        else { return nil }
        return probe.seq
    }
}

actor APIClient {
    private let base: URL
    private let token: String
    private let session: URLSession
    private var wsPump: WebSocketEventPump?
    private var wsOperationGeneration: UInt64 = 0
    private let webSocketTaskFactory: (URLRequest) -> any WebSocketEventTask

    init(base: URL, token: String) {
        self.base = base
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        self.session = session
        self.webSocketTaskFactory = { request in
            URLSessionWebSocketEventTask(task: session.webSocketTask(with: request))
        }
    }

    init(base: URL, token: String,
         webSocketTaskFactory: @escaping (URLRequest) -> any WebSocketEventTask) {
        self.base = base
        self.token = token
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: cfg)
        self.webSocketTaskFactory = webSocketTaskFactory
    }

    /// Test-only transport boundary for exercising the real REST adapter.
    /// Production construction continues to use the ephemeral configuration
    /// above, including the same localhost URL and bearer-auth behavior.
    init(base: URL, token: String, sessionConfiguration: URLSessionConfiguration) {
        self.base = base
        self.token = token
        let cfg = sessionConfiguration.copy() as? URLSessionConfiguration
            ?? sessionConfiguration
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg)
        self.session = session
        self.webSocketTaskFactory = { request in
            URLSessionWebSocketEventTask(task: session.webSocketTask(with: request))
        }
    }

    // MARK: REST

    /// Builds URLs with a proper query component. appendingPathComponent
    /// percent-escapes "?" — every queried endpoint 404'd through it.
    /// Constructed from scratch (never force-unwrapped): a crash here took
    /// the app down on every refresh.
    private func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = base.port
        comps.path = "/" + path
        comps.queryItems = query.isEmpty ? nil : query
        if let u = comps.url {
            return u
        }
        return base.appendingPathComponent(path) // unreachable fallback
    }

    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        // Absolute URLs (from url()) pass through; bare paths join the base.
        let target: URL
        if path.hasPrefix("http://"), let abs = URL(string: path) {
            target = abs
        } else {
            target = base.appendingPathComponent(path)
        }
        var req = URLRequest(url: target)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiErr = try? JSONDecoder().decode(APIError.self, from: data) {
                throw CoreAPIError.server(apiErr.error.code, apiErr.error.message)
            }
            throw CoreAPIError.server("http_\(http.statusCode)", String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func healthz() async throws -> Bool {
        _ = try await request("GET", "healthz")
        return true
    }

    func sessionInfo() async throws -> SessionInfo {
        try JSONDecoder().decode(SessionInfo.self, from: try await request("GET", "session"))
    }

    func startLink() async throws {
        _ = try await request("POST", "session/link", body: Data(#"{"mode":"qr"}"#.utf8))
    }

    func logout() async throws {
        _ = try await request("POST", "session/logout")
    }

    func chats(limit: Int = 50, cursor: String? = nil, filter: String = "all") async throws -> ChatsResponse {
        var q = [URLQueryItem(name: "limit", value: String(limit)),
                 URLQueryItem(name: "filter", value: filter)]
        if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try JSONDecoder().decode(ChatsResponse.self, from: try await request("GET", url("chats", q).absoluteString))
    }

    func messages(chat: String, before: String? = nil, limit: Int = 50) async throws -> MessagesResponse {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let before { q.append(URLQueryItem(name: "before", value: before)) }
        let u = url("chats/\(chat)/messages", q)
        return try JSONDecoder().decode(MessagesResponse.self, from: try await request("GET", u.absoluteString))
    }

    func send(chat: String, text: String, replyTo: (id: String, sender: String)? = nil,
              mentionedJids: [String] = []) async throws -> Message {
        struct Body: Codable {
            let chat_jid: String
            let text: String
            var reply_to: Reply?
            var mentioned_jids: [String]?
            struct Reply: Codable { let id: String; let sender: String }
        }
        let body = Body(chat_jid: chat, text: text,
                        reply_to: replyTo.map { .init(id: $0.id, sender: $0.sender) },
                        mentioned_jids: mentionedJids.isEmpty ? nil : mentionedJids)
        return try JSONDecoder().decode(Message.self, from: try await request("POST", "messages", body: try JSONEncoder().encode(body)))
    }

    struct GroupMember: Codable, Identifiable, Equatable {
        var id: String { jid }
        let jid: String
        var display_name: String?
        let role: String
        /// Alternate @lid form (LID-space groups): mention tokens must carry
        /// these digits there for the highlight to bind on receivers.
        var lid: String?
        var mentionDigits: String {
            if let lid, !lid.isEmpty {
                return String(lid.prefix(while: { $0 != "@" }))
            }
            return String(jid.prefix(while: { $0 != "@" }))
        }
    }

    struct UserProfile: Codable, Identifiable, Equatable {
        var id: String { jid }
        let jid: String
        var lid: String?
        var full_name: String?
        var push_name: String?
        var business_name: String?
        var role: String?
        var picture_url: String?
    }

    func groupMembers(chat jid: String) async throws -> [GroupMember] {
        struct Resp: Codable { let members: [GroupMember] }
        return try JSONDecoder().decode(Resp.self, from: try await request("GET", url("groups/\(jid)/members").absoluteString)).members
    }

    func profile(jid: String, group: String? = nil) async throws -> UserProfile {
        var q: [URLQueryItem] = []
        if let group { q.append(URLQueryItem(name: "group", value: group)) }
        return try JSONDecoder().decode(UserProfile.self,
                                        from: try await request("GET", url("contacts/\(jid)/profile", q).absoluteString))
    }

    /// Raw-bytes media upload: body = file bytes, Content-Type = mime.
    func sendMedia(chat: String, data: Data, mime: String, filename: String,
                   caption: String, replyTo: (id: String, sender: String)? = nil) async throws -> Message {
        var q = [URLQueryItem(name: "caption", value: caption),
                 URLQueryItem(name: "filename", value: filename)]
        if let replyTo {
            q.append(URLQueryItem(name: "reply_id", value: replyTo.id))
            q.append(URLQueryItem(name: "reply_sender", value: replyTo.sender))
        }
        let u = url("chats/\(chat)/media", q)
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreAPIError.server("send_media", String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(Message.self, from: data)
    }

    func markRead(chat: String) async throws {
        _ = try await request("POST", "chats/\(chat)/read")
    }

    func react(rowID: Int64, emoji: String) async throws {
        struct Body: Codable { let emoji: String }
        _ = try await request("POST", "messages/\(rowID)/react", body: try JSONEncoder().encode(Body(emoji: emoji)))
    }

    /// 5000 = server max. The full directory must arrive: the transcript's
    /// sender labels resolve through this map, and a truncated fetch showed
    /// everyone alphabetically past the cutoff as raw phone numbers (real
    /// bug at 2000 on a 3.5k-contact account). Beyond 5000 the fetch needs
    /// an on-demand jid lookup endpoint instead.
    func contacts(limit: Int = 5000) async throws -> [Contact] {
        struct Resp: Codable { let contacts: [Contact] }
        return try JSONDecoder().decode(Resp.self, from: try await request("GET", url("contacts", [URLQueryItem(name: "limit", value: String(limit))]).absoluteString)).contacts
    }

    func inbox(limit: Int = 100) async throws -> Inbox {
        let u = url("inbox", [URLQueryItem(name: "limit", value: String(limit))])
        return try JSONDecoder().decode(Inbox.self, from: try await request("GET", u.absoluteString))
    }

    func setMessageDone(rowID: Int64, done: Bool) async throws {
        struct B: Codable { let done: Bool }
        _ = try await request("POST", "messages/\(rowID)/done", body: try JSONEncoder().encode(B(done: done)))
    }

    /// Snoozes a message until an absolute unix timestamp (0 = clear).
    /// "Tomorrow 09:00" targets are computed here — calendar math stays where
    /// the calendar lives, the core just stores the deadline.
    func setMessageSnooze(rowID: Int64, until: Int64) async throws {
        struct B: Codable { let until: Int64 }
        _ = try await request("POST", "messages/\(rowID)/snooze", body: try JSONEncoder().encode(B(until: until)))
    }

    func setMessageStar(rowID: Int64, starred: Bool) async throws {
        struct B: Codable { let starred: Bool }
        _ = try await request("POST", "messages/\(rowID)/star", body: try JSONEncoder().encode(B(starred: starred)))
    }

    func setChatStar(jid: String, starred: Bool) async throws {
        struct B: Codable { let starred: Bool }
        _ = try await request("POST", "chats/\(jid)/star", body: try JSONEncoder().encode(B(starred: starred)))
    }

    func setChatWork(jid: String, work: Bool) async throws {
        struct B: Codable { let work: Bool }
        _ = try await request("POST", "chats/\(jid)/work", body: try JSONEncoder().encode(B(work: work)))
    }

    /// Conversation-level bulk actions: one Done clears every pending inbox
    /// item of the chat; the snooze deadline also holds future messages.
    func setChatDone(jid: String, done: Bool) async throws {
        struct B: Codable { let done: Bool }
        _ = try await request("POST", "chats/\(jid)/done", body: try JSONEncoder().encode(B(done: done)))
    }

    func setChatSnooze(jid: String, until: Int64) async throws {
        struct B: Codable { let until: Int64 }
        _ = try await request("POST", "chats/\(jid)/snooze", body: try JSONEncoder().encode(B(until: until)))
    }

    func search(_ q: String, limit: Int = 25) async throws -> SearchResponse {
        let u = url("search", [URLQueryItem(name: "q", value: q),
                               URLQueryItem(name: "limit", value: String(limit))])
        return try JSONDecoder().decode(SearchResponse.self, from: try await request("GET", u.absoluteString))
    }

    func mediaDownload(rowID: Int64) async throws -> Message {
        struct Resp: Codable { let message: Message }
        return try JSONDecoder().decode(Resp.self, from: try await request("POST", "media/\(rowID)/download")).message
    }

    /// Fetches media bytes with auth (AsyncImage can't send headers on loopback).
    /// Returns (data, contentType).
    func mediaData(rowID: Int64) async throws -> (Data, String) {
        var req = URLRequest(url: url("media/\(rowID)/file"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CoreAPIError.server("media_fetch", "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
        return (data, ct)
    }

    // MARK: WebSocket

    func connectEvents(onEvent: @escaping (CoreEvent) -> Void,
                       onHeartbeat: @escaping () -> Void = {},
                       onDisconnect: @escaping () -> Void = {},
                       onGap: @escaping () -> Void = {}) async {
        wsOperationGeneration &+= 1
        let operation = wsOperationGeneration
        if let previousPump = wsPump {
            await previousPump.stop()
        }
        guard wsOperationGeneration == operation else { return }
        var req = URLRequest(url: base.appendingPathComponent("ws"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let pump = WebSocketEventPump(
            task: webSocketTaskFactory(req),
            onEvent: { event in onEvent(event) },
            onHeartbeat: { onHeartbeat() },
            onDisconnect: { onDisconnect() },
            onGap: { onGap() }
        )
        _ = await pump.start()
        guard wsOperationGeneration == operation else {
            await pump.stop()
            return
        }
        wsPump = pump
    }

    func disconnectEvents() async {
        wsOperationGeneration &+= 1
        let operation = wsOperationGeneration
        guard let pump = wsPump else { return }
        await pump.stop()
        guard wsOperationGeneration == operation, wsPump === pump else { return }
        wsPump = nil
    }
}

enum CoreAPIError: LocalizedError {
    case server(String, String)
    var errorDescription: String? {
        if case .server(let code, let msg) = self { return "\(code): \(msg)" }
        return nil
    }
}
