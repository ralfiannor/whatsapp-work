# Feature & Functional Audit — 2026-08-30

Scope: every user-facing feature in the repository, audited end-to-end
(UI → state → IPC → Go → SQLite → whatsmeow → realtime back to UI).
Method: full source read of `core/` (Go) and `apps/macos/WhatsAppWork` (SwiftUI),
whatsmeow pinned-version verification for identity/mention behavior, no code
changes during the audit phase.

---

## 1. Feature Inventory

### Sidebar / navigation

| Feature | Entry point | Purpose | Status summary |
|---|---|---|---|
| Chats tab | Sidebar segmented control | Browse all conversations | Working |
| Inbox tab (⌘4) | Sidebar segmented control | Work action queue | **Semantics broken — see §3.1** |
| Filter: All / Unread / Mentions (⌘1/2/3) | Segmented control, Go menu | Chat-list subsets | Working; Mentions = *unread* mentions only — semantics must be understood as read-coupled |
| Focus Mode (⌘⇧F) | Sidebar moon button, Account menu | Silence/dim non-work chats; badge counts work chats only | Working (re-rank, opacity, notification filter, badge) |
| j/k chat navigation | Chat list key press | Next/prev conversation | Working |
| ⌘J next unread | Go menu | Jump to next unread chat; falls back to Inbox | Working (uses full chat set, survives filters) |
| ⌘R refresh, ⌘K search | App menu | Refresh chats / open search | Working |

### Chat list

| Feature | Status summary |
|---|---|
| Recency ordering, keyset pagination | Working (server-side keyset + local merge rules) |
| Last-message preview, mention-token resolution to names | Working (`resolveBareMentionTokens`) |
| Unread badge + `@n` mention badge per row | Working; `@n` = **unread** mention count |
| Group/direct glyph, star/briefcase markers | Working |
| Live updates on new message / read | Working (`message.received`, `chat.updated`; filtered views drop non-matching rows) |
| Context menu: Mark Read / Star as Work Contact / Mark as Work Group | Working (flags persist, `chat.updated` echoes) |
| Empty state | **Partial** — a filter with zero results shows the perpetual "Waiting for sync…" spinner (misleading) |

### Transcript

| Feature | Status summary |
|---|---|
| Windowed history, keyset "load older", anchored scroll restore | Working |
| Date dividers, unread divider ("N unread"), jump-to-latest | Working |
| Optimistic send (pending → sent → delivered → read / failed), in-place retry | Working; retry preserves reply context, drops temp row first (no dupes) |
| Reply (R key / context menu), quote preview, quote-tap jump incl. paging to target | Working; missing-original case pages to end of history and explains |
| Reactions (E key / context menu / chip click toggle) | **Broken realtime — see §3.4** (rows never update live; reload required) |
| Incoming mention rendering (`@name` resolution, own-mention highlight, row tint) | Working |
| Mention composition: `@` autocomplete, Tab/Enter accept, nick-panel click, context-menu "Mention" | Working; sends real `mentioned_jids` |
| Done (D) / Snooze (S panel) on selected row | Backend working; **no visible state on the row** (toast only) — see §3.6 |
| Star message (context menu) | **Dead-ish UI** — sets local state but no transcript indicator and no unstar path in the transcript menu |
| Forwarded marker, edited marker, revoked marker, receipt marks | Working |
| Media bubbles: tap-to-load, downsampled preview, retry, open external, full preview | Working (images/stickers preview; audio/video/document open externally) |
| Member panel (groups): sorted nicks, admin mark, click-to-mention, profile sheet | Working |
| Typography menu (size/density), member panel toggle | Working, persisted |
| "Snooze until tomorrow" (panel + context menu) | **Misleading — +16 h from now, not tomorrow** |

### Search (⌘K)

Global FTS message search + chat/contact name search, debounced, keyboard
navigation, deep-link open with anchor scroll & flash; missing-old-message case
explains. Working. (Minor: snippet `⟪⟫`→`**` conversion can bold arbitrary
`**` already present in a message — cosmetic.)

### Inbox (⌘4)

Message-level actionable queue grouped Mentions / Work Groups / Direct, plus a
chat-level Starred section. Rows deep-link to the message. Buttons: Done,
Snooze 1 h; context menu adds Snooze-until-tomorrow and Star toggle.
**Realtime: none** — refreshes only on tab open, pull-to-refresh, after a row
action, or the 15 s fallback poll while the WS stream is stale. A message
arriving while the Inbox tab is open does not appear. Snooze expiry is not
observed by anything.

### Notifications & badges

macOS notifications for incoming messages (skips the open chat; honors Focus
Mode and the muted flag). Dock badge = total unread (work chats only under
Focus). **Notification click does not open the conversation** — no delegate
routing. `is_muted` is never settable from the UI (see dead list §5).

### Login / session

QR linked-device login with rotation, progress bar, reconnect banner, logout
with local wipe. Working.

### Backend surface (for cross-reference)

- REST: 24 routes (see docs/protocol.md). All reachable from the UI except none
  orphaned; `GET /contacts/{jid}/profile`, `/groups/{jid}/members` used by the
  member panel.
- WS events: `connection.changed`, `session.qr`, `sync.progress`,
  `message.received`, `message.updated`, `chat.updated`, `chat.removed`,
  `reaction.received`, `media.updated`, `ping`.
- SQLite: `accounts`, `contacts`, `chats`, `messages`, `reactions`, `media`,
  `group_participants`, `local_message_state`, `messages_fts`, `app_settings`.

---

## 2. Classification (selected; full detail in §3)

| Feature | Classification |
|---|---|
| Inbox | PARTIALLY_WORKING · UNCLEAR_PURPOSE · MISSING_REALTIME_UPDATE · INCONSISTENT (copy vs behavior) |
| Mentions filter | PARTIALLY_WORKING (unread-only semantics undocumented; metadata lost on two ingest paths) |
| Reactions (incoming, live render) | BROKEN (realtime path) |
| Message Star (transcript) | DEAD_UI (no indicator, no toggle-back) |
| Message Done/Snooze row feedback | MISSING_FEEDBACK |
| "Snooze until tomorrow" | INCONSISTENT (label vs behavior) |
| Chat-list empty state under filter | MISSING_FEEDBACK / P2 |
| Notification click-through | MISSING (P2) |
| Chat list, search, reply, send, media, login, focus mode, read state | WORKING |

---

## 3. Findings (priority order)

### P0-1 Inbox conflates WhatsApp read state with local work state

```
Feature:            Inbox (⌘4)
Current purpose:    "actionable work items" (README), implemented as
                    "unread incoming messages not done/snoozed"
Current impl:       storage/inbox.go Inbox(): WHERE ... AND m.timestamp > c.last_read_ts
Actual behavior:    opening a chat — here or on the phone (read_self) — silently
                    removes its items from the Inbox. Done/Snooze only matter
                    while the item is unread, i.e. the primary exits are "read",
                    which is exactly the Unread view's exit.
Expected behavior:  Inbox = local productivity state: items leave via Done or
                    Snooze only; a message can be read and still need action.
Root cause:         entry/exit rules borrowed the chats.last_read_ts gate from
                    the unread-counter design; no separate inbox lifecycle.
Affected files:     core/internal/storage/inbox.go, migrations (baseline),
                    docs/protocol.md, InboxView copy, README.
```

The zero-state copy even contradicts the implementation: *"Done and snoozed
items drop out of here"* — reading also drops them, unmentioned.

Decision (Required Deliverable: Inbox): **OPTION A — keep the Inbox as the
actionable work queue** with an explicit state model:

```
live incoming message (mention | direct | work-group traffic)
        → Inbox item
exits:  Done (local) · Snooze (local, due-time return)
never:  read state
```

- Unread = WhatsApp read state (`unread_count`), unchanged.
- Mentions filter = unread mentions (WhatsApp signal + read state), unchanged —
  this keeps one purely-WhatsApp-signal view.
- Inbox = local workflow state. "Read but still in Inbox" and "unread but not
  in Inbox (non-work group)" both become true and testable.
- Entry is restricted to `source = 'live'` so the initial history sync (whose
  read position starts at the newest synced timestamp) cannot flood the queue.
  A one-time migration marks pre-existing incoming rows done, so the queue
  starts empty and fills from upgrade time forward.
- Conversation- vs message-level: keep **message-level** (current model). It
  matches "one actionable item per request", Done/Snooze already persist per
  row, and the inbox rows deep-link to the exact message. A conversation-level
  rewrite would touch every layer for no new capability. Known trade-off: an
  unread chat can accumulate several rows; acceptable at work volumes.

> **Addendum (same day, after live testing):** the message-level trade-off
> failed in practice — a busy work group floods the queue with rows the user
> must clear one by one. The inbox was redesigned to **conversation digests**
> (one row per chat: newest pending item + count + any-mention flag) with
> bulk `POST /chats/{jid}/done` and a chat-level snooze deadline
> (`chats.snoozed_until`, migration v14) that holds messages arriving after
> the snooze was set. Message-level done/snooze remain for transcript rows;
> `done_recent` stays message-level as the audit trail. Migration v13 also
> reopened the v11 baseline's recent-unread backlog, which had silently
> swallowed genuinely pending items.

### P0-2 Re-delivered messages lose mention/reply metadata

```
Feature:    Mentions detection
Root cause: storage/messages.go insertMessageTx conflict branch (idempotent
            re-delivery) escalates text/kind but never has_mention,
            mentioned_jids, reply_to_id/reply_to_sender/quoted_text, forwarded.
            A row first stored as an empty/unsupported envelope (undecryptable
            retry, partial sync) keeps has_mention = 0 forever even when the
            re-delivery carries the full ExtendedTextMessage with ContextInfo.
Effect:     message renders text fine but never counts as a mention
            (mentioned_unread never bumps, filter + inbox miss it).
Fix:        escalate the metadata columns in the same UPDATE (never downgrade).
Tests:      re-delivery of an unsupported row with mention → has_mention = 1,
            reply fields populated; re-delivery without mention on a
            mention-flagged row must not clear the flag.
```

### P1-1 Incoming reactions never update the transcript live

`app.ingestReaction`/`app.React` emit only `reaction.received`; Swift decodes
it and deliberately ignores it (`// Reactions also arrive as message.updated` —
they do not; nothing emits `message.updated` for reactions). Result: reaction
chips appear only after switching chats/restart. Fix: emit `message.updated`
(full row incl. attached reactions) after the reaction write; keep
`reaction.received` for protocol compatibility.

### P1-2 Audio/document/sticker messages drop ContextInfo (mentions, replies)

`normalize.go` assigns `ci` only for image/video. Documents carry captions
(this app itself sends captioned documents), so a mention or reply inside a
document caption is lost (`has_mention = 0`, no quote line). Audio/sticker
carry reply context too. Fix: `pm, ci = x, x.GetContextInfo()` for those kinds.

### P1-3 Edits never update mention metadata

`SetEdited` writes text/edited_ts only. An edit that adds a mention leaves the
row un-flagged. Fix: pass mention fields through the edit path (both live and
history ingest).

### P1-4 Own-LID mention edge

Mention detection compares `ContextInfo.MentionedJID` against
`[dev.ID, dev.LID]`. whatsmeow persists `Device.LID` at pairing/connect
(verified against the pinned version), so the normal case is covered. Edge:
sessions whose stored LID is empty while traffic is LID-addressed — the
`whatsmeow_lid_map` still learns own lid→pn (whatsmeow stores it on connect),
so the adapter should fold the reverse mapping into `myJIDs` as a fallback.
(Also documents the comparison: `bare()` strips device suffix and server, so
`user@lid` never equals a phone JID's user unless the digits coincide — no
systematic false positive; the LID user-space is distinct.)

### P1-5 Inbox has no realtime updates and no snooze-return

No `inbox.changed` event exists; `SetMessageSnoozed`/`SetMessageStarred` emit
nothing (protocol.md claims all three emit `message.updated` — only Done does).
Messages arriving while the Inbox is open don't show; expired snoozes never
resurface until some unrelated refresh. Fix: emit `inbox.changed` on every
inbox-affecting mutation; Swift refreshes (debounced) when the Inbox tab is
visible and runs a 60 s visibility-scoped refresh loop to catch snooze dues.

### P1-6 "Snooze until tomorrow" is +16 h

Both call sites (transcript menu, InboxView) send `minutes: 16*60`. At 18:00
that lands at 10:00 next day; at 06:00 it lands *the same evening*. Fix: snooze
API accepts an absolute `until` timestamp; Swift computes the next 09:00 local.
("Next week" keeps a +7 d relative meaning, label unchanged.)

### P1-7 Message star/done have no visible state

`Star` writes `local_message_state.starred` — no transcript indicator, no
unstar in the transcript menu. `Done` (D) confirms with a toast only. Fix:
expose `starred`/`done` on the message wire shape (LEFT JOIN in ListMessages),
render a `★` glyph and a subtle done marker, and make the context menu a toggle.

### P1-8 Notification click does nothing

No `UNUserNotificationCenterDelegate`. Fix: route the notification's message id
→ chat and open it.

### P2 (documented, not fixed in this pass)

- `chats.is_pinned` / `is_archived` / `is_muted`: never settable anywhere; the
  Swift mute check in `notify()` is permanently false. Dead columns (keep
  `is_muted` for the future mute feature; wire it or drop the others).
- `local_message_state.priority`, `app_settings` table: unused (§5).
- Chat-list empty state under a filter shows the "Waiting for sync…" spinner
  forever — should distinguish "no matches".
- Selection-driven read: j/k through the chat list opens (and marks read) every
  chat skimmed. Defensible (chat is displayed) but worth a dwell-time option
  later.
- Unread counters include system messages; the Inbox excludes them (a group
  join stub can show an unread badge with no actionable row). WhatsApp itself
  counts these; acceptable, documented.
- Notifications are posted even when the app is frontmost (different chat);
  a `willPresent` policy could suppress.
- Search snippet `⟪⟫`→markdown conversion can mis-bold text containing `**`.
- Inbox query scans `limit*4` newest qualifying rows then fills sections —
  heavily skewed group traffic can under-fill sections before the cap.
- History-sync read position = newest synced timestamp: any mention that
  arrives via a history payload rather than live delivery is born read and
  never appears in the Mentions filter. Design choice (schema.md); revisit only
  if whatsmeow exposes true per-conversation read positions.

---

## 4. Product Semantics Matrix (after P0/P1 fixes)

| Feature | Source of truth | Entry rule | Exit rule | Persists | Realtime |
|---|---|---|---|---|---|
| All Chats | WhatsApp (sync+live) | any conversation | — | Yes | Yes |
| Unread | read position (`last_read_ts`) | live msg newer than read pos | mark read (any device) | Yes | Yes |
| Mentions (filter) | WhatsApp mention metadata + read state | unread msg that mentions me | read / revoke | Yes | Yes |
| Inbox | local workflow | live incoming: mention, direct, or work-group msg | Done / Snooze(-due return) | Yes | Yes (`inbox.changed` + visibility refresh) |
| Starred chat (work contact) | local | user stars chat | user unstars | Yes | Yes (`chat.updated`) |
| Work Group | local | user marks group | user unmarks | Yes | Yes (`chat.updated`) |
| Focus Mode | local setting | user toggles | user toggles | Yes (AppStorage) | re-rank immediate |
| Message star/done | local per message | user action | user action (toggle / un-done) | Yes | Yes (`message.updated`) |
| Snooze | local per message | user snoozes until T | due time → returns; user re-snoozes/dones | Yes | ≤60 s latency while Inbox visible |

Mention badge semantics (explicit): the chat-row `@n` and the Mentions filter
count **unread mentions** (`mentioned_unread`), consistent with the Unread
filter's read-coupling. The Inbox "Mentions" section counts **mentions not yet
Done** — the two are intentionally different views of the same WhatsApp signal.

### Filter truth table (regression fixture)

| Chat state | All | Unread | Mentions | Inbox section |
|---|---|---|---|---|
| A unread direct message (live) | Yes | Yes | No | Direct |
| B read explicit mention (live, not done) | Yes | No | No | Mentions |
| C unread group msg, no mention, not work group | Yes | Yes | No | — |
| D starred contact, read message (not done) | Yes | No | No | Direct (Starred *chat* section additionally needs unread) |
| E snoozed item (not yet due) | Yes | per read state | per read state | — (returns at due) |
| F done item | Yes | per read state | per read state | — |
| G normal read conversation (not done) | Yes | No | No | Direct — read ≠ handled; Done is the exit |
| H unread group mention (live) | Yes | Yes | Yes | Mentions |
| I unread work-group msg without mention (live) | Yes | Yes | No | Work Groups |
| J history-synced mention (initial sync) | Yes | No | No | — (born read / not live) |

Encoded as `TestInboxTruthTable` + filter assertions in `core/internal/storage`.

---

## 5. Dead / redundant features

| Item | Evidence | Recommendation |
|---|---|---|
| `chats.is_pinned`, `chats.is_archived` | no setter endpoint, no UI, only scanned | drop at next schema cleanup (or wire pinning) |
| `chats.is_muted` | no setter; `notify()` checks it (always false) | keep column, add mute UI later (P2) |
| `local_message_state.priority` | written 0, never read | drop at next schema cleanup |
| `app_settings` table | created + wiped only | drop or start using (settings sync) |
| `reaction.received` event (Swift side) | decoded then ignored | now backed by `message.updated`; keep wire event, remove the dead Swift case when convenient |
| `CircleAvatar` in `ChatListView.swift` | unused by chat rows (used by Inbox) | move to shared file at next touch |

No unused REST endpoints or unreachable backend capabilities were found — every
route has a UI caller.

---

## 6. Implementation plan (executed after this report)

1. Broken core semantics: Inbox state model (P0-1) + truth-table tests.
2. Data/source-of-truth: re-delivery metadata escalation (P0-2); edit mention
   update (P1-3); own-LID fallback (P1-4).
3. Filters and queries: unchanged (Mentions filter stays read-coupled by design).
4. Realtime: reaction `message.updated` (P1-1), `inbox.changed` (P1-5), Inbox
   visibility refresh + snooze due.
5. Persistence: baseline migration for the Inbox switch; snooze `until` API (P1-6).
6. UX clarity: star/done row indicators + toggles (P1-7), notification
   click-through (P1-8), InboxView copy.
7. Edge cases: covered by new tests (fixtures §4).
8. Cleanup: documented in §5; deferred to a schema-cleanup change.

Docs updated alongside: protocol.md (inbox semantics, `inbox.changed`, snooze
`until`, message `starred`/`done`), README feature blurb.
