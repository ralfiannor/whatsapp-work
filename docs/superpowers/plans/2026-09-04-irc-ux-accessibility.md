# IRC UX and Accessibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the IRC transcript visually intact while making surrounding controls, narrow-window behavior, search, errors, unread context, and VoiceOver comfortable for daily macOS use.

**Architecture:** Preserve the current `NavigationSplitView`, virtualized transcript `List`, Equatable row wall, and SwiftUI `Text` renderer. Add pure preference/layout/load-state/selection/accessibility policies, one lightweight Settings view, and one width preference for the single open transcript; no per-row geometry readers or new UI framework.

**Tech Stack:** Swift 5.10, SwiftUI, AppKit pasteboard, XCTest, OSSignposter, Instruments, macOS 14.5.

**Spec:** `docs/superpowers/specs/2026-09-04-performance-irc-ux-hardening-design.md`

## Global Constraints

- Keep the transcript content model exactly `time | nick | message`, monospaced, virtualized by `List`, with stable nick colors and `#`/`@` channel notation.
- New installs use Comfortable transcript density; existing stored `transcriptDensity` values remain untouched.
- Appearance choices are System, Dark, and Dark High Contrast; no GPU-heavy global filter is allowed.
- Persistent raw JID/LID text leaves the primary header but stays available through explicit Copy actions.
- The 180 pt member panel appears inline only at a safe detail width; narrow layouts use one sheet or popover.
- Photo interpolation is normal; only stickers may use nearest-neighbor interpolation.
- Color is never the only signal for unread, mention, Focus Mode, failed, done, or starred states.
- Search and Inbox failures preserve last-known content and expose Retry.
- Unread counts larger than the loaded page never trigger eager full-history loading.
- Performance verdicts require signposts/Instruments numbers on the 2018-class Intel machine.
- The repository currently has no `HEAD`; do not initialize Git. Commit steps are conditional on `rtk git rev-parse --verify HEAD` succeeding.

## File Map

| File | Responsibility after this plan |
|---|---|
| `apps/macos/WhatsAppWork/Core/UXPolicies.swift` | Appearance defaults, member-panel layout, preserving load state, search selection, and accessibility summary policies. |
| `apps/macos/WhatsAppWork/Core/PerformanceSignposts.swift` | Central, low-overhead OSSignposter lifecycle for UI budgets. |
| `apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift` | Tests defaults, adaptive layout, stale-data preservation, stable search selection, and row summaries. |
| `apps/macos/WhatsAppWork/Views/AppearanceSettingsView.swift` | Native Settings UI for appearance, density, and transcript text size. |
| `apps/macos/WhatsAppWork/WhatsAppWorkApp.swift` | Applies selected appearance and adds the Settings scene. |
| `apps/macos/WhatsAppWork/Core/AppState.swift` | Preserves Inbox/search errors, resolves bounded unread markers, exposes copy-identity helpers, and emits signpost lifecycle events. |
| `apps/macos/WhatsAppWork/Views/TranscriptView.swift` | Adaptive member panel, compact Info menu, readable metadata, unread top marker, media interpolation, accessibility labels, and signpost completion. |
| `apps/macos/WhatsAppWork/Views/SearchOverlay.swift` | Stable IDs, automatic keyboard scrolling, Escape, and explicit search states. |
| `apps/macos/WhatsAppWork/Views/InboxView.swift` | Stale-content error banner and retryable first-load failure. |
| `apps/macos/WhatsAppWork/Views/ChatListView.swift` | Accessible chat-row and Focus Mode control descriptions. |
| `docs/performance.md` | Before/after UI measurements and final budget verdicts. |

---

### Task 0: Instrument UI hot paths and capture the pre-UX baseline

**Files:**
- Create: `apps/macos/WhatsAppWork/Core/PerformanceSignposts.swift`
- Create: `apps/macos/WhatsAppWorkTests/PerformanceSignpostsTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift`
- Modify: `apps/macos/WhatsAppWork/Views/ChatListView.swift`
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift`
- Modify: `docs/performance.md`

**Interfaces:**
- Consumes: AppState launch, preview/loadOlder, event apply, optimistic send, sync refresh, and row appearance.
- Produces: paired OSSignposter intervals for launch, chat switch, incoming visibility, optimistic-send visibility, message-page fetch/decode, and sync refresh.

- [ ] **Step 1: Add a failing compile-time signpost smoke test**

Create `PerformanceSignpostsTests.swift`:

```swift
import XCTest
@testable import WhatsAppWork

@MainActor
final class PerformanceSignpostsTests: XCTestCase {
    func testBeginAndEndPairsAreSafeWithoutAnInstrumentsConsumer() {
        PerformanceSignposts.beginLaunch()
        PerformanceSignposts.endLaunchAtFirstChatFrame()
        PerformanceSignposts.beginChatSwitch(chatJID: "a@s.whatsapp.net")
        PerformanceSignposts.endChatSwitch(chatJID: "a@s.whatsapp.net")
        PerformanceSignposts.beginIncoming(rowID: 7)
        PerformanceSignposts.endVisibleRow(rowID: 7)
        let page = PerformanceSignposts.beginMessagePage()
        PerformanceSignposts.endMessagePage(page)
        let sync = PerformanceSignposts.beginSyncRefresh()
        PerformanceSignposts.endSyncRefresh(sync)
    }
}
```

- [ ] **Step 2: Run and confirm the facade is missing**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/PerformanceSignpostsTests
```

Expected: compile failure for `PerformanceSignposts`.

- [ ] **Step 3: Implement a bounded, main-actor signpost facade**

Create `PerformanceSignposts.swift`:

```swift
import Foundation
import os

@MainActor
enum PerformanceSignposts {
    private enum PendingRowKind { case incoming, optimistic }
    private struct PendingRow {
        let kind: PendingRowKind
        let state: OSSignpostIntervalState
    }

    private static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.whatsappwork.WhatsAppWork",
        category: "UI Performance"
    )
    private static var launch: OSSignpostIntervalState?
    private static var chatSwitches: [String: OSSignpostIntervalState] = [:]
    private static var pendingRows: [Int64: PendingRow] = [:]

    static func beginLaunch() {
        guard launch == nil else { return }
        launch = signposter.beginInterval("Launch to First Chat Frame")
    }

    static func endLaunchAtFirstChatFrame() {
        guard let state = launch else { return }
        signposter.endInterval("Launch to First Chat Frame", state)
        launch = nil
    }

    static func beginChatSwitch(chatJID: String) {
        guard chatSwitches[chatJID] == nil else { return }
        chatSwitches[chatJID] = signposter.beginInterval("Chat Switch")
    }

    static func endChatSwitch(chatJID: String) {
        guard let state = chatSwitches.removeValue(forKey: chatJID) else { return }
        signposter.endInterval("Chat Switch", state)
    }

    static func beginIncoming(rowID: Int64) {
        guard pendingRows.count < 256 else { return }
        pendingRows[rowID] = PendingRow(
            kind: .incoming,
            state: signposter.beginInterval("Incoming to Visible")
        )
    }

    static func beginOptimistic(rowID: Int64) {
        guard pendingRows.count < 256 else { return }
        pendingRows[rowID] = PendingRow(
            kind: .optimistic,
            state: signposter.beginInterval("Send to Optimistic Visible")
        )
    }

    static func endVisibleRow(rowID: Int64) {
        guard let pending = pendingRows.removeValue(forKey: rowID) else { return }
        switch pending.kind {
        case .incoming:
            signposter.endInterval("Incoming to Visible", pending.state)
        case .optimistic:
            signposter.endInterval("Send to Optimistic Visible", pending.state)
        }
    }

    static func beginMessagePage() -> OSSignpostIntervalState {
        signposter.beginInterval("Message Page Fetch Decode")
    }
    static func endMessagePage(_ state: OSSignpostIntervalState) {
        signposter.endInterval("Message Page Fetch Decode", state)
    }
    static func beginSyncRefresh() -> OSSignpostIntervalState {
        signposter.beginInterval("Sync Refresh")
    }
    static func endSyncRefresh(_ state: OSSignpostIntervalState) {
        signposter.endInterval("Sync Refresh", state)
    }

    static func clearPending() {
        chatSwitches.removeAll()
        pendingRows.removeAll()
    }
}
```

- [ ] **Step 4: Place signposts at user-visible boundaries**

- Call `beginLaunch()` in `AppState.init`; end on the next main run-loop after `ChatListView` observes `chatsLoaded` and renders rows or its honest empty state.
- Begin chat switch at `previewChat`; end from `MessageList.onAppear` or its first page-count change for the same `chatJID`.
- Begin incoming immediately before `upsert` in `.messageReceived` only when
  `message.chat_jid == selectedChat`; begin optimistic immediately before
  inserting the negative-id row; end both from `MessageBubble.onAppear` by
  row id.
- Pair `beginMessagePage/endMessagePage` around each `api.messages` await through merge.
- Pair `beginSyncRefresh/endSyncRefresh` around the actual coalesced sync refresh.
- Call `clearPending()` on logout.

`endVisibleRow` is an O(1) dictionary miss for ordinary rows. Do not instrument
each receipt/reaction and do not attach a geometry reader to any row.

- [ ] **Step 5: Run tests and a Release build before collecting baseline**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: tests pass and Release ends with `BUILD SUCCEEDED`.

- [ ] **Step 6: Capture the pre-UX baseline with a logged-in account**

On the 2018-class Intel target, use Instruments App Launch, Time Profiler, and
Core Animation. Collect at least 20 chat switches, 20 incoming messages, and
20 optimistic sends; report p50/p95. Type for 30 seconds in a busy 200-row
transcript, scroll a 10k-message chat, and sample idle CPU/RSS for five minutes
after sync.

Append the exact raw baseline numbers under
`Measured — 2026-09-04 pre-UX hardening` in `docs/performance.md`. This baseline
must exist before Task 1 changes appearance or spacing.

- [ ] **Step 7: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/PerformanceSignposts.swift apps/macos/WhatsAppWorkTests/PerformanceSignpostsTests.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/ChatListView.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift docs/performance.md
rtk git commit -m "perf: instrument IRC UI budgets"
```

Skip without initializing Git when there is no valid `HEAD`.

---

### Task 1: Typed appearance preferences and native Settings

**Files:**
- Create: `apps/macos/WhatsAppWork/Core/UXPolicies.swift`
- Create: `apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift`
- Create: `apps/macos/WhatsAppWork/Views/AppearanceSettingsView.swift`
- Modify: `apps/macos/WhatsAppWork/WhatsAppWorkApp.swift:14-76, 154-178`
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift:11-29, 74-96`

**Interfaces:**
- Consumes: existing `transcriptFontSize` and `transcriptDensity` UserDefaults keys.
- Produces: `AppAppearance`, `TranscriptDensity`, `AppearanceDefaults`, `AppAppearanceModifier`, and `AppearanceSettingsView`.

- [ ] **Step 1: Add failing preference-default tests**

Create `UXPoliciesTests.swift`:

```swift
import XCTest
@testable import WhatsAppWork

final class UXPoliciesTests: XCTestCase {
    func testNewInstallDefaultsAreComfortableAndDark() {
        XCTAssertEqual(AppearanceDefaults.transcriptDensity, TranscriptDensity.comfortable.rawValue)
        XCTAssertEqual(AppearanceDefaults.appAppearance, AppAppearance.dark.rawValue)
    }

    func testDensitySpacingKeepsTheSameLayoutAtThreeComfortLevels() {
        XCTAssertEqual(TranscriptDensity.compact.rowPadding, 0.5)
        XCTAssertEqual(TranscriptDensity.comfortable.rowPadding, 3)
        XCTAssertEqual(TranscriptDensity.spacious.rowPadding, 6)
    }
}
```

- [ ] **Step 2: Run and verify missing preference types fail**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/UXPoliciesTests
```

Expected: compile failure for `AppearanceDefaults`, `AppAppearance`, or `TranscriptDensity`.

- [ ] **Step 3: Implement typed values without changing stored keys**

Create `UXPolicies.swift`:

```swift
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case dark
    case darkHighContrast

    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .dark: "Dark"
        case .darkHighContrast: "Dark High Contrast"
        }
    }
}

enum TranscriptDensity: String, CaseIterable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }
    var rowPadding: CGFloat {
        switch self {
        case .compact: 0.5
        case .comfortable: 3
        case .spacious: 6
        }
    }
}

enum AppearanceDefaults {
    static let appAppearance = AppAppearance.dark.rawValue
    static let transcriptDensity = TranscriptDensity.comfortable.rawValue
    static let transcriptFontSize = 12.5
}
```

- [ ] **Step 4: Add a no-filter appearance modifier and Settings scene**

Implement:

```swift
struct AppAppearanceModifier: ViewModifier {
    let appearance: AppAppearance

    @ViewBuilder
    func body(content: Content) -> some View {
        switch appearance {
        case .system:
            content
        case .dark:
            content.environment(\.colorScheme, .dark)
        case .darkHighContrast:
            content
                .environment(\.colorScheme, .dark)
                .environment(\.colorSchemeContrast, .increased)
        }
    }
}
```

Create `AppearanceSettingsView.swift`:

```swift
import SwiftUI

struct AppearanceSettingsView: View {
    @AppStorage("appAppearance") private var appearance = AppearanceDefaults.appAppearance
    @AppStorage("transcriptDensity") private var density = AppearanceDefaults.transcriptDensity
    @AppStorage("transcriptFontSize") private var fontSize = AppearanceDefaults.transcriptFontSize

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { value in
                    Text(value.title).tag(value.rawValue)
                }
            }
            Picker("Transcript density", selection: $density) {
                Text("Compact").tag(TranscriptDensity.compact.rawValue)
                Text("Comfortable").tag(TranscriptDensity.comfortable.rawValue)
                Text("Spacious").tag(TranscriptDensity.spacious.rawValue)
            }
            HStack {
                Text("Transcript text")
                Slider(value: $fontSize, in: 11...16, step: 0.5)
                Text(fontSize.formatted(.number.precision(.fractionLength(1))))
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
            }
        }
        .formStyle(.grouped)
        .padding(16)
        .frame(width: 420)
    }
}
```

Add:

```swift
Settings {
    AppearanceSettingsView()
}
```

In `RootView`, add:

```swift
@AppStorage("appAppearance") private var appearanceRaw = AppearanceDefaults.appAppearance
private var appearance: AppAppearance { AppAppearance(rawValue: appearanceRaw) ?? .dark }
```

Replace forced `.environment(\.colorScheme, .dark)` with
`.modifier(AppAppearanceModifier(appearance: appearance))`. Replace the
hard-coded RootView and TranscriptView dark backgrounds with
`Color(nsColor: .windowBackgroundColor)` so System-light remains legible; do
not use `.contrast`, blur, or another GPU filter. In `TranscriptView`, change
only the fallback density string to `AppearanceDefaults.transcriptDensity`
and read spacing from `TranscriptDensity(rawValue:)`; stored user values
continue to win.

- [ ] **Step 5: Run tests and build both appearance paths**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: tests/builds pass. Switching System/Dark/High Contrast updates chrome without changing transcript structure, and a pre-existing Compact preference stays Compact.

- [ ] **Step 6: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/UXPolicies.swift apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift apps/macos/WhatsAppWork/Views/AppearanceSettingsView.swift apps/macos/WhatsAppWork/WhatsAppWorkApp.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift
rtk git commit -m "feat: add comfortable IRC appearance settings"
```

---

### Task 2: Adaptive member panel, compact identity menu, and correct image interpolation

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/UXPolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:480-520, 730-745, 1388-1412`
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift:5-168, 1109-1165, 1234-1340`

**Interfaces:**
- Consumes: `showMemberPanel`, `MemberPanel`, `profileRequest`, `knownChatLIDs`, and `MessageMedia.kind`.
- Produces: `MemberPanelLayoutPolicy.showsInline`, one detail-width preference, `AppState.copyIdentifier`, and a narrow member sheet.

- [ ] **Step 1: Add failing adaptive-layout tests**

Append:

```swift
func testMemberPanelRequiresGroupPreferenceAndSafeWidth() {
    XCTAssertTrue(MemberPanelLayoutPolicy.showsInline(
        detailWidth: 760, isGroup: true, prefersVisible: true
    ))
    XCTAssertFalse(MemberPanelLayoutPolicy.showsInline(
        detailWidth: 759, isGroup: true, prefersVisible: true
    ))
    XCTAssertFalse(MemberPanelLayoutPolicy.showsInline(
        detailWidth: 900, isGroup: false, prefersVisible: true
    ))
    XCTAssertFalse(MemberPanelLayoutPolicy.showsInline(
        detailWidth: 900, isGroup: true, prefersVisible: false
    ))
}
```

- [ ] **Step 2: Run and confirm the layout policy is red**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/UXPoliciesTests
```

Expected: missing `MemberPanelLayoutPolicy`.

- [ ] **Step 3: Implement the pure threshold and one outer geometry preference**

Append:

```swift
enum MemberPanelLayoutPolicy {
    static let minimumInlineDetailWidth: CGFloat = 760

    static func showsInline(detailWidth: CGFloat, isGroup: Bool,
                            prefersVisible: Bool) -> Bool {
        isGroup && prefersVisible && detailWidth >= minimumInlineDetailWidth
    }
}

struct DetailWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
```

Attach exactly one background `GeometryReader` to `TranscriptView`’s outer HStack and store the width in `@State private var detailWidth`. Do not add geometry work to message rows.

- [ ] **Step 4: Present members inline when wide and in one sheet when narrow**

Add `@State private var memberSheetPresented = false`. Compute:

```swift
private var showsInlineMembers: Bool {
    MemberPanelLayoutPolicy.showsInline(
        detailWidth: detailWidth, isGroup: isGroup, prefersVisible: showMemberPanel
    )
}
```

Render the existing 180 pt panel only when `showsInlineMembers`. The toolbar action toggles `showMemberPanel` when wide; below 760 pt it sets `memberSheetPresented = true`. Add:

```swift
.sheet(isPresented: $memberSheetPresented) {
    MemberPanel(chatJID: chatJID)
        .frame(minWidth: 320, minHeight: 420)
}
```

A `profileRequest` opens the inline panel when wide or the member sheet when narrow.

- [ ] **Step 5: Move identifiers into an Info menu with explicit copy actions**

Add:

```swift
func copyIdentifier(_ value: String, label: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    toast = "\(label) copied"
}
```

Remove persistent 9 pt JID/LID `Text` from the header. Add one borderless `Menu` labeled with `info.circle` containing “Copy JID” and, when different, “Copy LID”. Give it `.accessibilityLabel("Conversation information")` and keep IDs in the existing profile detail view.

- [ ] **Step 6: Use normal interpolation for photos and nearest only for stickers**

Change the bubble image modifier to:

```swift
.interpolation(media.kind == "sticker" ? .none : .medium)
```

Keep existing 480 px downsampling, 220×200 pt frame, 48 MiB byte cache, and click-to-load behavior unchanged.

- [ ] **Step 7: Run tests/build and resize through the threshold**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build
```

Expected: tests/build pass; panel switches at 760 pt without horizontal clipping or oscillation; narrow toolbar opens one sheet; photos are smooth and stickers remain crisp; IDs copy from the Info menu.

- [ ] **Step 8: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/UXPolicies.swift apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift
rtk git commit -m "feat: adapt IRC detail chrome"
```

---

### Task 3: Stable keyboard search and stale-data error states

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/UXPolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:1165-1175, 1290-1350, 1415-1422`
- Modify: `apps/macos/WhatsAppWork/WhatsAppWorkApp.swift:200-225`
- Modify: `apps/macos/WhatsAppWork/Views/SearchOverlay.swift`
- Modify: `apps/macos/WhatsAppWork/Views/InboxView.swift:6-105`

**Interfaces:**
- Consumes: `APIClient.search`, `APIClient.inbox`, existing 120 ms search debounce, and Inbox refresh triggers.
- Produces: `PreservingLoadState<Value>`, `LoadPhase`, `SearchSelectionPolicy.move`, stable `SearchRow.id`, and throwing `AppState.runSearch`.

- [ ] **Step 1: Add failing stale-data and selection tests**

Append:

```swift
func testFailedRefreshPreservesLastSuccessfulValue() {
    var state = PreservingLoadState<Int>()
    state.begin()
    state.succeed(42)
    state.begin()
    state.fail("offline")
    XCTAssertEqual(state.value, 42)
    XCTAssertEqual(state.phase, .failed)
    XCTAssertEqual(state.errorMessage, "offline")
}

func testSearchSelectionMovesByStableIdentity() {
    let ids = ["chat:a", "contact:b", "message:9"]
    XCTAssertEqual(SearchSelectionPolicy.move(current: nil, ids: ids, delta: 1), "chat:a")
    XCTAssertEqual(SearchSelectionPolicy.move(current: "chat:a", ids: ids, delta: 1), "contact:b")
    XCTAssertEqual(SearchSelectionPolicy.move(current: "chat:a", ids: ids, delta: -1), "chat:a")
}
```

- [ ] **Step 2: Run and verify missing load/selection types fail**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/UXPoliciesTests
```

Expected: compile failure for `PreservingLoadState` or `SearchSelectionPolicy`.

- [ ] **Step 3: Implement preserving load state and stable selection**

Append:

```swift
enum LoadPhase: Equatable { case idle, loading, loaded, failed }

struct PreservingLoadState<Value> {
    private(set) var value: Value?
    private(set) var phase: LoadPhase = .idle
    private(set) var errorMessage: String?

    mutating func begin() {
        phase = .loading
        errorMessage = nil
    }
    mutating func succeed(_ value: Value) {
        self.value = value
        phase = .loaded
        errorMessage = nil
    }
    mutating func fail(_ message: String) {
        phase = .failed
        errorMessage = message
    }
}

enum SearchSelectionPolicy {
    static func move(current: String?, ids: [String], delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        let index = current.flatMap { ids.firstIndex(of: $0) }
            ?? (delta > 0 ? -1 : ids.count)
        return ids[min(max(index + delta, 0), ids.count - 1)]
    }
}
```

- [ ] **Step 4: Make search rows identifiable and keep keyboard selection visible**

Declare `enum SearchRow: Identifiable` and give it this stable identity:

```swift
var id: String {
    switch self {
    case .chat(let chat): "chat:\(chat.jid)"
    case .contact(let contact): "contact:\(contact.jid)"
    case .hit(let hit): "message:\(hit.rowid)"
    }
}
```

Replace integer selection with `String?`. Wrap the result scroll view in `ScrollViewReader`, tag each row `.id(row.id)`, and on selection changes call `proxy.scrollTo(id, anchor: .center)`. Add:

```swift
.onKeyPress(.escape) {
    state.searchOpen = false
    return .handled
}
```

Use `@State private var loadState = PreservingLoadState<SearchResponse>()` and
replace the current optional rendering with:

```swift
@ViewBuilder
private func searchContent(proxy: ScrollViewProxy) -> some View {
    if query.trimmingCharacters(in: .whitespaces).isEmpty {
        Text("Type to search messages, chats, and contacts")
            .foregroundStyle(.secondary)
    } else if loadState.phase == .loading && loadState.value == nil {
        ProgressView("Searching…")
    } else if let results = loadState.value {
        resultsList(results, proxy: proxy)
        if loadState.phase == .failed {
            retryBanner(loadState.errorMessage ?? "Search unavailable")
        }
    } else if loadState.phase == .failed {
        retryState(loadState.errorMessage ?? "Search unavailable")
    }
}
```

`resultsList` shows “No results” when the successful value is empty. The
search task calls `loadState.begin()`, then `succeed` or `fail`; a stale
response may mutate state only when its trimmed query still equals the current
trimmed query. Change `AppState.runSearch` to `async throws -> SearchResponse`
so the view can distinguish an empty success from failure.

- [ ] **Step 5: Preserve Inbox content and add persistent Retry feedback**

In AppState, add `@Published private(set) var inboxLoading = false` and `@Published private(set) var inboxError: String?`. Replace optional assignment with:

```swift
func refreshInbox() async {
    guard let api else { return }
    inboxLoading = true
    defer { inboxLoading = false }
    do {
        inbox = try await api.inbox()
        inboxError = nil
    } catch {
        inboxError = error.localizedDescription
    }
}
```

If prior Inbox data exists, keep the list and overlay this compact persistent
banner:

```swift
if let error = state.inboxError {
    HStack {
        Label(error, systemImage: "exclamationmark.triangle")
            .lineLimit(2)
        Spacer()
        Button("Retry") { Task { await state.refreshInbox() } }
    }
    .font(.callout)
    .padding(8)
    .background(.regularMaterial)
}
```

If no data exists, show the same message and Retry centered rather than a
spinner. Show `ProgressView` only while `inboxLoading && inbox == nil`. Keep
the existing 60-second snooze-expiry refresh only while the Inbox tab is
visible.

Add an explicit retry for the persistent offline banner:

```swift
func retryConnection() {
    if api == nil {
        if case .running = sidecar.phase { connectIfNeeded() }
        else { sidecar.start() }
    } else {
        wsReconnectAttempts = 0
        scheduleWSReconnect()
    }
}
```

Render “Retry Now” beside “Reconnecting…” in `ConnectionBanner`; QR linking
keeps its informational banner because scanning, not retrying, is the required
action.

- [ ] **Step 6: Run tests and state-transition checks**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: tests/build pass. Up/Down always scrolls selected search result into view; Enter opens it; Escape closes; a simulated offline refresh keeps old Search/Inbox rows and shows Retry; a successful retry clears the persistent error.

- [ ] **Step 7: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/UXPolicies.swift apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/WhatsAppWorkApp.swift apps/macos/WhatsAppWork/Views/SearchOverlay.swift apps/macos/WhatsAppWork/Views/InboxView.swift
rtk git commit -m "feat: preserve search and inbox context"
```

---

### Task 4: Honest unread-window marker and explicit accessibility descriptions

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/UXPolicies.swift`
- Modify: `apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift`
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift:27-37, 743-830`
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift:171-480, 550-720, 877-1108, 1234-1543`
- Modify: `apps/macos/WhatsAppWork/Views/ChatListView.swift:25-255`
- Modify: `apps/macos/WhatsAppWork/Views/InboxView.swift:110-257`

**Interfaces:**
- Consumes: optional-row `UnreadBoundary` and `UnreadBoundaryPolicy` from the interaction plan.
- Produces: `UnreadWindowMarker`, `MessageAccessibilitySummary.make`, coherent row descriptions, and labels/hints for icon-only controls.

- [ ] **Step 1: Add a failing message-summary test**

Append:

```swift
func testMessageAccessibilitySummaryIncludesStateWithoutDependingOnColor() {
    let value = MessageAccessibilitySummary.make(
        time: "10:42", author: "Rafi", body: "deploy done",
        isMention: true, isStarred: true, isDone: false,
        receiptStatus: "failed"
    )
    XCTAssertEqual(value,
                   "10:42, Rafi, mention, starred, failed to send, deploy done")
}
```

- [ ] **Step 2: Run and confirm the summary type is missing**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test -only-testing:WhatsAppWorkTests/UXPoliciesTests
```

Expected: compile failure for `MessageAccessibilitySummary`.

- [ ] **Step 3: Implement a deterministic non-color summary**

Append:

```swift
enum MessageAccessibilitySummary {
    static func make(time: String, author: String, body: String,
                     isMention: Bool, isStarred: Bool, isDone: Bool,
                     receiptStatus: String?) -> String {
        var parts = [time, author]
        if isMention { parts.append("mention") }
        if isStarred { parts.append("starred") }
        if isDone { parts.append("done") }
        switch receiptStatus {
        case "failed": parts.append("failed to send")
        case "pending": parts.append("sending")
        case "read": parts.append("read")
        case "delivered": parts.append("delivered")
        default: break
        }
        if !body.isEmpty { parts.append(body) }
        return parts.joined(separator: ", ")
    }
}
```

- [ ] **Step 4: Render a bounded top marker until the true unread row is loaded**

In `MessageList`, before message rows, render the marker when `unreadBoundary?.rowID == nil`:

```swift
if let boundary = unreadBoundary, boundary.rowID == nil {
    UnreadWindowMarker(count: boundary.count, visibleCount: messages.count) {
        Task { await loadOlderAnchored(proxy) }
    }
}
```

Implement:

```swift
struct UnreadWindowMarker: View {
    let count: Int
    let visibleCount: Int
    let loadEarlier: () -> Void

    var body: some View {
        Button(action: loadEarlier) {
            Label("\(count) unread · showing latest \(visibleCount) · Load Earlier",
                  systemImage: "arrow.up.to.line")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityHint("Loads one earlier page without loading all history")
    }
}
```

After every successful older-page merge, recompute the boundary from its
preserved `count`:

```swift
if let count = unreadBoundaries[chat]?.count {
    unreadBoundaries[chat] = UnreadBoundaryPolicy.resolve(
        unreadCount: count, messages: messagesByChat[chat] ?? []
    )
}
```

Once enough incoming rows exist, `rowID` becomes concrete and the existing
inline `UnreadDivider` renders. Never loop pages automatically.

- [ ] **Step 5: Add explicit accessibility labels and readable metadata floors**

Apply these exact labels/hints:

```swift
// Focus button
.accessibilityLabel(state.focusMode ? "Disable Focus Mode" : "Enable Focus Mode")
.accessibilityHint("Focus Mode allows notifications only from work chats")

// Member button
.accessibilityLabel(showsInlineMembers ? "Hide group members" : "Show group members")

// Attachment and send
.accessibilityLabel("Attach file")
.accessibilityLabel("Send message")

// Dismiss reply/attachment/profile
.accessibilityLabel("Cancel reply")
.accessibilityLabel("Remove attachment")
.accessibilityLabel("Back to group members")

// Jump latest
.accessibilityLabel("Jump to latest message")
```

Add accessible values to unread/mention counts and chat rows. Raise persistent
9 pt metadata to at least 10 pt. In `MessageBubble`, compute:

```swift
private var accessibilitySummary: String {
    let body = state.resolveBareMentionTokens(
        in: message.text?.isEmpty == false
            ? message.text!
            : (message.media?.kind.capitalized ?? "")
    )
    return MessageAccessibilitySummary.make(
        time: IRCLineText.timeString(message.timestamp),
        author: state.ircNick(for: message),
        body: body,
        isMention: message.has_mention && !message.from_me,
        isStarred: message.starred == true,
        isDone: message.done == true,
        receiptStatus: message.receipt_status
    )
}
```

Apply `.accessibilityLabel(accessibilitySummary)` to the existing selectable
`IRCLineText`, and hide the duplicate time/nick labels from VoiceOver. Nested
media/action controls remain separate accessibility elements. Keep
`IRCLineText` as SwiftUI `Text`; do not replace it with an AppKit view.

In `ChatRow`, read `@Environment(\.colorSchemeContrast)` and use opacity 0.72
instead of 0.45 for non-work rows when contrast is `.increased`; normal Dark
keeps the existing 0.45 value. Hierarchical `.secondary`/`.tertiary` styles
then receive the standard increased-contrast environment without a render
filter.

- [ ] **Step 6: Audit non-color state cues**

Verify and retain these textual/glyph cues: Focus Mode moon state plus accessible value; unread number; `@N` mention; `✗ failed`; `✓ done`; star glyph; receipt glyph. Add missing `.accessibilityLabel` text but do not remove existing visible cues.

- [ ] **Step 7: Run tests/build and VoiceOver checks**

Working directory: `apps/macos`.

```bash
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: tests/build pass. With VoiceOver, Chat list, transcript actions, composer, member panel, and Inbox controls have unique meaningful names; a message announces time/author/state/body coherently; selectable text still copies with Command-C.

- [ ] **Step 8: Commit when HEAD exists**

```bash
rtk git add apps/macos/WhatsAppWork/Core/UXPolicies.swift apps/macos/WhatsAppWorkTests/UXPoliciesTests.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift apps/macos/WhatsAppWork/Views/ChatListView.swift apps/macos/WhatsAppWork/Views/InboxView.swift
rtk git commit -m "feat: improve IRC accessibility and unread context"
```

---

### Task 5: Re-measure every UI budget and gate rollout

**Files:**
- Modify: `docs/performance.md`

**Interfaces:**
- Consumes: Task 0’s signposts/baseline and the completed UX Tasks 1-4.
- Produces: after measurements, before/after comparison, and final pass/fail rollout decision.

- [ ] **Step 1: Run the complete automated gate before live measurement**

Working directory: repository root, then `apps/macos` where noted.

```bash
rtk ./scripts/build-core.sh
```

Working directory: `core`.

```bash
rtk go build ./...
rtk go vet ./...
rtk go test ./...
rtk go test -race ./internal/app ./internal/whatsapp ./internal/storage ./internal/ipc ./internal/media
rtk env WW_BENCH_N=150000 go test ./internal/storage -run XXX -bench . -benchmem
```

Working directory: `apps/macos`.

```bash
rtk xcodegen generate
rtk xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test
rtk xcodebuild -scheme WhatsAppWork -configuration Release -derivedDataPath build/DerivedData-release build
```

Expected: all Go tests/race/vet, universal build, Swift tests, and Release build pass. Storage page/search/chat numbers remain within repository budgets.

- [ ] **Step 2: Repeat the exact baseline scenario on the Intel target**

Use the same account, Release build, transcript/chat sample, Instruments
templates, and sample counts used in Task 0. Collect at least 20 chat switches,
20 incoming messages, and 20 optimistic sends; report p50/p95. Type
continuously for 30 seconds in the same busy 200-row transcript, scroll the
same 10k-message chat, and sample idle CPU/RSS for five minutes after sync.

Required pass criteria:

```text
cold start → first useful frame : < 1.0 s
chat switch p95                : < 100 ms
incoming → visible p95         : < 50 ms
typing frame time              : < 16 ms
scrolling                      : no sustained dropped frames
idle CPU                       : ≤ 1% average; ≤ 5 wakeups/s sustained
idle RSS                       : app < 90 MB; combined < 150 MB
working-set RSS                : combined < 250 MB
```

- [ ] **Step 3: Record exact comparisons and block completion on regressions**

Add a dated table to `docs/performance.md`:

```markdown
| UI metric | Before | After | Budget | Verdict |
|---|---:|---:|---:|---|
| Cold start → useful chat frame | Task 0 launch median | post-change launch median | <1.0 s | compare to budget and baseline |
| Chat switch p95 | Task 0 p95 | post-change p95 | <100 ms | compare to budget and baseline |
| Incoming → visible p95 | Task 0 p95 | post-change p95 | <50 ms | compare to budget and baseline |
| Send → optimistic visible p95 | Task 0 p95 | post-change p95 | no regression | compare p95 values |
| Typing frame time | Task 0 maximum | post-change maximum | <16 ms | compare to budget and baseline |
| Idle CPU / app RSS / combined RSS | Task 0 five-minute sample | post-change five-minute sample | ≤1% / <90 MB / <150 MB | compare to budget and baseline |
```

Replace each descriptive value/verdict cell with evidence from Tasks 0 and 5.
If a UI budget regresses, stop rollout, identify the responsible task with
signposts/Time Profiler, and fix or revert that task before claiming
completion.

- [ ] **Step 4: Commit when HEAD exists**

```bash
rtk git add docs/performance.md
rtk git commit -m "docs: record IRC UX performance results"
```

Skip without initializing Git when there is no valid `HEAD`.
