# Messaging Improvements — Design

Date: 2026-09-19
Status: approved (design), pending implementation plan

Four user-facing improvements:

1. Save button in the image preview sheet.
2. Colored mentions in the composer (resolved = accent blue, unresolved = default text).
3. Unread badge clears when a chat is opened (bug fix) plus a privacy setting that
   suppresses read receipts for direct messages.
4. Delete message (revoke "for everyone", own messages only).

## Goals

- Opening a chat clears its unread badge immediately, regardless of entry path.
- The user can tell at a glance, before sending, which mentions resolved.
- Image previews can be saved to disk with a standard save dialog.
- Own messages can be revoked ("delete for everyone") and render as «deleted»
  consistently with incoming revocations.
- DM read-receipt suppression is a user setting, effective immediately, scoped to
  direct messages only.

## Non-goals

- "Delete for me" (local-only deletion). The pinned whatsmeow version exposes no
  client API for it; a local tombstone would resurface on full re-sync. Revisit
  if whatsmeow gains support.
- Admins deleting other participants' messages.
- Zoom, pan, or multi-image browsing in the preview sheet.
- Changing read-receipt behavior for group chats.
- Blocking send while unresolved mentions exist (visual signal only).

## 1. Save button in image preview

`ImagePreviewSheet` (apps/macos/WhatsAppWork/Views/TranscriptView.swift:1664)
currently offers only Close. Add a **Save** button (footer, alongside Close,
`square.and.arrow.down` system image).

- Action `AppState.savePreviewImage()`:
  1. Reuse the preview's message (`state.previewImage.message`).
  2. Fetch original bytes via `APIClient.mediaData(rowID:)`
     (`GET /media/{rowid}/file`); the preview flow has already driven the
     download, the fetch is the source of truth.
  3. `NSSavePanel` defaulting to `~/Downloads`, filename from
     `media.filename`, extension derived from MIME when absent.
  4. Write bytes, reveal in Finder.
- Extract the save-to-disk logic shared with `MediaBubble.openExternally()`
  (TranscriptView.swift:1299) into one helper instead of duplicating the
  panel/write/reveal code.

## 2. Colored mentions in the composer

The composer is a SwiftUI `TextField(axis: .vertical)`
(TranscriptView.swift:819) which cannot render per-token color. Replace it with
`MentionTextView`, a new `NSViewRepresentable` wrapping a single `NSTextView`.

- This is one composer view, not an AppKit text view per transcript row; the
  AGENTS.md prohibition targets per-row views (Intel scroll regression). No
  transcript row rendering changes.
- Coloring:
  - Token matching reuses the exact same matcher as the send path
    (`containsMentionToken`, AppState.swift:1911), extracted into a shared
    helper so what the user sees and what `deliver` filters can never diverge.
  - `@Label` tokens backed by a live `mentionTargets` entry for the open chat
    render in accent blue; any other `@token` renders in the default text
    color (per product decision: failures stay plain, not red).
  - Recolor only sets attributes on computed ranges during text-change
    notifications; selection and scroll position are preserved.
- Behaviors preserved exactly:
  - Enter sends (paperplane button and keyboard submit unchanged).
  - Auto-growing height, capped at ~5 lines, scrolling beyond.
  - Focus control via the existing `composerFocusRequest` counter
    (the SwiftUI `@FocusState` equivalent is bridged through the
    representable).
  - Image paste (⌘V) continues to route through the app-level dispatcher; if
    the NSTextView responder intercepts paste, override `paste(_:)` to forward
    image data to `AppState.handlePaste` and fall through for text.
- Draft/mention data structures are unchanged: `draftStore`,
  `mentionTargets`, per-chat persistence on switch, clear-after-send.

## 3. Unread badge on open + DM read-receipt suppression

### 3a. Bug fix — badge clears when the chat opens

Root cause: `onChange(of: state.selectedChat)` (ChatListView.swift:106) only
calls `loadSelectedChat`; it never commits read. Clicks whose row tap gesture
races the List binding leave the badge until the composer gains focus
(`composerFocus`, TranscriptView.swift:677).

- The `onChange` handler now calls `loadSelectedChat` **and** `commitRead`.
- j/k preview navigation stays non-acknowledging: `moveSelection`
  (ChatListView.swift:159) sets a transient `selectionBrowsing` flag on
  AppState immediately before writing `selectedChat`; the `onChange` handler
  consumes the flag and skips `commitRead`. ⌘J `jumpNextUnread` keeps preview
  semantics.
- All other commit sources (row click, Enter, "Mark Read" menu, deep links)
  are unchanged; the existing in-flight per-chat dedup prevents double sends.

### 3b. Privacy setting — suppress DM read receipts

- New preference `suppressDMReadReceipts` (`@AppStorage`, default **on**),
  exposed in a minimal macOS `Settings` scene (⌘,): one checkbox,
  "Don't send read receipts in direct messages".
- Client computes `sendReceipt = isGroupChat || !suppressDMReadReceipts`
  (group = JID server part `g.whatsapp.net`) and passes it per request.
- API: `POST /chats/{jid}/read?send_receipt=true|false`, default `true`
  (backward compatible). The sidecar stays stateless; it stores no config.
- Go `App.MarkChatRead(ctx, chatJID, sendReceipt)`:
  - `true` — current behavior: collect unread incoming IDs grouped by sender,
    call `wa.MarkRead` per sender, advance `last_read_ts` and zero counters
    only on success (retry semantics preserved).
  - `false` — local only: take the max timestamp of unread incoming messages,
    `store.MarkChatRead` (zero counters, advance position), emit
    `chat.updated`. whatsmeow is not touched.
- Read-self receipts from other own devices still advance the position
  (receive path, unchanged).
- `docs/protocol.md` documents the query parameter.

## 4. Delete message (revoke for everyone, own messages)

The receive side already exists end-to-end: `revoked` flag, `SetRevoked`
storage repair (counters, last preview), `message.updated` fan-out, «deleted»
rendering (WhatsAppText.swift:273). This feature adds the send side.

### Go sidecar

- `core/ports.go`: add `RevokeMessage(ctx, chatJID, messageID string) error`
  to `WAClient`.
- `internal/whatsapp`: implement with `cli.BuildRevoke(chat, sender, id)` +
  `SendMessage`, sender empty for own messages (same pattern as the existing
  `React` wrapper; verified against the pinned whatsmeow
  `v0.0.0-20260909164729-b25a56d63729`).
- `App.DeleteMessage(ctx, rowID)`:
  1. Load message — `storage.ErrNotFound` → 404.
  2. Reject non-own messages (400). Already-revoked rows return 204 as a
     no-op without calling whatsmeow.
  3. `wa.RevokeMessage(ctx, chatJID, messageID)` — failure propagates, row
     untouched.
  4. Success: `store.SetRevoked` locally + `emitMessageUpdated`. The
     server's protocol echo later lands in the existing
     `IncomingRevoke` → `SetRevoked` path, which is guarded by `revoked=0`,
     so counters are never decremented twice.
- Route `POST /messages/{id}/delete` → 204 on success, 404 unknown row,
  400 non-own message; documented in `docs/protocol.md`.

### Swift

- `APIClient.deleteMessage(rowID:)` + `AppRuntimeClient` passthrough.
- Context-menu item **Delete** on `MessageBubble`, gated on
  `from_me && !revoked`, with a confirmation alert.
- After 204: apply optimistic local row update (`revoked = true`,
  text cleared) so the bubble becomes «deleted» immediately; the
  `message.updated` WS event re-asserts server truth (same reconciliation
  philosophy as optimistic sends).

## Testing

- Go: extend both fakes (`internal/app/app_test.go`,
  `internal/ipc/server_test.go`) with `RevokeMessage`. Cases:
  - Delete: happy path (wa called once, row revoked, event emitted),
    non-own rejected, unknown row 404, wa failure leaves row intact,
    already-revoked idempotent.
  - MarkChatRead local-only: no wa call, counters zeroed, position advanced,
    `chat.updated` emitted; receipt path unchanged (regression cover).
- Swift: build via xcodebuild; manual verification checklist for composer
  behaviors (focus, Enter, paste, height) since no UI test harness exists.
- `go test ./...` + `go vet` + race green; `docs/protocol.md` updated in the
  same change.

## Performance

No request-path query changes. Delete and read are rare actions; the composer
is a single view; transcript row rendering is untouched. No new benchmarks
required (per docs/performance.md budgets, nothing hot is modified).

## Compatibility

- `send_receipt` defaults to true; older callers observe no change.
- The new route is additive on the existing authenticated mux.
- `Message.revoked` wire field already exists; no schema migration needed
  for any feature in this batch.
