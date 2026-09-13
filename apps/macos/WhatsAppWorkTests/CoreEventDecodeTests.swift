import XCTest
@testable import WhatsAppWork

final class CoreEventDecodeTests: XCTestCase {
    private let performanceFrame = #"{"type":"connection.changed","data":{"state":"connected","reason":"wake"}}"#

    func testEveryCurrentWireEventDecodesToItsTypedCase() {
        let media = MessageMedia(
            id: "media-42",
            kind: "image",
            mime: "image/jpeg",
            size: 1_024,
            filename: "photo.jpg",
            state: "downloaded",
            local_path: "/tmp/photo.jpg"
        )
        let message = Message(
            id: 42,
            message_id: "wamid-42",
            chat_jid: "chat@g.us",
            sender_jid: "sender@s.whatsapp.net",
            from_me: false,
            timestamp: 1_700_000_000,
            kind: "image",
            text: "hello",
            reply_to_id: "wamid-41",
            reply_to_sender: "quoted@s.whatsapp.net",
            quoted_text: "quoted",
            has_mention: true,
            mentioned_jids: ["self@s.whatsapp.net"],
            receipt_status: "read",
            revoked: false,
            forwarded: true,
            edited_ts: 1_700_000_001,
            starred: true,
            done: false,
            raw_kind: "imageMessage",
            media: media,
            reactions: [Reaction(reactor_jid: "reactor@s.whatsapp.net", emoji: "👍")]
        )
        let chat = Chat(
            jid: "chat@g.us",
            kind: "group",
            display_name: "Project",
            last_message_ts: 1_700_000_000,
            last_preview: "hello",
            unread_count: 2,
            mentioned_unread: 1,
            is_pinned: true,
            is_muted: false,
            is_starred: true,
            is_work: false,
            lid: "123@lid"
        )

        let messageJSON = #"{"id":42,"message_id":"wamid-42","chat_jid":"chat@g.us","sender_jid":"sender@s.whatsapp.net","from_me":false,"timestamp":1700000000,"kind":"image","text":"hello","reply_to_id":"wamid-41","reply_to_sender":"quoted@s.whatsapp.net","quoted_text":"quoted","has_mention":true,"mentioned_jids":["self@s.whatsapp.net"],"receipt_status":"read","revoked":false,"forwarded":true,"edited_ts":1700000001,"starred":true,"done":false,"raw_kind":"imageMessage","media":{"id":"media-42","kind":"image","mime":"image/jpeg","size":1024,"filename":"photo.jpg","state":"downloaded","local_path":"/tmp/photo.jpg"},"reactions":[{"reactor_jid":"reactor@s.whatsapp.net","emoji":"👍"}]}"#
        let chatJSON = #"{"jid":"chat@g.us","kind":"group","display_name":"Project","last_message_id":"wamid-42","last_message_ts":1700000000,"last_preview":"hello","unread_count":2,"mentioned_unread":1,"is_pinned":true,"is_muted":false,"is_archived":false,"is_starred":true,"is_work":false,"lid":"123@lid"}"#
        let mediaJSON = #"{"id":"media-42","kind":"image","mime":"image/jpeg","size":1024,"filename":"photo.jpg","state":"downloaded","local_path":"/tmp/photo.jpg"}"#
        let cases: [(label: String, frame: String, expected: CoreEvent)] = [
            ("connection.changed", #"{"type":"connection.changed","seq":1,"data":{"state":"connected","reason":"wake"}}"#,
             .connectionChanged(state: "connected", reason: "wake")),
            ("session.qr", #"{"type":"session.qr","seq":2,"data":{"code":"qr-code","expires_ts":1700000030}}"#,
             .qr(code: "qr-code", expires: 1_700_000_030)),
            ("sync.progress", #"{"type":"sync.progress","seq":3,"data":{"stage":"messages","progress":62.5}}"#,
             .syncProgress(stage: "messages", progress: 62.5)),
            ("message.received", #"{"type":"message.received","seq":4,"data":{"message":\#(messageJSON)}}"#,
             .messageReceived(message)),
            ("message.updated", #"{"type":"message.updated","seq":5,"data":{"message":\#(messageJSON)}}"#,
             .messageUpdated(message)),
            ("chat.updated", #"{"type":"chat.updated","seq":6,"data":{"chat":\#(chatJSON)}}"#,
             .chatUpdated(chat)),
            ("chat.removed", #"{"type":"chat.removed","seq":7,"data":{"jid":"stale@lid"}}"#,
             .chatRemoved("stale@lid")),
            ("contacts.updated", #"{"type":"contacts.updated","seq":8,"data":{"changed":7}}"#,
             .contactsUpdated(changed: 7)),
            ("inbox.changed", #"{"type":"inbox.changed","seq":9,"data":{"reason":"message.done"}}"#,
             .inboxChanged(reason: "message.done")),
            ("reaction.received", #"{"type":"reaction.received","seq":10,"data":{"message_rowid":42,"chat_jid":"chat@g.us","reactor_jid":"reactor@s.whatsapp.net","emoji":"👍"}}"#,
             .reaction(rowid: 42, emoji: "👍")),
            ("media.updated", #"{"type":"media.updated","seq":11,"data":{"message_rowid":42,"chat_jid":"chat@g.us","media":\#(mediaJSON)}}"#,
             .mediaUpdated(rowid: 42, chat: "chat@g.us", media: media)),
            ("ping", #"{"type":"ping"}"#, .ping),
        ]

        for item in cases {
            XCTAssertEqual(CoreEvent.decode(text: item.frame), item.expected, item.label)
        }
    }

    func testOptionalPayloadFieldsPreserveLegacyDefaults() {
        let emptyMedia = MessageMedia(
            id: "",
            kind: "",
            mime: "",
            size: 0,
            filename: nil,
            state: "not_downloaded",
            local_path: nil
        )

        XCTAssertEqual(
            CoreEvent.decode(text: #"{"type":"connection.changed","data":{"state":"disconnected"}}"#),
            .connectionChanged(state: "disconnected", reason: nil)
        )
        XCTAssertEqual(
            CoreEvent.decode(text: #"{"type":"connection.changed","data":{"state":"disconnected","reason":null}}"#),
            .connectionChanged(state: "disconnected", reason: nil)
        )
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"contacts.updated","data":{}}"#),
                       .contactsUpdated(changed: nil))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"contacts.updated"}"#),
                       .contactsUpdated(changed: nil))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"contacts.updated","data":null}"#),
                       .contactsUpdated(changed: nil))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"contacts.updated","data":[]}"#),
                       .contactsUpdated(changed: nil))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"inbox.changed","data":{}}"#),
                       .inboxChanged(reason: nil))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"inbox.changed"}"#),
                       .inboxChanged(reason: nil))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"inbox.changed","data":null}"#),
                       .inboxChanged(reason: nil))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"inbox.changed","data":"ignored"}"#),
                       .inboxChanged(reason: nil))
        XCTAssertEqual(
            CoreEvent.decode(text: #"{"type":"reaction.received","data":{"message_rowid":42}}"#),
            .reaction(rowid: 42, emoji: "")
        )
        XCTAssertEqual(
            CoreEvent.decode(text: #"{"type":"reaction.received","data":{"message_rowid":42,"emoji":null}}"#),
            .reaction(rowid: 42, emoji: "")
        )
        XCTAssertEqual(
            CoreEvent.decode(text: #"{"type":"media.updated","data":{"message_rowid":42}}"#),
            .mediaUpdated(rowid: 42, chat: "", media: emptyMedia)
        )
        XCTAssertEqual(
            CoreEvent.decode(text: #"{"type":"media.updated","data":{"message_rowid":42,"chat_jid":null,"media":null}}"#),
            .mediaUpdated(rowid: 42, chat: "", media: emptyMedia)
        )
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"ping","data":7}"#), .ping)
    }

    func testUnknownAndMalformedFramesAreIgnored() {
        XCTAssertNil(CoreEvent.decode(text: #"{"type":"unknown","data":{}}"#))

        let malformedFrames = [
            "",
            "{",
            "[]",
            "{}",
            #"{"type":7,"data":{}}"#,
            #"{"type":"connection.changed","data":{"reason":"missing state"}}"#,
            #"{"type":"session.qr","data":{"code":"qr","expires_ts":"soon"}}"#,
            #"{"type":"message.received","data":{}}"#,
            #"{"type":"chat.updated","data":{"chat":[]}}"#,
            #"{"type":"chat.removed","data":[]}"#,
            #"{"type":"contacts.updated","data":{"changed":"many"}}"#,
            #"{"type":"reaction.received","data":{"emoji":"👍"}}"#,
            #"{"type":"media.updated","data":{"chat_jid":"chat@g.us"}}"#,
        ]

        for frame in malformedFrames {
            XCTAssertNil(CoreEvent.decode(text: frame), frame)
        }
    }

    func testPingProducesOnePongAndOneHeartbeatWithoutBecomingAnEvent() async {
        let socket = CoreEventDecodeSocket(frames: [.text(#"{"type":"ping"}"#)])
        let recorder = CoreEventDecodeRecorder()
        let pump = WebSocketEventPump(
            task: socket,
            onEvent: { event in await recorder.record(event: event) },
            onHeartbeat: { await recorder.recordHeartbeat() },
            onDisconnect: { await recorder.recordDisconnect() }
        )

        let completion = await pump.start()
        await completion.value

        let socketResult = await socket.result()
        let recorded = await recorder.result()
        XCTAssertEqual(socketResult.starts, 1)
        XCTAssertEqual(socketResult.receives, 2)
        XCTAssertEqual(socketResult.sent, [#"{"type":"pong"}"#])
        XCTAssertEqual(socketResult.cancels, 1)
        XCTAssertEqual(recorded.events, [])
        XCTAssertEqual(recorded.heartbeats, 1)
        XCTAssertEqual(recorded.disconnects, 1)
    }

    func testDecodePerformance10kFrames() {
        let options = XCTMeasureOptions()
        options.iterationCount = 20

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            var decodedCount = 0
            for _ in 0..<10_000 {
                if CoreEvent.decode(text: performanceFrame) != nil {
                    decodedCount += 1
                }
            }
            XCTAssertEqual(decodedCount, 10_000)
        }
    }
}

private enum CoreEventDecodeSocketError: Error {
    case finished
}

private actor CoreEventDecodeSocket: WebSocketEventTask {
    private var frames: [WebSocketFrame]
    private var starts = 0
    private var receives = 0
    private var sent: [String] = []
    private var cancels = 0

    init(frames: [WebSocketFrame]) {
        self.frames = frames
    }

    func start() async {
        starts += 1
    }

    func receive() async throws -> WebSocketFrame {
        receives += 1
        guard !frames.isEmpty else { throw CoreEventDecodeSocketError.finished }
        return frames.removeFirst()
    }

    func send(text: String) async throws {
        sent.append(text)
    }

    func cancel() async {
        cancels += 1
    }

    func result() -> (starts: Int, receives: Int, sent: [String], cancels: Int) {
        (starts, receives, sent, cancels)
    }
}

private actor CoreEventDecodeRecorder {
    private var events: [CoreEvent] = []
    private var heartbeats = 0
    private var disconnects = 0

    func record(event: CoreEvent) {
        events.append(event)
    }

    func recordHeartbeat() {
        heartbeats += 1
    }

    func recordDisconnect() {
        disconnects += 1
    }

    func result() -> (events: [CoreEvent], heartbeats: Int, disconnects: Int) {
        (events, heartbeats, disconnects)
    }
}
