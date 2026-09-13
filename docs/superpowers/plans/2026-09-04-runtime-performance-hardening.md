# Runtime Performance Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate unnecessary idle work and main-thread I/O, bound transcript memory, and remove measured hot-path waste without changing the app’s UI architecture.

**Architecture:** Add small value-type policies for freshness, refresh ordering, sleep assertion state, attachment preflight, transcript retention, and badge invalidation. `AppState` remains the sole UI store; `APIClient` remains the network actor; Go media eviction remains inside its existing manager/storage boundary but becomes one batched background pass.

**Tech Stack:** Swift 5.10 concurrency, SwiftUI, URLSession WebSocket, IOKit power assertions, XCTest, Go 1.26, SQLite/FTS5, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-04-performance-irc-ux-hardening-design.md`

## Global Constraints

- Transcript rows remain SwiftUI `Text` in `List`; no per-row AppKit views or layout rewrite.
- A connected WebSocket with activity younger than 60 seconds performs zero fallback HTTP polling.
- Contact refresh is event-driven after the bounded 45/180-second connect follow-ups; there is no repeating five-minute timer.
- Sidecar sleep prevention is active only during non-terminal sync progress and is capped at ten minutes.
- Attachment metadata and bytes are read outside `@MainActor`; the send cap remains exactly 20 MiB.
- `messagesByChat` retains the active chat plus nine recent chats and never evicts a chat containing a negative-id optimistic row.
- Actual downloaded media bytes remain authoritative for all cap decisions.
- SQLite hot queries require `EXPLAIN QUERY PLAN`; `SCAN messages` in a request path is forbidden.
- Retain only optimizations that build, pass race tests, and do not regress the relevant before/after measurement.
- The repository currently has no `HEAD`; do not initialize Git. Commit steps run only when `rtk git rev-parse --verify HEAD` succeeds.

## File Map

| File | Responsibility after this plan |
|---|---|
| `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift` | Pure WebSocket freshness, refresh sequence, sync-sleep, attachment, transcript LRU, and event-invalidation policies. |
| `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift` | Deterministic tests for runtime policies and attachment preflight. |
| `apps/macos/WhatsAppWork/Core/APIClient.swift` | Heartbeat callback and single-pass typed WebSocket event decoding. |
| `apps/macos/WhatsAppWork/Core/AppState.swift` | Uses heartbeat freshness, cancellable follow-ups, off-main attachment reads, LRU retention, and selective badge updates. |
| `apps/macos/WhatsAppWork/Core/SidecarManager.swift` | Applies the tested sync-sleep state machine and never asserts at spawn. |
| `apps/macos/project.yml` | Declares sidecar build-script inputs and outputs. |
| `core/internal/storage/media.go` | Selects enough LRU victims and clears their DB state in one transaction. |
| `core/internal/storage/media_test.go` | Tests cumulative victim selection and atomic batch state changes. |
| `core/internal/media/manager.go` | Coalesces eviction requests onto a managed background worker. |
| `core/internal/media/manager_test.go` | Tests asynchronous batch eviction and orderly manager shutdown. |
| `core/cmd/whatsapp-core/main.go` | Closes the media worker during shutdown. |
| `docs/performance.md` | Records before/after runtime evidence. |

---

### Task 1: WebSocket heartbeat freshness and zero healthy polling

**Files:**
- Create: `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift`
- Create: `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/APIClient.swift:509-544`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:13-17, 158-185, 1448-1465`

**Interfaces:**
- Consumes: `APIClient.connectEvents`, the core’s 25-second application-level ping, and `connectionState`.
- Produces: `WebSocketFreshnessPolicy.shouldPoll(now:lastActivityAt:connectionState:)`, `APIClient.connectEvents(onEvent:onHeartbeat:onDisconnect:)`, and `AppState.lastWSActivityAt`.

- [ ] **Step 1: Add failing freshness tests**

Create `RuntimePoliciesTests.swift`:

```swift
import Foundation
import XCTest
@testable import WhatsAppWork

final class RuntimePoliciesTests: XCTestCase {
    func testFreshConnectedWebSocketSuppressesPoll() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(WebSocketFreshnessPolicy.shouldPoll(
            now: now, lastActivityAt: now.addingTimeInterval(-59), connectionState: "connected"
        ))
    }

    func testStaleOrUnprovenWebSocketAllowsRecoveryPoll() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
            now: now, lastActivityAt: now.addingTimeInterval(-61), connectionState: "connected"
        ))
        XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
            now: now, lastActivityAt: nil, connectionState: "connected"
        ))
        XCTAssertTrue(WebSocketFreshnessPolicy.shouldPoll(
            now: now, lastActivityAt: now, connectionState: "offline"
        ))
    }
}
```

- [ ] **Step 2: Run the focused tests and verify the missing policy fails**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/RuntimePoliciesTests
```

Expected: compile failure for `WebSocketFreshnessPolicy`.

- [ ] **Step 3: Implement the freshness policy and heartbeat callback**

Create `RuntimePolicies.swift`:

```swift
import Foundation

enum WebSocketFreshnessPolicy {
    static let freshInterval: TimeInterval = 60

    static func shouldPoll(now: Date, lastActivityAt: Date?,
                           connectionState: String) -> Bool {
        guard connectionState == "connected", let lastActivityAt else { return true }
        return now.timeIntervalSince(lastActivityAt) >= freshInterval
    }
}
```

Extend the WebSocket API without publishing heartbeat state:

```swift
func connectEvents(onEvent: @escaping (CoreEvent) -> Void,
                   onHeartbeat: @escaping () -> Void = {},
                   onDisconnect: @escaping () -> Void = {}) {
    // existing request/task setup
    receiveLoop(task, onEvent, onHeartbeat, onDisconnect)
}

private func receiveLoop(_ task: URLSessionWebSocketTask,
                         _ onEvent: @escaping (CoreEvent) -> Void,
                         _ onHeartbeat: @escaping () -> Void,
                         _ onDisconnect: @escaping () -> Void) {
    task.receive { [weak self] result in
        guard let self else { return }
        switch result {
        case .success(let message):
            if case .string(let text) = message, let event = CoreEvent.decode(text: text) {
                if case .ping = event {
                    Task {
                        do {
                            try await task.send(.string(#"{"type":"pong"}"#))
                            onHeartbeat()
                        } catch {
                            onDisconnect()
                        }
                    }
                } else {
                    onEvent(event)
                }
            }
            self.receiveLoop(task, onEvent, onHeartbeat, onDisconnect)
        case .failure:
            onDisconnect()
        }
    }
}
```

- [ ] **Step 4: Make AppState gate fallback work on ping freshness**

Rename `lastEventAt` to non-published `lastWSActivityAt`. Remove the timestamp
write from `apply`; set it exactly once at the WebSocket callback boundary for
normal events and successful heartbeat pongs:

```swift
await client.connectEvents { [weak self] event in
    Task { @MainActor in
        self?.lastWSActivityAt = Date()
        self?.apply(event)
    }
} onHeartbeat: { [weak self] in
    Task { @MainActor in
        self?.lastWSActivityAt = Date()
        self?.wsReconnectAttempts = 0
    }
} onDisconnect: { [weak self] in
    Task { @MainActor in self?.scheduleWSReconnect() }
}
```

In the 15-second timer:

```swift
guard WebSocketFreshnessPolicy.shouldPoll(
    now: Date(),
    lastActivityAt: self.lastWSActivityAt,
    connectionState: self.connectionState
) else { return }
await self.refreshSession()
await self.refreshInbox()
```

- [ ] **Step 5: Run tests and build**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/RuntimePoliciesTests
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: tests pass and Debug builds. With a connected account idle for 75 seconds, loopback request logging must show no `/session` or `/inbox` request while pings continue.

- [ ] **Step 6: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/RuntimePolicies.swift apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift apps/macos/WhatsAppWork/Core/APIClient.swift apps/macos/WhatsAppWork/Core/AppState.swift
rtk git commit -m "perf: treat websocket heartbeats as activity"
```

---

### Task 2: One authoritative connection refresh and bounded contact follow-ups

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:91-108, 136-185, 530-667, 1433-1470`

**Interfaces:**
- Consumes: Task 1’s heartbeat connection, `refreshSession`, `refreshChats`, `loadContacts`, and `contacts.updated` debounce.
- Produces: `ConnectionRefreshPlan.steps(for:)`, cancellable `contactNameFollowUpTasks`, and `refreshSession(includeChats:)`.

- [ ] **Step 1: Add failing refresh-order and follow-up tests**

Append:

```swift
func testConnectionRefreshPlansContainOneChatFetch() {
    XCTAssertEqual(ConnectionRefreshPlan.steps(for: .initial), [.session, .events, .chats])
    XCTAssertEqual(ConnectionRefreshPlan.steps(for: .reconnect), [.events, .session, .chats, .openTranscript])
    for reason in [ConnectionRefreshReason.initial, .reconnect] {
        XCTAssertEqual(ConnectionRefreshPlan.steps(for: reason).filter { $0 == .chats }.count, 1)
    }
}

func testContactFollowUpsAreBoundedAndNonRepeating() {
    XCTAssertEqual(ContactFollowUpPolicy.delays, [45, 180])
}
```

- [ ] **Step 2: Run and verify the new policy tests fail**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/RuntimePoliciesTests
```

Expected: missing `ConnectionRefreshPlan` and `ContactFollowUpPolicy` symbols.

- [ ] **Step 3: Implement explicit refresh plans**

Append to `RuntimePolicies.swift`:

```swift
enum ConnectionRefreshReason { case initial, reconnect }
enum ConnectionRefreshStep: Equatable { case session, events, chats, openTranscript }

enum ConnectionRefreshPlan {
    static func steps(for reason: ConnectionRefreshReason) -> [ConnectionRefreshStep] {
        switch reason {
        case .initial: [.session, .events, .chats]
        case .reconnect: [.events, .session, .chats, .openTranscript]
        }
    }
}

enum ContactFollowUpPolicy {
    static let delays: [TimeInterval] = [45, 180]
}
```

Change `refreshSession` to `refreshSession(includeChats: Bool = true)` and only call `refreshChats()` when `includeChats` is true. Execute the initial order as session-without-chats → events → chats, and reconnect as events → session-without-chats → chats → selected transcript merge. Do not call `refreshChats` elsewhere inside those sequences.

Make the tested plan drive production rather than remain test-only:

```swift
private func runConnectionRefresh(_ reason: ConnectionRefreshReason,
                                  client: APIClient) async {
    for step in ConnectionRefreshPlan.steps(for: reason) {
        switch step {
        case .session:
            await refreshSession(includeChats: false)
        case .events:
            await connectWS(client)
        case .chats:
            await refreshChats()
        case .openTranscript:
            guard let chat = selectedChat,
                  let response = try? await client.messages(chat: chat) else { continue }
            mergeMessages(response.messages, into: chat)
        }
    }
}
```

`connectIfNeeded` calls `.initial`; the reconnect task calls `.reconnect`.

- [ ] **Step 4: Replace the repeating contact timer with cancellable tasks**

Replace `contactNamesTimer` with:

```swift
private var contactNameFollowUpTasks: [Task<Void, Never>] = []

private func cancelContactNameFollowUps() {
    contactNameFollowUpTasks.forEach { $0.cancel() }
    contactNameFollowUpTasks.removeAll()
}

private func scheduleContactNameFollowUps() {
    cancelContactNameFollowUps()
    contactNameFollowUpTasks = ContactFollowUpPolicy.delays.map { delay in
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self,
                  self.connectionState == "connected" else { return }
            await self.loadContacts(force: true)
        }
    }
}
```

Call `cancelContactNameFollowUps()` and `contactNamesReloadTask?.cancel()` from logout/session clearing. Keep initial contact load and the debounced forced reload for `contacts.updated`.

- [ ] **Step 5: Verify tests, build, and request counts**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: tests/build pass. One launch and one forced WebSocket reconnect must each produce exactly one `/chats` request in the connection sequence; contact requests occur initially, at 45 seconds, at 180 seconds, or after `contacts.updated`, never every five minutes.

- [ ] **Step 6: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/RuntimePolicies.swift apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift
rtk git commit -m "perf: bound connection refresh work"
```

---

### Task 3: Scope the sidecar power assertion to active sync

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/SidecarManager.swift:175-185, 240-340`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:203-211, 1433-1445`

**Interfaces:**
- Consumes: sync stages from `CoreEvent.syncProgress` and existing IOKit assertion methods.
- Produces: `SleepPreventionSignal`, `SleepPreventionPolicy.apply(_:)`, and `SidecarManager.handleSleepSignal(_:)`.

- [ ] **Step 1: Add failing state-machine tests**

Append:

```swift
func testSleepPreventionOnlyTracksActiveSyncAndCap() {
    var policy = SleepPreventionPolicy()
    XCTAssertFalse(policy.apply(.spawn))
    XCTAssertFalse(policy.apply(.qr))
    XCTAssertTrue(policy.apply(.syncProgress(stage: "history")))
    XCTAssertTrue(policy.apply(.syncProgress(stage: "contacts")))
    XCTAssertFalse(policy.apply(.syncProgress(stage: "done")))
    XCTAssertTrue(policy.apply(.syncProgress(stage: "history")))
    XCTAssertFalse(policy.apply(.capExpired))
    XCTAssertFalse(policy.apply(.termination))
    XCTAssertFalse(policy.apply(.logout))
}
```

- [ ] **Step 2: Run and confirm the missing state machine is red**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/RuntimePoliciesTests
```

Expected: compile failure for `SleepPreventionPolicy`.

- [ ] **Step 3: Implement the pure sleep policy**

Append:

```swift
enum SleepPreventionSignal {
    case spawn, qr, syncProgress(stage: String), capExpired, termination, logout
}

struct SleepPreventionPolicy {
    private(set) var active = false

    mutating func apply(_ signal: SleepPreventionSignal) -> Bool {
        switch signal {
        case .syncProgress(let stage): active = stage != "done"
        case .spawn, .qr, .capExpired, .termination, .logout: active = false
        }
        return active
    }
}
```

- [ ] **Step 4: Wire the policy to SidecarManager and remove spawn assertion**

Delete the `holdPowerAssertion()` call immediately after `p.run()`. Keep policy state queue-confined:

```swift
private var sleepPolicy = SleepPreventionPolicy()

func handleSleepSignal(_ signal: SleepPreventionSignal) {
    if DispatchQueue.getSpecific(key: Self.queueKey) == true {
        applySleepSignal(signal)
    } else {
        queue.async { [weak self] in self?.applySleepSignal(signal) }
    }
}

private func applySleepSignal(_ signal: SleepPreventionSignal) {
    let wasActive = sleepPolicy.active
    let isActive = sleepPolicy.apply(signal)
    if isActive && !wasActive {
        sleepCapGen += 1
        let generation = sleepCapGen
        holdPowerAssertion()
        queue.asyncAfter(deadline: .now() + 600) { [weak self] in
            guard let self, self.sleepCapGen == generation else { return }
            _ = self.sleepPolicy.apply(.capExpired)
            self.releasePowerAssertion()
        }
    } else if !isActive {
        sleepCapGen += 1
        releasePowerAssertion()
    }
}
```

Call `applySleepSignal(.spawn)` directly on the sidecar queue at the start of
`spawn`, then send `.syncProgress(stage:)` from AppState, `.termination` from
process termination/stop, `.logout` on logout, and `.qr` on QR state. Repeated
progress does not re-arm the cap, so ten minutes is a hard maximum from the
first active-sync event. Remove `setSleepPrevention(_:)` after all callers
migrate.

- [ ] **Step 5: Verify automated and power-state behavior**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: tests and Release build pass. `pmset -g assertions` shows no “WhatsAppWork sync” assertion while waiting for QR or connected idle, shows one during sync, and removes it on done/logout/termination or after 600 seconds.

- [ ] **Step 6: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/RuntimePolicies.swift apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift apps/macos/WhatsAppWork/Core/SidecarManager.swift apps/macos/WhatsAppWork/Core/AppState.swift
rtk git commit -m "fix: prevent sleep only during sync"
```

---

### Task 4: Move attachment reads off-main with preflight enforcement

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:907-918, 1093-1130`

**Interfaces:**
- Consumes: chat-explicit `sendAttachment(url:caption:in:)` from the interaction plan.
- Produces: `AttachmentLoader.read(url:maxBytes:)` and `AttachmentReadError`.

- [ ] **Step 1: Add failing preflight tests**

Append:

```swift
func testAttachmentLoaderReadsWithinLimitAndRejectsByMetadata() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("payload.bin")
    try Data([1, 2, 3, 4]).write(to: url)

    XCTAssertEqual(try AttachmentLoader.read(url: url, maxBytes: 4), Data([1, 2, 3, 4]))
    XCTAssertThrowsError(try AttachmentLoader.read(url: url, maxBytes: 3)) { error in
        XCTAssertEqual(error as? AttachmentReadError, .tooLarge(actual: 4, limit: 3))
    }
}
```

- [ ] **Step 2: Run and verify the attachment test is red**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/RuntimePoliciesTests
```

Expected: missing `AttachmentLoader`.

- [ ] **Step 3: Implement metadata-first attachment loading**

Append:

```swift
enum AttachmentReadError: Error, Equatable {
    case unreadable
    case tooLarge(actual: Int64, limit: Int64)

    var isTooLarge: Bool {
        if case .tooLarge = self { return true }
        return false
    }
}

enum AttachmentLoader {
    static func read(url: URL, maxBytes: Int64 = 20 << 20) throws -> Data {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { throw AttachmentReadError.unreadable }
        guard Int64(size) <= maxBytes else {
            throw AttachmentReadError.tooLarge(actual: Int64(size), limit: maxBytes)
        }
        do { return try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw AttachmentReadError.unreadable }
    }
}
```

- [ ] **Step 4: Read bytes in a detached task and return only the result to AppState**

At the start of `sendAttachment`:

```swift
let read = Task.detached(priority: .userInitiated) {
    try AttachmentLoader.read(url: url)
}
let data: Data
do {
    data = try await read.value
} catch let error as AttachmentReadError {
    toast = error.isTooLarge ? "File too large (max 20 MB)" : "Cannot read file"
    return false
} catch {
    toast = "Cannot read file"
    return false
}
```

Mark `AppState.mime(forExtension:)` `nonisolated` if it is also moved into the
detached closure; otherwise compute MIME after the data returns to main.

- [ ] **Step 5: Verify tests, build, and main-thread behavior**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: tests/build pass. In Instruments’ Main Thread track, selecting/sending a 19 MiB file shows no `Data(contentsOf:)` work on the main actor; a file larger than 20 MiB is rejected before byte loading.

- [ ] **Step 6: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/RuntimePolicies.swift apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift
rtk git commit -m "perf: read attachments off main actor"
```

---

### Task 5: Bound transcript retention and dock-badge invalidation

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:185-295, 329-410, 743-830, 1478-1500`

**Interfaces:**
- Consumes: the interaction plan’s `previewChat`, negative optimistic message
  ids, and `CoreEvent`.
- Produces: `TranscriptRetention`, `CoreEvent.affectsDockBadge`, and a real `AppState.touchTranscript(_:)`.

- [ ] **Step 1: Add failing retention and invalidation tests**

Append:

```swift
func testTranscriptRetentionEvictsOldestButProtectsActiveAndPending() {
    var retention = TranscriptRetention(limit: 3)
    ["a", "b", "c", "d"].forEach { retention.touch($0) }
    XCTAssertEqual(retention.evictionCandidates(
        loaded: Set(["a", "b", "c", "d"]), active: "a", protected: Set(["b"])
    ), ["c"])
}

func testOnlyUnreadAffectingEventsInvalidateDockBadge() {
    let message = testMessage(id: 1, chat: "a@s.whatsapp.net")
    XCTAssertTrue(CoreEvent.messageReceived(message).affectsDockBadge)
    XCTAssertTrue(CoreEvent.chatRemoved("a@s.whatsapp.net").affectsDockBadge)
    XCTAssertFalse(CoreEvent.messageUpdated(message).affectsDockBadge)
    XCTAssertFalse(CoreEvent.syncProgress(stage: "history", progress: 0.5).affectsDockBadge)
    XCTAssertFalse(CoreEvent.reaction(rowid: 1, emoji: "👍").affectsDockBadge)
    XCTAssertFalse(CoreEvent.ping.affectsDockBadge)
}
```

Add this independent fixture to `RuntimePoliciesTests`:

```swift
private func testMessage(id: Int64, chat: String, fromMe: Bool = false) -> Message {
    Message(id: id, message_id: "m\(id)", chat_jid: chat,
            sender_jid: "sender@s.whatsapp.net", from_me: fromMe,
            timestamp: 1_700_000_000 + id, kind: "text", text: "body",
            reply_to_id: nil, reply_to_sender: nil, quoted_text: nil,
            has_mention: false, mentioned_jids: nil, receipt_status: nil,
            revoked: false, forwarded: nil, edited_ts: nil,
            starred: nil, done: nil, raw_kind: nil, media: nil, reactions: nil)
}
```

Also assert `CoreEvent.messageReceived(testMessage(id: 2, chat: "a", fromMe: true)).affectsDockBadge` is false.

- [ ] **Step 2: Run and verify retention/invalidation tests fail**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/RuntimePoliciesTests
```

Expected: missing `TranscriptRetention` or `affectsDockBadge`.

- [ ] **Step 3: Implement deterministic LRU and event classification**

Append:

```swift
struct TranscriptRetention {
    let limit: Int
    private var oldestFirst: [String] = []

    init(limit: Int = 10) { self.limit = limit }

    mutating func touch(_ chatJID: String) {
        oldestFirst.removeAll { $0 == chatJID }
        oldestFirst.append(chatJID)
    }

    func evictionCandidates(loaded: Set<String>, active: String?,
                            protected: Set<String>) -> [String] {
        var remaining = loaded
        var victims: [String] = []
        for chat in oldestFirst where remaining.count > limit {
            guard chat != active, !protected.contains(chat), remaining.contains(chat) else { continue }
            victims.append(chat)
            remaining.remove(chat)
        }
        return victims
    }
}

extension CoreEvent {
    var affectsDockBadge: Bool {
        switch self {
        case .messageReceived(let message): !message.from_me
        case .chatUpdated, .chatRemoved: true
        default: false
        }
    }
}
```

- [ ] **Step 4: Apply retention without evicting active or pending sends**

In AppState:

```swift
private var transcriptRetention = TranscriptRetention(limit: 10)

private func touchTranscript(_ chatJID: String) {
    transcriptRetention.touch(chatJID)
    let protected = Set(messagesByChat.compactMap { chat, rows in
        rows.contains(where: { $0.id < 0 }) ? chat : nil
    })
    for victim in transcriptRetention.evictionCandidates(
        loaded: Set(messagesByChat.keys), active: selectedChat, protected: protected
    ) {
        messagesByChat.removeValue(forKey: victim)
    }
}
```

Call `touchTranscript(chat)` after a page merge and after a send creates a protected row. Do not retain a positive-id incoming row for a chat whose transcript was never loaded:

```swift
guard messagesByChat[chat] != nil || chat == selectedChat || m.id < 0 else { return }
```

Continue trimming non-open loaded arrays to their newest 300 rows. Clear the retention value on logout.

- [ ] **Step 5: Update the badge only when unread membership can change**

Replace unconditional `updateDockBadge()` at the end of `apply` with:

```swift
if event.affectsDockBadge { updateDockBadge() }
```

Call `updateDockBadge()` after a successful authoritative `refreshChats`, after explicit mark-read, after Focus Mode changes, and after session clearing. Do not call it for receipts, reactions, media, contacts, sync progress, inbox changes, QR, or ping.

- [ ] **Step 6: Verify tests/build and memory behavior**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: tests/build pass. After opening 25 chats, `messagesByChat.count` is at most 10 unless additional chats contain pending negative-id sends; receipt storms no longer call dock-badge reduction.

- [ ] **Step 7: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/RuntimePolicies.swift apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift
rtk git commit -m "perf: bound transcript and badge work"
```

---

### Task 6: Decode WebSocket events once

**Files:**
- Create: `apps/macos/WhatsAppWorkTests/CoreEventDecodeTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/APIClient.swift:118-234`
- Modify: `docs/performance.md`

**Interfaces:**
- Consumes: existing `CoreEvent` cases and wire payload JSON.
- Produces: `CoreEvent.Envelope: Decodable` and a single `JSONDecoder.decode` per frame.

- [ ] **Step 1: Add correctness and baseline performance tests before changing the decoder**

Create `CoreEventDecodeTests.swift`:

```swift
import XCTest
@testable import WhatsAppWork

final class CoreEventDecodeTests: XCTestCase {
    private let frame = #"{"type":"connection.changed","data":{"state":"connected","reason":"wake"}}"#

    func testTypedEventPayloadsRemainCompatible() {
        XCTAssertEqual(CoreEvent.decode(text: frame),
                       .connectionChanged(state: "connected", reason: "wake"))
        XCTAssertEqual(CoreEvent.decode(text: #"{"type":"ping","data":{}}"#), .ping)
        XCTAssertNil(CoreEvent.decode(text: #"{"type":"unknown","data":{}}"#))
    }

    func testDecodePerformance() {
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<10_000 { _ = CoreEvent.decode(text: frame) }
        }
    }
}
```

- [ ] **Step 2: Run the tests against the old decoder and record the baseline**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release test -only-testing:WhatsAppWorkTests/CoreEventDecodeTests
```

Expected: correctness passes. Record the median clock and memory result in the execution notes before editing `CoreEvent.decode`.

- [ ] **Step 3: Replace JSONSerialization/re-encoding with a custom Decodable envelope**

Inside `CoreEvent`, define payload structs and:

```swift
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
            event = .contactsUpdated(changed: try container.decode(ContactsUpdatedPayload.self, forKey: .data).changed)
        case "inbox.changed":
            event = .inboxChanged(reason: try container.decode(InboxChangedPayload.self, forKey: .data).reason)
        case "reaction.received":
            let value = try container.decode(ReactionPayload.self, forKey: .data)
            event = .reaction(rowid: value.message_rowid, emoji: value.emoji ?? "")
        case "media.updated":
            let value = try container.decode(MediaPayload.self, forKey: .data)
            event = .mediaUpdated(rowid: value.message_rowid, chat: value.chat_jid ?? "",
                                  media: value.media ?? Self.emptyMedia)
        case "ping": event = .ping
        default: event = nil
        }
    }

    private static let emptyMedia = MessageMedia(
        id: "", kind: "", mime: "", size: 0, filename: nil,
        state: "not_downloaded", local_path: nil
    )
}

static func decode(text: String) -> CoreEvent? {
    guard let data = text.data(using: .utf8) else { return nil }
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
    return envelope.event
}
```

Move the existing local payload definitions next to `Envelope` with these
unchanged fields:

```swift
private struct ConnPayload: Decodable { let state: String; var reason: String? }
private struct QRPayload: Decodable { let code: String; let expires_ts: Int64 }
private struct SyncPayload: Decodable { let stage: String; let progress: Double }
private struct MsgPayload: Decodable { let message: Message }
private struct ChatPayload: Decodable { let chat: Chat }
private struct RemovedPayload: Decodable { let jid: String }
private struct ContactsUpdatedPayload: Decodable { var changed: Int? }
private struct InboxChangedPayload: Decodable { var reason: String? }
private struct ReactionPayload: Decodable { let message_rowid: Int64; var emoji: String? }
private struct MediaPayload: Decodable {
    let message_rowid: Int64
    var chat_jid: String?
    var media: MessageMedia?
}
```

- [ ] **Step 4: Re-run correctness and performance; retain only a non-regressing decoder**

```bash
cd apps/macos
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release test -only-testing:WhatsAppWorkTests/CoreEventDecodeTests
```

Expected: correctness passes. Median clock time must not be slower than the old baseline by more than 5%, and allocation/memory output must not increase materially. If it misses, revert only the decoder implementation while retaining correctness tests and record the measured rejection.

- [ ] **Step 5: Record and conditionally commit the result**

Add the exact old/new medians and verdict to the dated performance section. When HEAD exists:

```bash
rtk git add apps/macos/WhatsAppWork/Core/APIClient.swift apps/macos/WhatsAppWorkTests/CoreEventDecodeTests.swift docs/performance.md
rtk git commit -m "perf: decode websocket events once"
```

Use `test: cover websocket event decoding` if measurement rejects the implementation.

---

### Task 7: Batch and background media cache eviction

**Files:**
- Modify: `core/internal/storage/media.go`
- Modify: `core/internal/storage/media_test.go`
- Modify: `core/internal/media/manager.go`
- Modify: `core/internal/media/manager_test.go`
- Modify: `core/cmd/whatsapp-core/main.go:113-123`

**Interfaces:**
- Consumes: `MediaCacheSize`, `idx_media_evict`, current actual-byte `SetMediaDownloaded`, and manager shutdown.
- Produces: `Store.MediaEvictionCandidates(ctx, bytesToFree)`, `Store.ClearDownloadedMedia(ctx, rowIDs)`, `Manager.ScheduleEviction()`, and a managed eviction worker.

- [ ] **Step 1: Add failing storage tests for cumulative victims and batch clearing**

Extend `storage/media_test.go` with three downloaded fixtures sized 4, 5, and
6 bytes. Seed each through `seedMediaMessage`, call `SetMediaDownloaded` with
paths under `t.TempDir()`, and then assert:

```go
victims, err := st.MediaEvictionCandidates(ctx, 8)
if err != nil {
	t.Fatal(err)
}
if len(victims) != 2 || victims[0].Size != 4 || victims[1].Size != 5 {
	t.Fatalf("victims = %+v, want oldest 4+5 bytes", victims)
}
ids := []int64{victims[0].MessageRowID, victims[1].MessageRowID}
if err := st.ClearDownloadedMedia(ctx, ids); err != nil {
	t.Fatal(err)
}
for _, id := range ids {
	row, _ := st.GetMedia(ctx, id)
	if row.State != "not_downloaded" || row.LocalPath != "" {
		t.Fatalf("row %d not cleared: %+v", id, row)
	}
}
```

- [ ] **Step 2: Run the storage test and confirm missing methods fail**

```bash
cd core
rtk go test ./internal/storage -run 'TestMediaEviction' -count=1
```

Expected: compile failure for the two new storage methods.

- [ ] **Step 3: Implement one bounded candidate query and one transaction**

Use the indexed ordering and a window sum:

```go
func (s *Store) MediaEvictionCandidates(ctx context.Context, bytesToFree int64) ([]MediaRow, error) {
	rows, err := s.r.QueryContext(ctx, `
		WITH ranked AS (
			SELECT message_id, local_path, size,
			       SUM(size) OVER (ORDER BY downloaded_at ASC, rowid ASC) AS reclaimed
			FROM media WHERE state = 'downloaded'
		)
		SELECT message_id, local_path, size FROM ranked
		WHERE reclaimed - size < ?
		ORDER BY reclaimed ASC`, bytesToFree)
	if err != nil {
		return nil, fmt.Errorf("storage: media eviction candidates: %w", err)
	}
	defer rows.Close()
	var victims []MediaRow
	for rows.Next() {
		var row MediaRow
		if err := rows.Scan(&row.MessageRowID, &row.LocalPath, &row.Size); err != nil {
			return nil, fmt.Errorf("storage: media eviction candidate scan: %w", err)
		}
		victims = append(victims, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("storage: media eviction candidates rows: %w", err)
	}
	return victims, nil
}

func (s *Store) ClearDownloadedMedia(ctx context.Context, rowIDs []int64) error {
	if len(rowIDs) == 0 { return nil }
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil { return fmt.Errorf("storage: media eviction begin: %w", err) }
	defer tx.Rollback()
	stmt, err := tx.PrepareContext(ctx, `UPDATE media SET state='not_downloaded',
		local_path='', downloaded_at=NULL, updated_at=strftime('%s','now') WHERE message_id=?`)
	if err != nil { return fmt.Errorf("storage: media eviction prepare: %w", err) }
	defer stmt.Close()
	for _, id := range rowIDs {
		if _, err := stmt.ExecContext(ctx, id); err != nil {
			return fmt.Errorf("storage: media eviction row %d: %w", id, err)
		}
	}
	if err := tx.Commit(); err != nil { return fmt.Errorf("storage: media eviction commit: %w", err) }
	return nil
}
```

- [ ] **Step 4: Run storage tests and inspect the query plan**

```bash
cd core
rtk go test ./internal/storage -run 'TestMedia' -count=1
```

Run `EXPLAIN QUERY PLAN` for the candidate query against a migrated fixture. Expected: media rows are ordered via `idx_media_evict`; there must be no `SCAN messages`.

- [ ] **Step 5: Add a coalescing eviction worker and a failing async manager test**

Change the LRU test to request the new worker explicitly and wait until
eviction completes rather than assuming it occurs before
`EnsureDownloaded` returns. Add immediately after the second download:

```go
m.ScheduleEviction()
deadline := time.Now().Add(2 * time.Second)
for time.Now().Before(deadline) {
	row1, _ := st.GetMedia(context.Background(), m1.ID)
	if row1.State == "not_downloaded" { break }
	time.Sleep(10 * time.Millisecond)
}
row1, _ := st.GetMedia(context.Background(), m1.ID)
if row1.State != "not_downloaded" {
	t.Fatalf("background eviction did not complete: %+v", row1)
}
```

Run `rtk go test ./internal/media -run TestLRUEviction -count=1`; it should
fail to compile because `ScheduleEviction` does not exist.

- [ ] **Step 6: Implement managed asynchronous eviction**

Add these fields to `Manager`:

```go
ctx     context.Context
cancel  context.CancelFunc
evictCh chan struct{}
wg      sync.WaitGroup
```

Create them and start exactly one worker in `New`:

```go
workerCtx, cancel := context.WithCancel(context.Background())
m := &Manager{
	store: store, dl: dl, dir: dir, maxBytes: maxBytes,
	sem: make(chan struct{}, maxConcurrent), log: slog.Default(),
	onUpdate: onUpdate, inflight: make(map[int64]chan struct{}),
	ctx: workerCtx, cancel: cancel, evictCh: make(chan struct{}, 1),
}
m.wg.Add(1)
go m.evictionLoop()
return m, nil
```

Implement the worker:

```go
func (m *Manager) evictionLoop() {
	defer m.wg.Done()
	for {
		select {
		case <-m.ctx.Done(): return
		case <-m.evictCh: m.EvictLRU(m.ctx)
		}
	}
}

func (m *Manager) ScheduleEviction() {
	select {
	case m.evictCh <- struct{}{}:
	default:
	}
}

func (m *Manager) Close() error {
	m.cancel()
	m.wg.Wait()
	return nil
}
```

Replace the response-path `m.EvictLRU(ctx)` with `m.ScheduleEviction()`. Rewrite `EvictLRU` to call `MediaCacheSize` once, request enough candidates once, remove their files, and call `ClearDownloadedMedia` once. Continue logging each victim. Add `defer mediaMgr.Close()` in `main.go`; keep the synchronous startup reconciliation.

Use this single-pass body:

```go
func (m *Manager) EvictLRU(ctx context.Context) {
	total, _, err := m.store.MediaCacheSize(ctx)
	if err != nil { m.log.Error("media: cache size", "err", err); return }
	overflow := total - m.maxBytes
	if overflow <= 0 { return }
	victims, err := m.store.MediaEvictionCandidates(ctx, overflow)
	if err != nil { m.log.Error("media: evict lookup", "err", err); return }
	ids := make([]int64, 0, len(victims))
	for _, victim := range victims {
		if victim.LocalPath != "" { _ = os.Remove(victim.LocalPath) }
		ids = append(ids, victim.MessageRowID)
	}
	if err := m.store.ClearDownloadedMedia(ctx, ids); err != nil {
		m.log.Error("media: evict state", "err", err)
		return
	}
	for _, victim := range victims {
		m.log.Info("media: evicted", "row", victim.MessageRowID, "bytes", victim.Size)
	}
}
```

- [ ] **Step 7: Run all Go verification including race**

```bash
cd core
rtk gofmt -w internal/storage/media.go internal/storage/media_test.go internal/media/manager.go internal/media/manager_test.go cmd/whatsapp-core/main.go
rtk go test ./...
rtk go vet ./...
rtk go test -race ./internal/app ./internal/whatsapp ./internal/storage ./internal/ipc ./internal/media
```

Expected: all commands pass with no race report.

- [ ] **Step 8: Benchmark and conditionally commit**

Before changing `EvictLRU`, add `fmt` to `manager_test.go`'s imports, add this
benchmark, and record
its median; run the same benchmark after the batch implementation:

```go
func BenchmarkEvictLRU100(b *testing.B) {
	ctx := context.Background()
	st, err := storage.Open(ctx, b.TempDir(), nil)
	if err != nil { b.Fatal(err) }
	b.Cleanup(func() { _ = st.Close() })
	cacheDir := b.TempDir()
	m, err := media.New(st, &fakeDL{data: []byte("x")}, cacheDir, 1, 1, nil)
	if err != nil { b.Fatal(err) }
	b.Cleanup(func() { _ = m.Close() })
	jid := "bench@s.whatsapp.net"
	if err := st.EnsureChat(ctx, core.Chat{JID: jid, Kind: core.KindDirect, DisplayName: "Bench"}); err != nil {
		b.Fatal(err)
	}
	rowIDs := make([]int64, 101)
	paths := make([]string, 101)
	for i := range rowIDs {
		message := core.Message{
			MessageID: fmt.Sprintf("bench-%03d", i), ChatJID: jid, SenderJID: jid,
			Timestamp: int64(1_700_000_000 + i), Kind: core.KindImage,
			Source: "live", MentionedJIDs: []string{},
			Media: &core.MediaMeta{Kind: "image", MIME: "image/png", Size: 1,
				URL: "u", DirectPath: "/p", Proto: []byte("p")},
		}
		if _, err := st.InsertMessage(ctx, &message); err != nil { b.Fatal(err) }
		rowIDs[i] = message.ID
		paths[i] = filepath.Join(cacheDir, fmt.Sprintf("bench-%03d.bin", i))
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		for j, rowID := range rowIDs {
			_ = os.WriteFile(paths[j], []byte("x"), 0o600)
			if err := st.SetMediaDownloaded(ctx, rowID, paths[j], 1); err != nil { b.Fatal(err) }
		}
		b.StartTimer()
		m.EvictLRU(ctx)
	}
}
```

Run:

```bash
rtk go test ./internal/media -run XXX -bench BenchmarkEvictLRU100 -benchmem -count=5
```

The new implementation must use one size query, one candidate query, and one
DB transaction, and `EnsureDownloaded` must return before eviction finishes.
When HEAD exists:

```bash
rtk git add core/internal/storage/media.go core/internal/storage/media_test.go core/internal/media/manager.go core/internal/media/manager_test.go core/cmd/whatsapp-core/main.go
rtk git commit -m "perf: batch media cache eviction"
```

---

### Task 8: Make sidecar bundling incremental and run the runtime gate

**Files:**
- Modify: `apps/macos/project.yml`
- Regenerate: `apps/macos/WhatsAppWork.xcodeproj/project.pbxproj`
- Modify: `docs/performance.md`

**Interfaces:**
- Consumes: built `dist/whatsapp-core` and all previous runtime tasks.
- Produces: Xcode dependency-analysis inputs/outputs and final measured runtime record.

- [ ] **Step 1: Measure the unchanged Debug rebuild before editing the build phase**

```bash
rtk ./scripts/build-core.sh
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
```

Record the second build duration and confirm the “Bundle Go Core” phase runs with the current dependency-analysis warning.

- [ ] **Step 2: Declare exact sidecar input and output paths**

In the existing post-build script entry add:

```yaml
        basedOnDependencyAnalysis: true
        inputFiles:
          - $(SRCROOT)/../../dist/whatsapp-core
        outputFiles:
          - $(BUILT_PRODUCTS_DIR)/$(PRODUCT_NAME).app/Contents/MacOS/whatsapp-core
```

Regenerate with `rtk xcodegen generate`.

- [ ] **Step 3: Rebuild twice and verify the phase skips safely**

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
rtk codesign --verify --deep --strict "build/DerivedData/Build/Products/Debug/WhatsApp Work.app"
```

Expected: first build bundles the sidecar, second unchanged build omits the script warning/work, the app remains validly signed, and second-build time does not regress.

- [ ] **Step 4: Run the complete runtime verification matrix**

```bash
rtk go build ./...
rtk go vet ./...
rtk go test ./...
rtk go test -race ./internal/app ./internal/whatsapp ./internal/storage ./internal/ipc ./internal/media
rtk env WW_BENCH_N=150000 go test ./internal/storage -run XXX -bench . -benchmem
rtk ../scripts/build-core.sh
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: all tests/builds pass; the universal binary reports both `x86_64` and `arm64`; ListMessages and ChatsPage remain within their recorded range; FTS remains below the 100 ms budget.

- [ ] **Step 5: Record exact evidence, including rejected optimizations**

Add this filled table under a dated heading in `docs/performance.md`:

```markdown
| Runtime metric | Before | After | Budget | Verdict |
|---|---:|---:|---:|---|
| Healthy-idle fallback requests / 5 min | value from pre-change request log | value from post-change request log | 0 | PASS only when after is 0 |
| Connected idle CPU / RSS | pre-change five-minute sample | post-change five-minute sample | ≤1% / app <90 MB | compare to budget |
| Attachment main-thread read time, 19 MiB | pre-change Instruments sample | post-change Instruments sample | 0 ms | PASS only when no read is on main |
| Retained transcript chats after opening 25 | pre-change debugger count | post-change debugger count | ≤10 plus pending | compare to budget |
| CoreEvent decode, 10k frames | old XCTest median | new XCTest median | no >5% regression | compare medians |
| Media eviction, 100 victims | old benchmark median | new benchmark median | one size query + one transaction | compare query count and time |
| Incremental Debug rebuild | old second-build duration | new second-build duration | no regression | compare durations |
```

Replace each descriptive value cell with the exact result collected by the
preceding steps; do not write estimates.

- [ ] **Step 6: Commit when HEAD exists**

```bash
rtk git add apps/macos/project.yml apps/macos/WhatsAppWork.xcodeproj/project.pbxproj docs/performance.md
rtk git commit -m "build: skip unchanged sidecar bundling"
```
