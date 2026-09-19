import AppKit
import XCTest
@testable import WhatsAppWork

@MainActor
final class InteractionPoliciesTests: XCTestCase {
    func testPasteRoutingOnlyStagesAttachmentInFocusedComposer() {
        XCTAssertEqual(PasteRoutingPolicy.route(composerFocused: true, hasAttachment: true), .attachment)
        XCTAssertEqual(PasteRoutingPolicy.route(composerFocused: true, hasAttachment: false), .responder)
        XCTAssertEqual(PasteRoutingPolicy.route(composerFocused: false, hasAttachment: true), .responder)
    }

    func testResponderActionsUseNativeSelectors() {
        var selectors: [String] = []
        let dispatcher = ResponderActionDispatcher { selector in
            selectors.append(NSStringFromSelector(selector))
            return true
        }

        dispatcher.perform(.cut)
        dispatcher.perform(.copy)
        dispatcher.perform(.paste)
        dispatcher.perform(.pasteAndMatchStyle)

        XCTAssertEqual(selectors, ["cut:", "copy:", "paste:", "pasteAsPlainText:"])
    }

    func testReplyStoreRejectsCrossChatTargetsAndRestoresPerChatReply() {
        let a = message(id: 1, chat: "a@s.whatsapp.net", text: "one")
        let b = message(id: 2, chat: "b@s.whatsapp.net", text: "two")
        var store = ChatReplyStore()

        store.set(a, for: a.chat_jid)
        store.set(b, for: b.chat_jid)
        store.set(a, for: b.chat_jid)

        XCTAssertEqual(store.reply(for: a.chat_jid)?.id, 1)
        XCTAssertNil(store.reply(for: b.chat_jid))
    }

    func testTakingReplyClearsOnlyOwningChat() {
        let a = message(id: 1, chat: "a@s.whatsapp.net", text: "one")
        let b = message(id: 2, chat: "b@s.whatsapp.net", text: "two")
        var store = ChatReplyStore()
        store.set(a, for: a.chat_jid)
        store.set(b, for: b.chat_jid)

        XCTAssertEqual(store.take(for: a.chat_jid)?.id, 1)
        XCTAssertNil(store.reply(for: a.chat_jid))
        XCTAssertEqual(store.reply(for: b.chat_jid)?.id, 2)
    }

    func testMediaReplyPeekRetainsReplyWhenSendDoesNotSucceed() {
        let chat = "a@s.whatsapp.net"
        let target = message(id: 1, chat: chat, text: "one")
        var store = ChatReplyStore()
        store.set(target, for: chat)

        let operation = store.mediaSendOperation(for: chat)

        XCTAssertEqual(operation?.message.id, 1)
        XCTAssertEqual(store.reply(for: chat)?.id, 1)
    }

    func testMediaReplySuccessClearsExactCapturedReply() {
        let chat = "a@s.whatsapp.net"
        let target = message(id: 1, chat: chat, text: "one")
        var store = ChatReplyStore()
        store.set(target, for: chat)
        let operation = store.mediaSendOperation(for: chat)

        XCTAssertTrue(store.completeMediaSend(operation, for: chat))
        XCTAssertNil(store.reply(for: chat))
    }

    func testMediaReplyReplacementDuringAwaitSurvivesOldCompletion() {
        let chat = "a@s.whatsapp.net"
        let oldTarget = message(id: 1, chat: chat, text: "old")
        let replacement = message(id: 2, chat: chat, text: "replacement")
        var store = ChatReplyStore()
        store.set(oldTarget, for: chat)
        let oldOperation = store.mediaSendOperation(for: chat)

        store.set(replacement, for: chat)

        XCTAssertFalse(store.completeMediaSend(oldOperation, for: chat))
        XCTAssertEqual(store.reply(for: chat)?.id, 2)
    }

    func testMediaReplyGenerationProtectsReselectedSameTarget() {
        let chat = "a@s.whatsapp.net"
        let target = message(id: 1, chat: chat, text: "same target")
        var store = ChatReplyStore()
        store.set(target, for: chat)
        let oldOperation = store.mediaSendOperation(for: chat)

        store.set(target, for: chat)

        XCTAssertFalse(store.completeMediaSend(oldOperation, for: chat))
        XCTAssertEqual(store.reply(for: chat)?.id, 1)
    }

    func testRetryOwnershipUsesFailedMessageChat() {
        let failed = message(id: 3, chat: "retry@s.whatsapp.net", text: "retry",
                             fromMe: true, receiptStatus: "failed")

        XCTAssertEqual(RetryOwnershipPolicy.chat(for: failed), "retry@s.whatsapp.net")
    }

    func testMentionGenerationKeepsRearmedSameChatCurrent() {
        var generations = ChatMentionGenerationStore()
        let sentGeneration = generations.generation(for: "group@g.us")
        generations.rearm("group@g.us")

        XCTAssertFalse(generations.isCurrent(sentGeneration, for: "group@g.us"))
        XCTAssertTrue(generations.isCurrent(1, for: "group@g.us"))
    }

    func testMentionGenerationRearmsOnlyOwningGroup() {
        var generations = ChatMentionGenerationStore()

        XCTAssertEqual(generations.rearm("120@g.us"), 1)
        XCTAssertFalse(generations.isCurrent(0, for: "120@g.us"))
        XCTAssertTrue(generations.isCurrent(0, for: "member@s.whatsapp.net"))
    }

    func testDelayedMediaCompletionClearsOnlyOwningDraftAfterSwitchAndEdit() throws {
        let chatA = "a@s.whatsapp.net"
        let chatB = "b@s.whatsapp.net"
        let sentURL = URL(fileURLWithPath: "/tmp/a.png")
        let newerURL = URL(fileURLWithPath: "/tmp/b.png")
        var tracker = ComposerMediaSendTracker()
        var drafts = [chatA: "caption A", chatB: "new draft B"]
        let visibleChat = chatB
        var visibleDraft = "edited draft B"
        var visibleAttachment: URL? = newerURL
        drafts[chatB] = visibleDraft

        let operationCandidate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chatA,
            draft: "caption A",
            attachmentURL: sentURL
        )
        let operation = try XCTUnwrap(operationCandidate)
        let completion = tracker.completion(
            for: operation,
            succeeded: true,
            ownerDraft: drafts[chatA],
            visibleChatJID: visibleChat,
            visibleDraft: visibleDraft,
            visibleAttachmentURL: visibleAttachment
        )
        if completion.clearsOwnerDraft { drafts[operation.chatJID] = "" }
        if completion.clearsVisibleDraft {
            visibleDraft = ""
            visibleAttachment = nil
        }

        XCTAssertEqual(drafts[chatA], "")
        XCTAssertEqual(drafts[chatB], "edited draft B")
        XCTAssertEqual(visibleChat, chatB)
        XCTAssertEqual(visibleDraft, "edited draft B")
        XCTAssertEqual(visibleAttachment, newerURL)
    }

    func testDelayedMediaCompletionPreservesNewerSameChatDraft() throws {
        let chat = "a@s.whatsapp.net"
        let url = URL(fileURLWithPath: "/tmp/a.png")
        var tracker = ComposerMediaSendTracker()
        let operationCandidate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chat,
            draft: "old",
            attachmentURL: url
        )
        let operation = try XCTUnwrap(operationCandidate)
        tracker.noteCompositionChanged(for: chat)

        let completion = tracker.completion(
            for: operation,
            succeeded: true,
            ownerDraft: "new",
            visibleChatJID: chat,
            visibleDraft: "new",
            visibleAttachmentURL: url
        )

        XCTAssertFalse(completion.clearsOwnerDraft)
        XCTAssertFalse(completion.clearsVisibleDraft)
    }

    func testDelayedMediaCompletionNeverClearsIdenticalCompositionInAnotherChat() throws {
        let chatA = "a@s.whatsapp.net"
        let chatB = "b@s.whatsapp.net"
        let url = URL(fileURLWithPath: "/tmp/shared.png")
        var tracker = ComposerMediaSendTracker()
        let operationCandidate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chatA,
            draft: "same",
            attachmentURL: url
        )
        let operation = try XCTUnwrap(operationCandidate)

        let completion = tracker.completion(
            for: operation,
            succeeded: true,
            ownerDraft: "same",
            visibleChatJID: chatB,
            visibleDraft: "same",
            visibleAttachmentURL: url
        )

        XCTAssertTrue(completion.clearsOwnerDraft)
        XCTAssertFalse(completion.clearsVisibleDraft)
    }

    func testDelayedMediaCompletionTokenRejectsReplacementAttachment() throws {
        let chat = "a@s.whatsapp.net"
        let sentURL = URL(fileURLWithPath: "/tmp/sent.png")
        let replacementURL = URL(fileURLWithPath: "/tmp/replacement.png")
        var tracker = ComposerMediaSendTracker()
        let operationCandidate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chat,
            draft: "caption",
            attachmentURL: sentURL
        )
        let operation = try XCTUnwrap(operationCandidate)
        tracker.noteCompositionChanged(for: chat)

        let completion = tracker.completion(
            for: operation,
            succeeded: true,
            ownerDraft: "caption",
            visibleChatJID: chat,
            visibleDraft: "caption",
            visibleAttachmentURL: replacementURL
        )

        XCTAssertFalse(completion.clearsOwnerDraft)
        XCTAssertFalse(completion.clearsVisibleDraft)
    }

    func testFailedMediaSubmissionKeepsCompositionAndAllowsRetry() throws {
        let chat = "a@s.whatsapp.net"
        let url = URL(fileURLWithPath: "/tmp/retry.png")
        var tracker = ComposerMediaSendTracker()
        let firstCandidate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chat,
            draft: "keep this caption",
            attachmentURL: url
        )
        let first = try XCTUnwrap(firstCandidate)
        XCTAssertTrue(tracker.isSubmitting)

        let failure = tracker.completion(
            for: first,
            succeeded: false,
            ownerDraft: "keep this caption",
            visibleChatJID: chat,
            visibleDraft: "keep this caption",
            visibleAttachmentURL: url
        )

        XCTAssertFalse(failure.clearsOwnerDraft)
        XCTAssertFalse(failure.clearsVisibleDraft)
        XCTAssertFalse(tracker.isSubmitting)
        let retry: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chat,
            draft: "keep this caption",
            attachmentURL: url
        )
        XCTAssertNotNil(retry)
    }

    func testMediaSubmitRoundTripNavigationClearsOnlyUnchangedCaption() async {
        for edit in ["none", "new draft", "replacement attachment", "edit then restore"] {
            let action = ComposerMediaSubmitAction()
            let attachment = URL(fileURLWithPath: "/original.png")
            let replacement = URL(fileURLWithPath: "/replacement.png")
            var ownerDraft: String? = "sent caption"
            var visibleChat = "A"
            var visibleDraft = "sent caption"
            var visibleAttachment: URL? = attachment
            let outcome = await action.submit(
                chatJID: "A", draft: visibleDraft, attachmentURL: attachment, caption: visibleDraft,
                send: { request in
                    XCTAssertEqual(request.chatJID, "A")
                    XCTAssertEqual(request.caption, "sent caption")
                    // Match ComposerBar's navigation handler: restore stored
                    // drafts; remove attachments without rearming ownership.
                    visibleChat = "B"
                    visibleDraft = "B draft"
                    visibleAttachment = nil
                    await Task.yield()
                    visibleChat = "A"
                    visibleDraft = ownerDraft ?? ""
                    if edit != "none" {
                        action.noteCompositionChanged(for: "A")
                        if edit == "new draft" {
                            ownerDraft = "new draft"
                            visibleDraft = "new draft"
                        } else if edit == "replacement attachment" {
                            visibleAttachment = replacement
                        } else {
                            action.noteCompositionChanged(for: "A")
                        }
                    }
                    return true
                },
                completionState: {
                    ComposerMediaCompositionSnapshot(ownerDraft: ownerDraft,
                        visibleChatJID: visibleChat, visibleDraft: visibleDraft,
                        visibleAttachmentURL: visibleAttachment)
                }
            )
            XCTAssertTrue(outcome.accepted)
            XCTAssertTrue(outcome.succeeded)
            XCTAssertEqual(outcome.completion.clearsOwnerDraft, edit == "none", edit)
            XCTAssertEqual(outcome.completion.clearsVisibleDraft, edit == "none", edit)
            XCTAssertFalse(outcome.completion.clearsVisibleAttachment, edit)
        }
    }

    func testComposerMediaSubmitActionForwardsFailureAndAllowsRetry() async {
        let chat = "a@s.whatsapp.net"
        let url = URL(fileURLWithPath: "/tmp/retry-action.png")
        let caption = "keep this caption"
        let action = ComposerMediaSubmitAction()
        var sendInvocations = 0
        let completionState: @MainActor () -> ComposerMediaCompositionSnapshot = {
            ComposerMediaCompositionSnapshot(
                ownerDraft: caption,
                visibleChatJID: chat,
                visibleDraft: caption,
                visibleAttachmentURL: url
            )
        }

        let failure = await action.submit(
            chatJID: chat,
            draft: caption,
            attachmentURL: url,
            caption: caption,
            send: { request in
                sendInvocations += 1
                XCTAssertEqual(request.chatJID, chat)
                XCTAssertEqual(request.attachmentURL, url)
                XCTAssertEqual(request.caption, caption)
                return false
            },
            completionState: completionState
        )

        XCTAssertTrue(failure.accepted)
        XCTAssertFalse(failure.succeeded)
        XCTAssertFalse(failure.completion.clearsOwnerDraft)
        XCTAssertFalse(failure.completion.clearsVisibleDraft)
        XCTAssertFalse(action.isSubmitting)

        let retry = await action.submit(
            chatJID: chat,
            draft: caption,
            attachmentURL: url,
            caption: caption,
            send: { _ in
                sendInvocations += 1
                return true
            },
            completionState: completionState
        )

        XCTAssertTrue(retry.accepted)
        XCTAssertTrue(retry.succeeded)
        XCTAssertTrue(retry.completion.clearsOwnerDraft)
        XCTAssertTrue(retry.completion.clearsVisibleDraft)
        XCTAssertTrue(retry.completion.clearsVisibleAttachment)
        XCTAssertFalse(action.isSubmitting)
        XCTAssertEqual(sendInvocations, 2)
    }

    func testStaleMediaCompletionCannotReleaseNewerSubmission() throws {
        let chat = "a@s.whatsapp.net"
        let oldURL = URL(fileURLWithPath: "/tmp/old.png")
        let newURL = URL(fileURLWithPath: "/tmp/new.png")
        var tracker = ComposerMediaSendTracker()
        let oldCandidate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chat,
            draft: "old",
            attachmentURL: oldURL
        )
        let old = try XCTUnwrap(oldCandidate)
        _ = tracker.completion(
            for: old,
            succeeded: false,
            ownerDraft: "old",
            visibleChatJID: chat,
            visibleDraft: "old",
            visibleAttachmentURL: oldURL
        )
        let newCandidate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chat,
            draft: "new",
            attachmentURL: newURL
        )
        let new = try XCTUnwrap(newCandidate)

        let stale = tracker.completion(
            for: old,
            succeeded: true,
            ownerDraft: "new",
            visibleChatJID: chat,
            visibleDraft: "new",
            visibleAttachmentURL: newURL
        )

        XCTAssertFalse(stale.clearsOwnerDraft)
        XCTAssertFalse(stale.clearsVisibleDraft)
        XCTAssertTrue(tracker.isSubmitting)
        let duplicate: ComposerMediaSendOperation? = tracker.begin(
            chatJID: chat,
            draft: "new",
            attachmentURL: newURL
        )
        XCTAssertNil(duplicate)
        _ = tracker.completion(
            for: new,
            succeeded: false,
            ownerDraft: "new",
            visibleChatJID: chat,
            visibleDraft: "new",
            visibleAttachmentURL: newURL
        )
        XCTAssertFalse(tracker.isSubmitting)
    }

    func testMemberMentionUsesOwningGroupNotMemberJID() {
        XCTAssertEqual(
            MentionInsertionPolicy.owningChat(
                forMemberJID: "member@s.whatsapp.net",
                in: "120@g.us"
            ),
            "120@g.us"
        )
    }

    func testEveryMemberMentionActionRoutesFinalInsertionToOwningGroup() {
        var targetChats: [String] = []
        var queuedLabels: [String] = []
        let router = MemberMentionActionRouter(
            setMentionTarget: { _, _, chatJID in targetChats.append(chatJID) },
            queueInsertion: { queuedLabels.append($0) }
        )

        router.fromMemberRow(
            memberJID: "member@s.whatsapp.net",
            label: "Member",
            groupChatJID: "120@g.us"
        )
        router.fromMemberContextMenu(
            memberJID: "member@s.whatsapp.net",
            label: "Member",
            groupChatJID: "120@g.us"
        )
        router.fromProfile(
            memberJID: "member@s.whatsapp.net",
            label: "Member",
            groupChatJID: "120@g.us"
        )

        XCTAssertEqual(targetChats, ["120@g.us", "120@g.us", "120@g.us"])
        XCTAssertEqual(queuedLabels, ["Member", "Member", "Member"])
    }

    func testOnlyExplicitNavigationSourcesAcknowledgeRead() {
        XCTAssertFalse(ChatOpenSource.keyboardSelection.acknowledgesRead)
        for source in [ChatOpenSource.enter, .mouse, .transcriptFocus,
                       .composerFocus, .selectionChange, .search, .inbox,
                       .notification, .deepLink] {
            XCTAssertTrue(source.acknowledgesRead, "\(source) should acknowledge")
        }
    }

    func testReadGateAllowsOnlyOneConcurrentCommitPerChat() {
        var gate = ReadCommitGate()
        XCTAssertTrue(gate.begin("a@s.whatsapp.net", unreadCount: 3))
        XCTAssertFalse(gate.begin("a@s.whatsapp.net", unreadCount: 3))
        gate.finish("a@s.whatsapp.net")
        XCTAssertTrue(gate.begin("a@s.whatsapp.net", unreadCount: 1))
        XCTAssertFalse(gate.begin("b@s.whatsapp.net", unreadCount: 0))
    }

    func testUnreadBoundaryIsRowBoundedOrTopOfWindow() {
        let chat = "a@s.whatsapp.net"
        let rows = [message(id: 1, chat: chat, text: "one"),
                    message(id: 2, chat: chat, text: "two")]
        XCTAssertEqual(UnreadBoundaryPolicy.resolve(unreadCount: 2, messages: rows)?.rowID, 1)
        let truncated = UnreadBoundaryPolicy.resolve(unreadCount: 5, messages: rows)
        XCTAssertEqual(truncated?.count, 5)
        XCTAssertNil(truncated?.rowID)
    }

    func testUnreadBoundaryOrdersEqualTimestampsAroundOutgoingRows() {
        let chat = "a@s.whatsapp.net"
        let rows = [message(id: 99, chat: chat, text: "old", timestamp: 100),
                    message(id: 1, chat: chat, text: "out-old", fromMe: true, timestamp: 50),
                    message(id: 200, chat: chat, text: "out-middle", fromMe: true, timestamp: 150),
                    message(id: 70, chat: chat, text: "middle-high", timestamp: 200),
                    message(id: 2, chat: chat, text: "middle-low", timestamp: 200),
                    message(id: 50, chat: chat, text: "new", timestamp: 300),
                    message(id: 4, chat: chat, text: "out-late", fromMe: true, timestamp: 350),
                    message(id: 3, chat: chat, text: "out-new", fromMe: true, timestamp: 400)]

        XCTAssertEqual(UnreadBoundaryPolicy.resolve(unreadCount: 3, messages: rows)?.rowID, 2)
    }

    func testProductionMessageOrderingAndBoundaryShareTimestampIDOrder() {
        let chat = "a@s.whatsapp.net"
        let rows = [message(id: 5, chat: chat, text: "incoming-five", timestamp: 200),
                    message(id: 1, chat: chat, text: "outgoing-one", fromMe: true, timestamp: 200),
                    message(id: 4, chat: chat, text: "incoming-four", timestamp: 200),
                    message(id: 2, chat: chat, text: "incoming-two", timestamp: 200),
                    message(id: 3, chat: chat, text: "outgoing-three", fromMe: true, timestamp: 200)]

        let ordered = MessageTimelineOrder.ordered(rows)

        XCTAssertEqual(ordered.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(
            UnreadBoundaryPolicy.resolve(unreadCount: 2, messages: ordered)?.rowID,
            4
        )
    }

    func testNilRowUnreadBoundaryPresentsBoundedMarkerAndLoadEarlierAction() {
        let boundary = UnreadBoundary(rowID: nil, count: 125)
        let presentation = UnreadMarkerPresenter.presentation(
            for: boundary,
            loadedMessageCount: 50
        )

        XCTAssertEqual(
            presentation,
            .boundedTop(
                label: "125 unread · showing latest 50",
                actionTitle: "Load Earlier"
            )
        )
    }

    func testMergedOlderPageRecomputesBoundedUnreadMarkerToRow() {
        let chat = "a@s.whatsapp.net"
        let initial = [message(id: 4, chat: chat, text: "four"),
                       message(id: 5, chat: chat, text: "five")]
        let bounded = UnreadBoundaryPolicy.refresh(
            existing: nil,
            liveUnreadCount: 3,
            messages: initial
        )
        let afterOneOlderPage = [message(id: 1, chat: chat, text: "one"),
                                 message(id: 2, chat: chat, text: "two"),
                                 message(id: 3, chat: chat, text: "three")] + initial

        let resolved = UnreadBoundaryPolicy.refresh(
            existing: bounded,
            liveUnreadCount: 0,
            messages: afterOneOlderPage
        )

        XCTAssertEqual(bounded, UnreadBoundary(rowID: nil, count: 3))
        XCTAssertEqual(resolved, UnreadBoundary(rowID: 3, count: 3))
    }

    func testPreviewCoordinatorCoalescesReentryWithoutDroppingAnchor() {
        var coordinator = PreviewLoadCoordinator()
        let explicit = coordinator.request(chatJID: "a@s.whatsapp.net", anchorMessageID: "anchor")
        XCTAssertTrue(coordinator.claim(explicit))

        let reentry = coordinator.request(chatJID: "a@s.whatsapp.net", anchorMessageID: nil)

        XCTAssertEqual(reentry, explicit)
        XCTAssertEqual(reentry.anchorMessageID, "anchor")
        XCTAssertFalse(coordinator.claim(reentry))
        XCTAssertTrue(coordinator.isCurrent(reentry))
        XCTAssertNil(coordinator.selectionRequest(chatJID: "a@s.whatsapp.net"))
    }

    func testPreviewCoordinatorRejectsSupersededSelection() {
        var coordinator = PreviewLoadCoordinator()
        let first = coordinator.request(chatJID: "a@s.whatsapp.net", anchorMessageID: nil)
        let latest = coordinator.request(chatJID: "b@s.whatsapp.net", anchorMessageID: nil)

        XCTAssertFalse(coordinator.isCurrent(first))
        XCTAssertTrue(coordinator.isCurrent(latest))
    }

    func testClaimedNilAnchorPreviewUpgradesAndCleansUp() {
        var coordinator = PreviewLoadCoordinator()
        let first = coordinator.request(chatJID: "a@s.whatsapp.net", anchorMessageID: nil)
        XCTAssertTrue(coordinator.claim(first))

        let reentry = coordinator.request(chatJID: "a@s.whatsapp.net", anchorMessageID: "anchor")

        XCTAssertEqual(first, reentry)
        XCTAssertEqual(reentry.anchorMessageID, "anchor")
        XCTAssertTrue(coordinator.isCurrent(first))
        coordinator.finish(first)

        let later = coordinator.request(chatJID: "a@s.whatsapp.net", anchorMessageID: nil)
        XCTAssertNotEqual(later, first)
        XCTAssertTrue(coordinator.claim(later))
    }

    func testSuccessfulReadCannotRetryAfterFilteredRowIsRemoved() {
        let chat = "a@s.whatsapp.net"
        var unread = LiveUnreadState()
        var gate = ReadCommitGate()
        unread.observe(chat, unreadCount: 3)

        XCTAssertTrue(gate.begin(chat, unreadCount: unread.count(for: chat)))
        unread.markReadSucceeded(chat)
        gate.finish(chat)

        XCTAssertEqual(unread.count(for: chat), 0)
        XCTAssertFalse(gate.begin(chat, unreadCount: unread.count(for: chat)))
    }

    func testFailedReadCanRetry() {
        let chat = "a@s.whatsapp.net"
        var unread = LiveUnreadState()
        var gate = ReadCommitGate()
        unread.observe(chat, unreadCount: 3)

        XCTAssertTrue(gate.begin(chat, unreadCount: unread.count(for: chat)))
        gate.finish(chat)

        XCTAssertTrue(gate.begin(chat, unreadCount: unread.count(for: chat)))
    }

    func testReadActionSuccessDoesNotRetryAfterFilteredRowRemoval() async {
        let chat = "a@s.whatsapp.net"
        let action = ReadCommitAction()
        action.observe(chat, unreadCount: 3)
        var visibleUnread: Int? = 3
        var backingUnread = 3
        var requests = 0

        let first = await action.commit(
            chatJID: chat,
            source: .transcriptFocus,
            fallbackUnreadCount: visibleUnread ?? backingUnread,
            request: { requests += 1 },
            onSuccess: {
                visibleUnread = nil
                backingUnread = 0
            }
        )
        let second = await action.commit(
            chatJID: chat,
            source: .composerFocus,
            fallbackUnreadCount: visibleUnread ?? backingUnread,
            request: { requests += 1 },
            onSuccess: { XCTFail("a zero-unread focus must not succeed") }
        )

        XCTAssertEqual(first, .succeeded)
        XCTAssertEqual(second, .skipped)
        XCTAssertEqual(requests, 1)
    }

    func testReadActionFailureRetriesOnSecondFocus() async {
        let chat = "a@s.whatsapp.net"
        let action = ReadCommitAction()
        action.observe(chat, unreadCount: 3)
        var requests = 0

        let first = await action.commit(
            chatJID: chat,
            source: .transcriptFocus,
            fallbackUnreadCount: 3,
            request: {
                requests += 1
                throw TestReadError.failed
            },
            onSuccess: { XCTFail("failed request must not update local read state") }
        )
        let second = await action.commit(
            chatJID: chat,
            source: .composerFocus,
            fallbackUnreadCount: 3,
            request: {
                requests += 1
                throw TestReadError.failed
            },
            onSuccess: { XCTFail("failed request must not update local read state") }
        )

        XCTAssertEqual(first, .failed)
        XCTAssertEqual(second, .failed)
        XCTAssertEqual(requests, 2)
    }

    func testSuccessfulReadThenSkippedFocusPreservesCapturedBoundary() async {
        let chat = "a@s.whatsapp.net"
        let rows = [message(id: 1, chat: chat, text: "one"),
                    message(id: 2, chat: chat, text: "two"),
                    message(id: 3, chat: chat, text: "three")]
        let action = ReadCommitAction()
        action.observe(chat, unreadCount: 3)
        var boundary = UnreadBoundaryPolicy.refresh(
            existing: nil,
            liveUnreadCount: action.value(for: chat),
            messages: rows
        )
        var requests = 0

        let first = await action.commit(
            chatJID: chat,
            source: .transcriptFocus,
            fallbackUnreadCount: 3,
            request: { requests += 1 },
            onSuccess: {}
        )
        boundary = UnreadBoundaryPolicy.refresh(
            existing: boundary,
            liveUnreadCount: action.value(for: chat),
            messages: rows
        )
        let second = await action.commit(
            chatJID: chat,
            source: .composerFocus,
            fallbackUnreadCount: 0,
            request: { requests += 1 },
            onSuccess: { XCTFail("a skipped focus must not commit again") }
        )

        XCTAssertEqual(first, .succeeded)
        XCTAssertEqual(second, .skipped)
        XCTAssertEqual(boundary, UnreadBoundary(rowID: 1, count: 3))
        XCTAssertEqual(requests, 1)
    }

    func testPreviewAfterReadCompletionRecomputesHistoricalBoundary() async {
        let chat = "a@s.whatsapp.net"
        let rows = [message(id: 1, chat: chat, text: "one"),
                    message(id: 2, chat: chat, text: "two"),
                    message(id: 3, chat: chat, text: "three")]
        let action = ReadCommitAction()
        action.observe(chat, unreadCount: 3)
        var boundary = UnreadBoundaryPolicy.refresh(
            existing: nil,
            liveUnreadCount: action.value(for: chat),
            messages: []
        )
        XCTAssertEqual(boundary, UnreadBoundary(rowID: nil, count: 3))

        _ = await action.commit(
            chatJID: chat,
            source: .mouse,
            fallbackUnreadCount: 3,
            request: {},
            onSuccess: {}
        )
        boundary = UnreadBoundaryPolicy.refresh(
            existing: boundary,
            liveUnreadCount: action.value(for: chat),
            messages: rows
        )

        XCTAssertEqual(action.value(for: chat), 0)
        XCTAssertEqual(boundary, UnreadBoundary(rowID: 1, count: 3))
    }

    // MARK: - Automatic top paging decision

    func testTopPagingThresholdIsFractionOfViewport() {
        XCTAssertEqual(TopPagingThreshold.atTopBound(visibleHeight: 600), 150, accuracy: 0.5)
        XCTAssertEqual(TopPagingThreshold.atTopBound(visibleHeight: 400), 100, accuracy: 0.5)
    }

    func testTopPagingThresholdHasSaneFloor() {
        // Degenerate/zero-height viewports must not disable the trigger.
        XCTAssertGreaterThan(TopPagingThreshold.atTopBound(visibleHeight: 0), 0)
        XCTAssertGreaterThanOrEqual(TopPagingThreshold.atTopBound(visibleHeight: 8), 2)
    }

    func testTopPagingDecisionAllowsScrollTriggerWhenNoBlocker() {
        XCTAssertTrue(AutomaticTopPagingDecision.shouldLoad(
            jumping: false, loadingOlder: false, messageCount: 50))
    }

    func testTopPagingDecisionBlocksWhileJumping() {
        XCTAssertFalse(AutomaticTopPagingDecision.shouldLoad(
            jumping: true, loadingOlder: false, messageCount: 60))
    }

    func testTopPagingDecisionBlocksWhileFetchInFlight() {
        XCTAssertFalse(AutomaticTopPagingDecision.shouldLoad(
            jumping: false, loadingOlder: true, messageCount: 60))
    }

    func testTopPagingDecisionBlocksShortFirstPage() {
        XCTAssertFalse(AutomaticTopPagingDecision.shouldLoad(
            jumping: false, loadingOlder: false, messageCount: 49))
    }

    func testTopPagingDecisionServesUnreadHeavyChats() {
        // Regression (2026-09-05): the old nil-row-boundary pause left
        // unread-heavy groups (68/258 unread) unable to load history by
        // scrolling at all — the exact user-visible "scroll up loads
        // nothing" report. The decision no longer depends on the boundary;
        // keep the boundary type in the signature's call sites out of this
        // unit and assert the behavior users depend on.
        XCTAssertTrue(AutomaticTopPagingDecision.shouldLoad(
            jumping: false, loadingOlder: false, messageCount: 60))
    }

    private enum TestReadError: Error {
        case failed
    }

    private func message(id: Int64, chat: String, text: String,
                         fromMe: Bool = false, receiptStatus: String? = nil,
                         timestamp: Int64? = nil) -> Message {
        Message(id: id, message_id: "m\(id)", chat_jid: chat,
                sender_jid: "sender@s.whatsapp.net", from_me: fromMe,
                timestamp: timestamp ?? 1_700_000_000 + id, kind: "text", text: text,
                reply_to_id: nil, reply_to_sender: nil, quoted_text: nil,
                has_mention: false, mentioned_jids: nil, receipt_status: receiptStatus,
                revoked: false, forwarded: nil, edited_ts: nil,
                starred: nil, done: nil, raw_kind: nil, media: nil, reactions: nil)
    }
}
