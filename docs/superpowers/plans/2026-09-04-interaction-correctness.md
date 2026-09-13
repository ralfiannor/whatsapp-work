# Interaction Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore native macOS clipboard behavior and make reply, send, navigation, and read acknowledgement safe when users move quickly between chats.

**Architecture:** Keep `AppState` as the single `@MainActor` observable object and add one small pure-policy file for deterministic unit tests. Transcript display and read acknowledgement become separate AppState operations; every send API receives its owning chat explicitly so no post-`await` work reads mutable global selection.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit responder chain, XCTest, XcodeGen, macOS 14.5.

**Spec:** `docs/superpowers/specs/2026-09-04-performance-irc-ux-hardening-design.md`

## Global Constraints

- Preserve `time | nick | message`, monospaced text, `#group` / `@direct`, stable nick colors, and the `List`-backed transcript.
- Do not introduce an `NSTextView` per transcript row, eager history/media loading, polling, or a state-management framework.
- `AppState` remains `@MainActor` and the only `ObservableObject`.
- Fetched message pages must merge with WebSocket and optimistic rows; they must never overwrite newer state after an `await`.
- New endpoints and Go-side changes are out of scope for this plan.
- The repository currently has no `HEAD`. Do not initialize Git or create an initial commit without owner authorization; commit steps are conditional on `rtk git rev-parse --verify HEAD` succeeding.

## File Map

| File | Responsibility after this plan |
|---|---|
| `apps/macos/project.yml` | Defines the macOS unit-test target and scheme membership. |
| `apps/macos/WhatsAppWork/Core/InteractionPolicies.swift` | Pure paste routing, responder dispatch, chat reply storage, navigation intent, unread-boundary calculation, and duplicate-read gate. |
| `apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift` | Unit tests for all deterministic interaction policies. |
| `apps/macos/WhatsAppWork/WhatsAppWorkApp.swift` | Restores Cut/Copy/Paste/Paste and Match Style through the responder chain. |
| `apps/macos/WhatsAppWork/Core/AppState.swift` | Owns chat-scoped reply/send state and separate preview/commit operations. |
| `apps/macos/WhatsAppWork/Views/ChatListView.swift` | Makes keyboard selection preview-only and mouse/Enter explicit commits. |
| `apps/macos/WhatsAppWork/Views/TranscriptView.swift` | Reads reply state by chat, passes chat into sends, and commits on transcript/composer focus. |
| `apps/macos/WhatsAppWork/Views/SearchOverlay.swift` | Marks search-result opens as explicit navigation. |
| `apps/macos/WhatsAppWork/Views/InboxView.swift` | Marks Inbox opens as explicit navigation. |

---

### Task 1: Unit-test target and native pasteboard commands

**Files:**
- Modify: `apps/macos/project.yml`
- Create: `apps/macos/WhatsAppWork/Core/InteractionPolicies.swift`
- Create: `apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/WhatsAppWorkApp.swift:25-35`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:900-909`

**Interfaces:**
- Consumes: `AppState.composerFieldFocused`, `AppState.pastedFileURL()`.
- Produces: `PasteRoute`, `PasteRoutingPolicy.route(composerFocused:hasAttachment:)`, `ResponderActionDispatcher.perform(_:)`, and `AppState.handlePaste() -> Bool`.

- [ ] **Step 1: Add the unit-test target and the failing responder/paste tests**

Add this target and scheme entry to `project.yml`:

```yaml
  WhatsAppWorkTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: WhatsAppWorkTests
    dependencies:
      - target: WhatsAppWork
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES

schemes:
  WhatsAppWork:
    build:
      targets:
        WhatsAppWork: all
        WhatsAppWorkTests: [test]
    test:
      config: Debug
      targets:
        - WhatsAppWorkTests
```

Create `InteractionPoliciesTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Generate the project and verify the tests fail for missing policy types**

Run:

```bash
cd apps/macos
rtk xcodegen generate
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
```

Expected: build failure mentioning `PasteRoutingPolicy` or `ResponderActionDispatcher` not found. A project-generation/schema error is not the expected red state and must be corrected before continuing.

- [ ] **Step 3: Implement the minimal pure policies and responder dispatcher**

Create `InteractionPolicies.swift` with:

```swift
import AppKit
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
```

Change `AppState.handlePaste()` to return whether it consumed an attachment; responder fallback moves to the command layer:

```swift
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
```

Replace the pasteboard command group in `WhatsAppWorkApp`:

```swift
private let responderActions = ResponderActionDispatcher()

CommandGroup(replacing: .pasteboard) {
    Button("Cut") { responderActions.perform(.cut) }
        .keyboardShortcut("x", modifiers: .command)
    Button("Copy") { responderActions.perform(.copy) }
        .keyboardShortcut("c", modifiers: .command)
    Button("Paste") {
        if !state.handlePaste() { responderActions.perform(.paste) }
    }
    .keyboardShortcut("v", modifiers: .command)
    Button("Paste and Match Style") { responderActions.perform(.pasteAndMatchStyle) }
        .keyboardShortcut("v", modifiers: [.command, .option, .shift])
}
```

- [ ] **Step 4: Run the focused tests and regenerate the checked-in Xcode project**

Run:

```bash
cd apps/macos
rtk xcodegen generate
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/InteractionPoliciesTests
```

Expected: both tests pass and `WhatsAppWork.xcodeproj` contains `WhatsAppWorkTests` in the scheme.

- [ ] **Step 5: Manually verify the clipboard acceptance matrix**

Launch the Debug app and verify: selected transcript text copies with Command-C; composer selection copies; text pastes into composer/search; a Finder file or clipboard image stages only while the composer owns focus; Paste and Match Style inserts plain text through the current responder.

- [ ] **Step 6: Commit when the repository has a valid HEAD**

First run `rtk git rev-parse --verify HEAD`. If it succeeds:

```bash
rtk git add apps/macos/project.yml apps/macos/WhatsAppWork.xcodeproj apps/macos/WhatsAppWork/Core/InteractionPolicies.swift apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift apps/macos/WhatsAppWork/WhatsAppWorkApp.swift apps/macos/WhatsAppWork/Core/AppState.swift
rtk git commit -m "fix: restore native clipboard commands"
```

If it fails, record `SKIPPED: repository has no HEAD` in the execution notes and do not initialize Git.

---

### Task 2: Chat-scoped reply state and explicitly owned sends

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/InteractionPolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:42, 528-553, 832-847, 1020-1130`
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift:310-321, 620-650, 816-870, 990-1010`

**Interfaces:**
- Consumes: `Message`, existing optimistic send/reconciliation functions, `draftStore`, and `mentionTargetStore`.
- Produces: `ChatReplyStore`, `AppState.reply(for:)`, `setReply(_:for:)`, `clearReply(for:)`, `send(_:in:)`, `sendReply(_:in:)`, and `sendAttachment(url:caption:in:)`.

- [ ] **Step 1: Add failing tests for reply isolation and consumption**

Append to `InteractionPoliciesTests`:

```swift
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

private func message(id: Int64, chat: String, text: String) -> Message {
    Message(id: id, message_id: "m\(id)", chat_jid: chat,
            sender_jid: "sender@s.whatsapp.net", from_me: false,
            timestamp: 1_700_000_000 + id, kind: "text", text: text,
            reply_to_id: nil, reply_to_sender: nil, quoted_text: nil,
            has_mention: false, mentioned_jids: nil, receipt_status: nil,
            revoked: false, forwarded: nil, edited_ts: nil,
            starred: nil, done: nil, raw_kind: nil, media: nil, reactions: nil)
}
```

- [ ] **Step 2: Run the tests and verify the reply-store test is red**

Run:

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/InteractionPoliciesTests
```

Expected: failure because `ChatReplyStore` does not exist.

- [ ] **Step 3: Add `ChatReplyStore` and expose chat-scoped AppState methods**

Append to `InteractionPolicies.swift`:

```swift
struct ChatReplyStore {
    private var replies: [String: Message] = [:]

    func reply(for chatJID: String) -> Message? {
        guard let value = replies[chatJID], value.chat_jid == chatJID else { return nil }
        return value
    }

    mutating func set(_ message: Message, for chatJID: String) {
        guard message.chat_jid == chatJID else {
            replies.removeValue(forKey: chatJID)
            return
        }
        replies[chatJID] = message
    }

    mutating func take(for chatJID: String) -> Message? {
        defer { replies.removeValue(forKey: chatJID) }
        return reply(for: chatJID)
    }

    mutating func clear(_ chatJID: String? = nil) {
        if let chatJID { replies.removeValue(forKey: chatJID) }
        else { replies.removeAll() }
    }
}
```

Replace global `pendingReply` with:

```swift
@Published private var replyStore = ChatReplyStore()

func reply(for chatJID: String) -> Message? { replyStore.reply(for: chatJID) }
func setReply(_ message: Message, for chatJID: String) { replyStore.set(message, for: chatJID) }
func clearReply(for chatJID: String) { replyStore.clear(chatJID) }
```

Call `replyStore.clear()` from `clearSessionData()`.

- [ ] **Step 4: Make all send entry points capture their owning chat before awaiting**

Use these signatures and rules in `AppState`:

```swift
func send(_ text: String, in chatJID: String) async {
    await deliver(text, in: chatJID, reply: nil)
}

func sendReply(_ text: String, in chatJID: String) async {
    let target = replyStore.take(for: chatJID)
    await deliver(text, in: chatJID, reply: target)
}

private func deliver(_ text: String, in chat: String, reply: Message?) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let api, !trimmed.isEmpty else { return }
    let activeTargets = lastOpenedChat == chat ? mentionTargets : (mentionTargetStore[chat] ?? [:])
    let mentioned = activeTargets.compactMap { jid, label in
        containsMentionToken(trimmed, label: label) ? jid : nil
    }
    let wireText = wireMentionText(trimmed, chat: chat, mentioned: mentioned,
                                   targets: activeTargets)
    let temp = makePendingMessage(chat: chat, text: trimmed, reply: reply)
    upsert(temp, in: chat)
    bumpChat(with: temp)
    do {
        let message = try await api.send(
            chat: chat,
            text: wireText,
            replyTo: reply.map { ($0.message_id, $0.sender_jid) },
            mentionedJids: mentioned
        )
        reconcilePending(temp, with: message, in: chat)
        bumpChat(with: message)
        mentionTargetStore[chat] = [:]
        if lastOpenedChat == chat { mentionTargets.removeAll() }
    } catch {
        markPendingFailed(temp, in: chat)
        toast = "Send failed: \(error.localizedDescription)"
    }
}
```

Change `wireMentionText` to accept the captured `targets: [String: String]`
instead of consulting the mutable active-chat dictionary. Change attachment
sending to `sendAttachment(url:caption:in:)`; capture
`replyStore.take(for: chatJID)` before the upload `await` and never consult
`selectedChat` after entry.

- [ ] **Step 5: Update ComposerBar and every Reply action to use its chat key**

Use `state.reply(for: chatJID)` in the reply banner and submit path. Replace every direct assignment with:

```swift
state.setReply(message, for: message.chat_jid)
state.composerFocusRequest += 1
```

Composer submission must call:

```swift
if let url = attachmentURL {
    _ = await state.sendAttachment(url: url, caption: text, in: chatJID)
} else if state.reply(for: chatJID) != nil {
    await state.sendReply(text, in: chatJID)
} else {
    await state.send(text, in: chatJID)
}
```

- [ ] **Step 6: Run tests and compile Debug**

Run:

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/InteractionPoliciesTests
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: tests pass and `BUILD SUCCEEDED`. Manually start replies in chats A and B, switch repeatedly, and confirm each reply banner and send stays with its own chat.

- [ ] **Step 7: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/InteractionPolicies.swift apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift
rtk git commit -m "fix: scope replies and sends to chats"
```

Skip without initializing Git when `rtk git rev-parse --verify HEAD` fails.

---

### Task 3: Preview-only keyboard navigation and idempotent read commits

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/InteractionPolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:743-813, 1355-1432`
- Modify: `apps/macos/WhatsAppWork/Views/ChatListView.swift:70-108, 135-151`
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift:171-322, 550-625`
- Modify: `apps/macos/WhatsAppWork/Views/SearchOverlay.swift:61-73`
- Modify: `apps/macos/WhatsAppWork/Views/InboxView.swift:45-65, 135-195, 240-250`

**Interfaces:**
- Consumes: `APIClient.messages`, `APIClient.markRead`, `mergeMessages`, `UnreadBoundary`, and all explicit-open call sites.
- Produces: `ChatOpenSource.acknowledgesRead`, `ReadCommitGate`, `UnreadBoundaryPolicy.resolve`, `AppState.previewChat`, and `AppState.commitRead`.

- [ ] **Step 1: Add failing navigation, read-gate, and unread-boundary tests**

Append:

```swift
func testOnlyExplicitNavigationSourcesAcknowledgeRead() {
    XCTAssertFalse(ChatOpenSource.keyboardSelection.acknowledgesRead)
    for source in [ChatOpenSource.enter, .mouse, .transcriptFocus,
                   .composerFocus, .search, .inbox, .notification, .deepLink] {
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
```

- [ ] **Step 2: Run the focused test and confirm missing navigation types fail**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/InteractionPoliciesTests
```

Expected: compile failure for `ChatOpenSource`, `ReadCommitGate`, or `UnreadBoundaryPolicy`.

- [ ] **Step 3: Implement pure navigation/read policies**

Append:

```swift
enum ChatOpenSource: CaseIterable {
    case keyboardSelection, enter, mouse, transcriptFocus, composerFocus
    case search, inbox, notification, deepLink

    var acknowledgesRead: Bool { self != .keyboardSelection }
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

struct UnreadBoundary: Equatable {
    let rowID: Int64?
    let count: Int
}

enum UnreadBoundaryPolicy {
    static func resolve(unreadCount: Int, messages: [Message]) -> UnreadBoundary? {
        guard unreadCount > 0 else { return nil }
        let incoming = messages.filter { !$0.from_me }
        guard incoming.count >= unreadCount else {
            return .init(rowID: nil, count: unreadCount)
        }
        return .init(rowID: incoming[incoming.count - unreadCount].id, count: unreadCount)
    }
}
```

Move `UnreadBoundary` out of `AppState` into `InteractionPolicies.swift` and
make `rowID` optional as shown above. Keep
`@Published var unreadBoundaries: [String: UnreadBoundary]` in AppState so the
next UX plan can render the honest bounded-window marker without crossing a
main-actor boundary from the pure policy.

- [ ] **Step 4: Split AppState display from acknowledgement**

Replace the monolithic `open` path with:

```swift
private var readCommitGate = ReadCommitGate()

func previewChat(_ chat: String, anchorMessageID: String? = nil) async {
    pendingAnchor = anchorMessageID.map { PendingAnchor(chatJID: chat, messageID: $0) }
    switchOpenedChat(to: chat)
    selectedChat = chat
    guard let api else { return }
    if let response = try? await api.messages(chat: chat) {
        mergeMessages(response.messages, into: chat)
        if let count = unreadBoundaries[chat]?.count
            ?? chats.first(where: { $0.jid == chat })?.unread_count,
           count > 0 {
            unreadBoundaries[chat] = UnreadBoundaryPolicy.resolve(
                unreadCount: count,
                messages: messagesByChat[chat] ?? []
            )
        }
    }
    if chat.hasSuffix("@g.us") { Task { await loadMembers(for: chat) } }
}

func commitRead(_ chat: String, source: ChatOpenSource) async {
    guard source.acknowledgesRead, let api else { return }
    let unread = unreadBoundaries[chat]?.count
        ?? chats.first(where: { $0.jid == chat })?.unread_count
        ?? 0
    guard readCommitGate.begin(chat, unreadCount: unread) else { return }
    unreadBoundaries[chat] = UnreadBoundaryPolicy.resolve(
        unreadCount: unread,
        messages: messagesByChat[chat] ?? []
    )
    defer { readCommitGate.finish(chat) }
    do {
        try await api.markRead(chat: chat)
        if let index = chats.firstIndex(where: { $0.jid == chat }) {
            chats[index].unread_count = 0
            chats[index].mentioned_unread = 0
        }
        updateDockBadge()
    } catch {
        toast = "Mark read failed: \(error.localizedDescription)"
    }
}

func open(_ chat: String, anchorMessageID: String? = nil,
          source: ChatOpenSource) async {
    await previewChat(chat, anchorMessageID: anchorMessageID)
    await commitRead(chat, source: source)
}
```

Extract the pre-fetch chat switching block from current `open` into
`switchOpenedChat(to:)`. Transcript LRU tracking is added by the next plan;
this plan does not introduce a placeholder/no-op retention method.

- [ ] **Step 5: Wire keyboard preview, Enter, mouse, transcript, and composer intent**

In `ChatListView`, keep `List(selection:)`, change its selection observer to `previewChat`, add Enter, and add a simultaneous row tap that commits without causing a second page fetch:

```swift
.onChange(of: state.selectedChat) { _, jid in
    if let jid { Task { await state.previewChat(jid) } }
}
.onKeyPress(.return) {
    guard let jid = state.selectedChat else { return .ignored }
    Task { await state.commitRead(jid, source: .enter) }
    return .handled
}
```

On `ChatRow.rowBody`:

```swift
.simultaneousGesture(TapGesture().onEnded {
    Task { await state.commitRead(chat, source: .mouse) }
})
```

Add a `@FocusState` to `MessageList` and call `commitRead(chatJID, source: .transcriptFocus)` when it becomes focused or is clicked. In `ComposerBar`'s existing `fieldFocused` observer, call `commitRead(chatJID, source: .composerFocus)` only on the `true` transition.

- [ ] **Step 6: Label every explicit navigation call site**

Use these sources:

```swift
// SearchOverlay / AppState.jump
await open(jid, anchorMessageID: anchorMessageID, source: .search)

// InboxView rows
await open(chatJID, anchorMessageID: messageID, source: .inbox)

// AppState.openChat(fromNotification:)
await open(chat, source: .notification)

// AppState.handleWhatsAppLink(_:)
await open(jid, source: .deepLink)

// jumpNextUnread: preview only
await previewChat(next.jid)

// Profile “Message” action
await open(profile.jid, source: .mouse)
```

The ChatRow context command “Mark Read” calls `commitRead(chat, source: .mouse)`; do not fetch the transcript just to mark it.

- [ ] **Step 7: Run tests, build, and exercise the read matrix**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
```

Expected automated result: all tests pass and Debug builds. Manual result: J/K and arrow selection changes the visible transcript without changing unread badges; Enter, click, transcript focus, composer focus, Search, Inbox, notification, and wa.me clear unread once; failed `/read` keeps the local unread count.

- [ ] **Step 8: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/InteractionPolicies.swift apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/ChatListView.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift apps/macos/WhatsAppWork/Views/SearchOverlay.swift apps/macos/WhatsAppWork/Views/InboxView.swift
rtk git commit -m "fix: separate chat preview from read state"
```

Skip without initializing Git when there is no valid `HEAD`.

---

### Task 4: Interaction-plan regression gate

**Files:**
- Modify: `docs/performance.md`

**Interfaces:**
- Consumes: completed Tasks 1-3.
- Produces: recorded build/test outcome and manual clipboard/read verification notes.

- [ ] **Step 1: Run the complete Swift regression gate**

```bash
cd apps/macos
rtk xcodegen generate
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: test suite passes; Debug and Release end with `BUILD SUCCEEDED`.

- [ ] **Step 2: Run focused manual regression checks**

Verify transcript scrolling remains smooth while selecting text; no row gained an AppKit text view; Command-C copies the exact selected substring; rapid chat switches during text/reply/media sends never move a row or clear another chat's state; J/K scanning does not mark read.

- [ ] **Step 3: Record evidence**

Add a dated “Interaction correctness” subsection to `docs/performance.md`.
Copy the exact `Executed ... tests, with 0 failures` line from the test result,
record `BUILD SUCCEEDED` for Debug and Release, list the five clipboard-matrix
outcomes as pass/fail, and state that the transcript implementation remains
`List` + SwiftUI `Text`. Do not claim FPS, p95 latency, or idle energy numbers
until the signpost/Instruments plan has measured them.

- [ ] **Step 4: Commit when HEAD exists**

```bash
rtk git add docs/performance.md
rtk git commit -m "docs: record interaction regression checks"
```

Skip without initializing Git when there is no valid `HEAD`.
