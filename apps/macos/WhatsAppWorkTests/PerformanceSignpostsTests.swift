import XCTest
@testable import WhatsAppWork

@MainActor
final class PerformanceSignpostsTests: XCTestCase {
    func testLaunchEndsOnceAndEmitsOneLoadedChatListProxyEvent() {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })

        lifecycle.beginLaunch()
        lifecycle.beginLaunch()
        lifecycle.endLaunchAtLoadedChatListRunLoopProxy()
        lifecycle.endLaunchAtLoadedChatListRunLoopProxy()

        XCTAssertEqual(events.map(\.phase), [.began, .ended(.completed), .event])
        XCTAssertEqual(events.map(\.metric), [
            .appStateLaunch, .appStateLaunch, .loadedChatListRunLoopProxy,
        ])
        XCTAssertEqual(events[0].intervalID, events[1].intervalID)
        XCTAssertNil(events[2].intervalID)
    }

    func testOverlappingIntervalsHaveUniqueIDsAndEndExactlyOnce() {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })

        let firstPage = lifecycle.beginMessagePage()
        let secondPage = lifecycle.beginMessagePage()
        let sync = lifecycle.beginSyncRefresh()
        lifecycle.endMessagePage(firstPage, outcome: .completed)
        lifecycle.endMessagePage(firstPage, outcome: .failed)
        lifecycle.endMessagePage(secondPage, outcome: .cancelled)
        lifecycle.endSyncRefresh(sync, outcome: .completed)

        let begunIDs = events.filter { $0.phase == .began }.compactMap(\.intervalID)
        XCTAssertEqual(begunIDs.count, 3)
        XCTAssertEqual(Set(begunIDs).count, 3)
        XCTAssertEqual(events.filter { $0.phase == .ended(.completed) }.count, 2)
        XCTAssertEqual(events.filter { $0.phase == .ended(.cancelled) }.count, 1)
        XCTAssertFalse(events.contains { $0.phase == .ended(.failed) })
    }

    func testChatAndRowBookkeepingIsBoundedAndOrdinaryRowsAreNoOps() {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(
            limits: .init(chatSwitches: 2, pendingRows: 2, activeIntervals: 8),
            observer: { events.append($0) }
        )

        lifecycle.beginChatSwitch(chatKey: "chat-a")
        lifecycle.beginChatSwitch(chatKey: "chat-b")
        lifecycle.beginChatSwitch(chatKey: "chat-c")
        lifecycle.beginIncoming(rowID: 1)
        lifecycle.beginOptimistic(rowID: 2)
        lifecycle.beginIncoming(rowID: 3)
        let beforeOrdinaryRow = events
        lifecycle.endVisibleRow(rowID: 999)

        XCTAssertEqual(events.filter { $0.phase == .began }.count, 4)
        XCTAssertEqual(events, beforeOrdinaryRow)

        lifecycle.clearPending()

        XCTAssertEqual(events.filter { $0.phase == .ended(.cancelled) }.count, 4)
    }

    func testReplacingAKeyCancelsItsOldIntervalBeforeStartingAnother() {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })

        lifecycle.beginChatSwitch(chatKey: "chat")
        lifecycle.beginChatSwitch(chatKey: "chat")
        lifecycle.beginIncoming(rowID: 7)
        lifecycle.beginOptimistic(rowID: 7)
        lifecycle.endVisibleRow(rowID: 7)
        lifecycle.endChatSwitch(chatKey: "chat", outcome: .completed)

        XCTAssertEqual(events.map(\.phase), [
            .began, .ended(.cancelled), .began,
            .began, .ended(.cancelled), .began,
            .ended(.completed), .ended(.completed),
        ])
        XCTAssertEqual(events.map(\.metric), [
            .chatSwitch, .chatSwitch, .chatSwitch,
            .incomingToVisible, .incomingToVisible, .optimisticToVisible,
            .optimisticToVisible, .chatSwitch,
        ])
    }

    func testCachedAndStaleViewUpdateProxiesCannotCompleteChatSwitch() async {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })
        let pages = SuspendedMessagePages()
        let state = AppState(
            runtimeClient: makeRuntimeClient(messages: { try await pages.load($0) }),
            performanceSignposts: lifecycle
        )
        let chat = "chat-a"
        state.messagesByChat[chat] = [message(id: 1, chat: chat)]

        let preview = Task { await state.previewChat(chat) }
        await pages.waitForRequest(chat, count: 1)
        state.selectedMessagePageDidReachViewUpdateProxy(chatJID: chat, renderVersion: 0)
        XCTAssertFalse(chatEvents(events).contains { $0.phase == .ended(.completed) })

        pages.succeed(chat, messages: [message(id: 2, chat: chat)])
        await preview.value
        let arrivedVersion = state.selectedMessagePageRenderVersion
        XCTAssertEqual(arrivedVersion, 1)

        state.selectedMessagePageDidReachViewUpdateProxy(chatJID: chat, renderVersion: 0)
        XCTAssertFalse(chatEvents(events).contains { $0.phase == .ended(.completed) })
        state.selectedMessagePageDidReachViewUpdateProxy(
            chatJID: chat,
            renderVersion: arrivedVersion
        )
        XCTAssertEqual(chatEvents(events).map(\.phase), [.began, .ended(.completed)])
    }

    func testReusedInFlightPreviewTransfersCompletionToLatestSelection() async {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })
        let pages = SuspendedMessagePages()
        let state = AppState(
            runtimeClient: makeRuntimeClient(messages: { try await pages.load($0) }),
            performanceSignposts: lifecycle
        )

        let firstA = Task { await state.previewChat("chat-a") }
        await pages.waitForRequest("chat-a", count: 1)
        let b = Task { await state.previewChat("chat-b") }
        await pages.waitForRequest("chat-b", count: 1)
        await state.previewChat("chat-a")
        XCTAssertEqual(pages.requestCount(for: "chat-a"), 1)

        pages.succeed("chat-a", messages: [message(id: 1, chat: "chat-a")])
        await firstA.value
        let version = state.selectedMessagePageRenderVersion
        state.selectedMessagePageDidReachViewUpdateProxy(
            chatJID: "chat-a",
            renderVersion: version
        )

        let chatLifecycle = chatEvents(events)
        XCTAssertEqual(chatLifecycle.map(\.phase), [
            .began, .ended(.cancelled),
            .began, .ended(.cancelled),
            .began, .ended(.completed),
        ])
        XCTAssertEqual(chatLifecycle[4].intervalID, chatLifecycle[5].intervalID)

        pages.succeed("chat-b", messages: [])
        await b.value
    }

    func testSelectionCancellationEndsSwitchAndRejectsLatePageGeneration() async {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })
        let pages = SuspendedMessagePages()
        let state = AppState(
            runtimeClient: makeRuntimeClient(messages: { try await pages.load($0) }),
            performanceSignposts: lifecycle
        )

        let preview = Task { await state.previewChat("chat-a") }
        await pages.waitForRequest("chat-a", count: 1)
        state.selectedChat = nil
        pages.succeed("chat-a", messages: [message(id: 1, chat: "chat-a")])
        await preview.value
        state.selectedMessagePageDidReachViewUpdateProxy(chatJID: "chat-a", renderVersion: 1)

        XCTAssertEqual(chatEvents(events).map(\.phase), [.began, .ended(.cancelled)])
        XCTAssertEqual(state.selectedMessagePageRenderVersion, 0)
    }

    func testFailedPreviewStillRefreshesCachedUnreadBoundary() async {
        enum ExpectedFailure: Error { case fetch }
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })
        let state = AppState(
            runtimeClient: makeRuntimeClient(messages: { _ in throw ExpectedFailure.fetch }),
            performanceSignposts: lifecycle
        )
        let chat = "chat-a"
        state.chats = [Chat(
            jid: chat, kind: "direct", display_name: "Chat", last_message_ts: 1,
            last_preview: nil, unread_count: 1, mentioned_unread: 0,
            is_pinned: false, is_muted: false, is_starred: false,
            is_work: false, lid: nil
        )]
        state.messagesByChat[chat] = [message(id: 7, chat: chat)]

        await state.previewChat(chat)

        XCTAssertEqual(state.unreadBoundaries[chat]?.count, 1)
        XCTAssertEqual(state.unreadBoundaries[chat]?.rowID, 7)
        XCTAssertEqual(chatEvents(events).map(\.phase), [.began, .ended(.failed)])
    }

    func testStaleRuntimeSuccessCancelsOwnedSwitchBeforeLaterSelectionCompletes() async {
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })
        let stalePages = SuspendedMessagePages()
        let replacementPages = SuspendedMessagePages()
        let state = AppState(
            runtimeClient: makeRuntimeClient(messages: { try await stalePages.load($0) }),
            performanceSignposts: lifecycle
        )
        let chat = "chat-a"

        let stalePreview = Task { await state.previewChat(chat) }
        await stalePages.waitForRequest(chat, count: 1)
        state.installRuntimeClient(
            makeRuntimeClient(messages: { try await replacementPages.load($0) })
        )
        stalePages.succeed(chat, messages: [message(id: 1, chat: chat)])
        await stalePreview.value

        XCTAssertEqual(chatEvents(events).map(\.phase), [.began, .ended(.cancelled)])

        state.selectedChat = nil
        let replacementPreview = Task { await state.previewChat(chat) }
        await replacementPages.waitForRequest(chat, count: 1)
        replacementPages.succeed(chat, messages: [message(id: 2, chat: chat)])
        await replacementPreview.value
        state.selectedMessagePageDidReachViewUpdateProxy(
            chatJID: chat,
            renderVersion: state.selectedMessagePageRenderVersion
        )

        XCTAssertEqual(chatEvents(events).map(\.phase), [
            .began, .ended(.cancelled), .began, .ended(.completed),
        ])
    }

    func testStaleRuntimeErrorCannotCancelNewerReboundSwitch() async {
        enum ExpectedFailure: Error { case fetch }
        var events: [PerformanceSignpostLifecycle.Event] = []
        let lifecycle = PerformanceSignpostLifecycle(observer: { events.append($0) })
        let stalePages = SuspendedMessagePages()
        let replacementPages = SuspendedMessagePages()
        let state = AppState(
            runtimeClient: makeRuntimeClient(messages: { try await stalePages.load($0) }),
            performanceSignposts: lifecycle
        )
        let chat = "chat-a"

        let stalePreview = Task { await state.previewChat(chat) }
        await stalePages.waitForRequest(chat, count: 1)
        state.cancelForUnavailableSidecar()
        state.selectedChat = nil
        state.selectedChat = chat
        stalePages.fail(chat, error: ExpectedFailure.fetch)
        await stalePreview.value

        XCTAssertEqual(chatEvents(events).map(\.phase), [
            .began, .ended(.cancelled), .began,
        ])

        state.installRuntimeClient(
            makeRuntimeClient(messages: { try await replacementPages.load($0) })
        )
        let replacementPreview = Task { await state.previewChat(chat) }
        await replacementPages.waitForRequest(chat, count: 1)
        replacementPages.succeed(chat, messages: [message(id: 2, chat: chat)])
        await replacementPreview.value
        state.selectedMessagePageDidReachViewUpdateProxy(
            chatJID: chat,
            renderVersion: state.selectedMessagePageRenderVersion
        )

        XCTAssertEqual(chatEvents(events).map(\.phase), [
            .began, .ended(.cancelled), .began, .ended(.completed),
        ])
    }
}

@MainActor
private func chatEvents(
    _ events: [PerformanceSignpostLifecycle.Event]
) -> [PerformanceSignpostLifecycle.Event] {
    events.filter { $0.metric == .chatSwitch }
}

@MainActor
private func makeRuntimeClient(
    messages: @escaping @MainActor (String) async throws -> MessagesResponse
) -> AppRuntimeClient {
    AppRuntimeClient(
        sessionInfo: { SessionInfo(state: "connected", account: nil, qr: nil, sync: nil) },
        chats: { _ in ChatsResponse(chats: [], next_cursor: nil) },
        contacts: { [] },
        startLink: {},
        logout: {},
        messages: messages,
        connectEvents: { _, _, _, _ in },
        disconnectEvents: {}
    )
}

private func message(id: Int64, chat: String) -> Message {
    Message(
        id: id, message_id: "m\(id)", chat_jid: chat, sender_jid: "sender",
        from_me: false, timestamp: id, kind: "text", text: "text",
        reply_to_id: nil, reply_to_sender: nil, quoted_text: nil,
        has_mention: false, mentioned_jids: nil, receipt_status: nil,
        revoked: false, forwarded: nil, edited_ts: nil, starred: nil,
        done: nil, raw_kind: nil, media: nil, reactions: nil
    )
}

@MainActor
private final class SuspendedMessagePages {
    private var counts: [String: Int] = [:]
    private var continuations: [String: CheckedContinuation<MessagesResponse, Error>] = [:]

    func load(_ chat: String) async throws -> MessagesResponse {
        counts[chat, default: 0] += 1
        return try await withCheckedThrowingContinuation { continuations[chat] = $0 }
    }

    func requestCount(for chat: String) -> Int { counts[chat, default: 0] }

    func waitForRequest(_ chat: String, count: Int) async {
        for _ in 0..<1_000 {
            if requestCount(for: chat) >= count { return }
            await Task.yield()
        }
        XCTFail("timed out waiting for message page")
    }

    func succeed(_ chat: String, messages: [Message]) {
        continuations.removeValue(forKey: chat)?.resume(
            returning: MessagesResponse(messages: messages, next_cursor: nil)
        )
    }

    func fail(_ chat: String, error: Error) {
        continuations.removeValue(forKey: chat)?.resume(throwing: error)
    }
}
