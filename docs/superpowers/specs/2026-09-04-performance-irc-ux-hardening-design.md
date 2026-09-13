# Performance and IRC UX Hardening — Design

Date: 2026-09-04 · Status: approved for implementation in the original task; resumed 2026-09-05

## Goal

Keep WhatsApp Work recognizably IRC-like while making its everyday workflow
safe, accessible, responsive, and measurable. The work fixes the reported
keyboard-copy regression, removes lifecycle work that defeats idle budgets,
and closes state leaks that can surprise keyboard-first users.

## Product principles

1. Preserve the IRC content model: `time | nick | message`, monospaced text,
   `#group` / `@direct`, stable nick colors, compact channel navigation, and a
   hideable group-member list.
2. Use native macOS interaction conventions for selection, copy/paste,
   keyboard focus, menus, accessibility, sheets, and settings. IRC appearance
   must not require IRC-era interaction friction.
3. Do not trade performance for polish. Transcript rows remain SwiftUI `Text`
   inside `List`; no AppKit text view per row, eager media download, unbounded
   cache, full-history render, request-path table scan, or healthy-connection
   polling may be introduced.
4. A performance claim needs a number. UI hot paths gain signposts and are
   measured against `docs/performance.md` on the 2018-class Intel target.
5. SQLite/REST remains authoritative. WebSocket events remain hints.

## Chosen approach

Use targeted hardening within the current SwiftUI + `AppState` architecture.
Small policy types and test seams may be extracted, but this is not a state
framework migration or a visual rewrite. The alternative of splitting the
entire `AppState` into multiple stores was rejected because it expands the
regression surface without being necessary for the requested outcomes. A new
IRC shell was also rejected because the existing transcript already has the
right visual language and proven virtualization behavior.

## 1. Clipboard and responder-chain behavior

### Root cause

`WhatsAppWorkApp` replaces the complete `.pasteboard` command group but adds
back only Paste. That removes the standard Copy/Cut menu items and their key
equivalents. A SwiftUI `Text` selection can therefore copy from its context
menu but receives no normal Command-C menu action, exactly matching the
reported symptom.

### Design

- Keep the custom Paste command because Command-V must convert a clipboard
  image/file into an attachment while the composer owns focus.
- Restore standard Cut and Copy commands in the replacement group. They send
  `cut:` and `copy:` through `NSApp`'s responder chain so selectable transcript
  `Text`, text fields, search, and any future native editor retain macOS
  behavior.
- Preserve text Paste fallback through the responder chain when the clipboard
  does not contain an attachment or the composer is not focused.
- Preserve Paste and Match Style through the responder chain.
- Do not add row-level key handlers for Command-C; selection ownership stays
  with the native text system.

Acceptance matrix:

| Focus / clipboard | Command-C / Command-V result |
|---|---|
| Selected transcript text | Copies exact selected text |
| Composer text selection | Copies selected draft text |
| Composer + text clipboard | Pastes text normally |
| Composer + image or Finder file | Stages attachment and focuses caption |
| Search field + text clipboard | Pastes text normally |

## 2. Chat-scoped composition state

Reply targets become chat-scoped, matching the existing per-chat draft and
mention stores. Switching chats preserves each chat's draft/reply context, but
the composer can only render and send the reply target whose `chat_jid` equals
its own `chatJID`.

Send APIs receive the composing chat explicitly rather than reading mutable
global selection after a task begins. Text, replies, media captions, mention
targets, optimistic rows, and reconciliation therefore stay attached to the
chat that created the send action even if the user changes selection while the
request is in flight. Logout clears all composition stores.

## 3. Keyboard navigation and read semantics

Selection/display and read acknowledgement are separated:

- J/K and the native arrow keys move the highlighted chat and may load its
  latest 50 messages, but do not mark it read.
- Enter on the highlighted chat commits the open and marks it read.
- A direct mouse click on a chat commits it immediately.
- Focusing the transcript or composer commits the currently displayed chat,
  idempotently.
- Search, Inbox, notification, and wa.me deep links are explicit navigation
  actions and commit the opened chat.
- The unread boundary is captured before acknowledgement and remains visible
  for the session.

For more unread messages than fit in the first page, the UI must not eagerly
load an arbitrarily large history. It renders a top-of-window marker such as
`N unread · showing latest 50` with a Load Earlier action until the true first
unread row enters the bounded transcript window. This keeps the count honest
without violating the rendering budget.

## 4. Lifecycle, idle work, and energy

### WebSocket freshness

`APIClient` reports successful application-level ping receipt through a small
heartbeat callback after sending pong. `AppState` records this as
`lastWSActivityAt` without publishing it to views. The 15-second recovery timer
does no HTTP work while the heartbeat is younger than 60 seconds and the
session is connected. A genuinely stale stream still uses REST recovery.

### Sleep prevention

Sidecar process spawn no longer creates a power assertion. The assertion starts
only when a non-terminal sync-progress event arrives, ends on `done`, process
termination, logout, or timeout, and retains the existing hard maximum of ten
minutes. Waiting for QR, ordinary connected idle, and crash backoff never hold
the Mac awake.

### Contacts and duplicate refreshes

- Remove the unconditional repeating five-minute contact timer.
- Keep the initial load, bounded 45/180-second post-connect follow-ups, and
  debounced `contacts.updated` refreshes.
- Track and cancel follow-up tasks on logout/restart.
- Avoid calling `/chats` twice during initial connection and WebSocket
  recovery; one authoritative refresh occurs after the event stream is ready.
- Failed refreshes preserve last-known data and expose a quiet retry/error
  state instead of replacing content with `nil` and an indefinite spinner.

## 5. Main-thread and memory budgets

### Attachment reads

File metadata and bytes are read outside `@MainActor`. Size is checked from
file attributes before loading data; the existing 20 MiB send cap remains, and
the result crosses back to the main actor only to update UI/send state.

### Transcript cache

`messagesByChat` retains the open chat plus the nine most recently viewed
chats. Eviction never removes the active chat or an optimistic/pending send.
Drafts and reply state are independent and remain available after transcript
eviction. Each retained non-open transcript remains bounded to the existing
row window.

### Event invalidation

Dock-badge recomputation occurs only for events that can change unread/chat
membership. Receipt, reaction, media, contact, and sync events do not perform
an O(chat-count) badge update. Existing 120 ms message-update coalescing stays.

### Lower-priority hot paths

- Replace WebSocket payload object re-encoding with one typed envelope decode
  when measurement confirms no regression.
- Media disk eviction computes overflow once, selects enough oldest victims in
  one bounded query, and updates them as a batch outside the response-critical
  download completion path. Actual downloaded byte size remains authoritative.
- The Xcode bundle script declares inputs/outputs so unchanged builds do not
  re-sign the sidecar needlessly.

## 6. IRC appearance with comfortable native UX

The message transcript layout does not change. Improvements apply to chrome,
adaptivity, and legibility:

- New installations default transcript density to Comfortable; Compact and
  Spacious remain available. Existing saved preference is preserved.
- Add Appearance settings for System, Dark, and Dark High Contrast. Dark stays
  the branded default for existing users; System is available without losing
  IRC typography. High Contrast raises secondary-text contrast and reduces
  reliance on low-opacity state.
- Transcript text size remains adjustable. Sidebar and secondary metadata use
  a readable floor; persistent 9 pt tertiary identifiers are removed from the
  primary header.
- JID and LID move into a compact Info menu with Copy JID / Copy LID actions.
- The 180 pt group-member panel automatically collapses below a safe detail
  width. Its toolbar action remains available and presents members in a sheet
  or popover when the window is too narrow for the side panel.
- Photo previews use normal interpolation; sticker pixel-art may retain nearest
  neighbor rendering.
- Icon-only controls receive explicit accessibility labels, values, and hints.
  Message rows combine time, author, state, and body into a coherent VoiceOver
  description while preserving text selection as a separate native action.
- Focus Mode, unread, mention, failed-send, done, and starred states retain a
  text/glyph cue; color is never the only signal.

## 7. Search and feedback

- Search uses a scroll reader with stable row identities. Up/Down keeps the
  selected result visible, Enter opens it, and Escape closes the overlay.
- Search distinguishes initial, searching, no-results, stale-results-with-
  error, and offline states.
- Inbox refresh failures preserve the prior snapshot and provide retry
  feedback; they do not turn the pane back into an unexplained spinner.
- Toasts remain transient for confirmation. Persistent connection or loading
  failures use persistent banners/empty states with a retry action.

## 8. Instrumentation and tests

Add a macOS unit-test target and small testable policies rather than attempting
to instantiate the entire live `AppState` with a WhatsApp account.

Required red-green tests cover:

- responder actions restore Copy and preserve custom attachment Paste routing;
- reply targets cannot cross chat boundaries and survive returning to a chat;
- preview selection does not mark read, while Enter/click/focus does exactly
  once;
- fresh heartbeat suppresses fallback polling and stale heartbeat permits it;
- power assertion policy is inactive at spawn/QR/idle and capped during sync;
- transcript LRU never evicts active or pending-send chats;
- unread counts larger than the current page produce the bounded top marker;
- search keyboard movement requests scrolling to the selected stable ID;
- theme/density defaults and persisted overrides;
- failed Inbox/search refreshes preserve stale content.

Add `OSSignposter` intervals/events for:

- process start to first useful chat-list frame;
- chat selection to first transcript-page render;
- incoming WebSocket message to visible-row appearance;
- send action to optimistic-row appearance;
- message-page fetch and decode;
- sync-driven refreshes.

Verification remains the repository contract: Go build/vet/tests/race,
storage benchmark at 150k messages, universal sidecar build, macOS Debug and
Release builds, then Instruments App Launch/Time Profiler/Core Animation plus
idle RSS/CPU sampling on the 2018-class Intel machine. Before/after results are
recorded in `docs/performance.md`; no UI performance verdict is accepted from
code inspection alone.

## 9. Rollout order

1. Add the Swift test target and policy seams.
2. Fix Copy/Paste responder behavior and chat-scoped reply/send state.
3. Separate preview selection from read acknowledgement.
4. Fix heartbeat freshness, power assertion scope, contact refresh, and
   duplicate startup refresh.
5. Move attachment reads off-main and bound transcript retention.
6. Add search/error/accessibility/adaptive-layout improvements.
7. Add signposts and collect before/after measurements.
8. Optimize JSON/media/build hot paths only with supporting measurement.

Each stage must leave the app buildable and independently testable. No stage
may reintroduce polling, eager loading, full scans, or per-row AppKit text
views.

## Non-goals

- Replacing SwiftUI, SQLite, the Go sidecar, or the loopback HTTP/WS protocol.
- Recreating WhatsApp's bubble-based visual design.
- Adding automation, bulk sending, read-receipt automation beyond explicit
  user acknowledgement, or background media prefetch.
- Loading all history to make unread boundaries exact.
- Introducing a third-party state-management or UI framework.

