# Performance Audit — 2026-08-27

> **Round 3 addendum (same day, evening):** re-audit after the day's feature
> work (mentions, member panel, profile view, sticker rendering, chat
> filters, counter recompute). Numbers below; all budgets hold.

## Round 3 — measured on the LIVE account DB (432 MB, 534k messages, 166 chats)

| Metric | Result | Budget | Verdict |
|---|---|---|---|
| Core exec → READY (warm, real DB, incl. counter recompute) | **0.06 s** | < 200 ms | ✅ recompute adds only ~8 ms |
| RecomputeUnreadCounters (startup, real DB) | **8 ms** | — | ✅ indexed correlated subqueries, both SEARCH |
| Message page 1 (largest chat: 274,760 msgs) | **< 1 ms** | < 100 ms | ✅ keyset + covering index holds at real scale |
| Chat list + Unread/Mentions filter queries | 0.1–3 ms | — | ✅ |
| SearchChatsByName (LIKE over all chats) | < 1 ms (166 rows) | — | ✅ table bounded by account |
| Storage benches (150k fixture) | page 0.88 ms · FTS 12.9 ms* · chats 0.10 ms | — | ✅ *FTS ran while the live app was connected — CPU contention, still ≪ budget |
| Sidecar idle (connected, real account) | 0.0 % CPU · 38 MB RSS | ~0 % · < 60 MB | ✅ |
| App idle (Debug build, connected) | 0.0 % CPU · 70 MB RSS | < 90 MB (Release) | ✅ (Release will land lower; NSTextView rollback also cut RSS 85→58 MB earlier) |
| Go tests + `-race` (app/whatsapp/storage/ipc/media) | green | — | ✅ |

**Round-3 notes:**
- The ~2.5 s "app open → chats visible" felt on cold launch is macOS app
  spawn + Debug-build SwiftUI init, NOT the core (core READY is 60 ms).
  Verify again on a Release build before optimizing anything app-side.
- One-off diagnostics that DO full-scan (e.g. `COUNT(*) GROUP BY chat_jid`)
  stay out of request paths — verified none were added.
- IRCLineText is back to the original SwiftUI-Text implementation (smooth
  scrolling restored); the only retained render fixes are bold/strike
  formatting and receipt marks.

---

Full-stack audit: SwiftUI → IPC → Go → SQLite → whatsmeow → media.
Method per the brief: measure → identify → explain → fix → measure again.
No architectural rewrites; all fixes are contained, evidence-backed changes.

**Environment of record (this audit):** MacBook Pro 2018-class, Intel i5-8259U,
macOS 14 (darwin x64), Go 1.26, Xcode 16.2. All numbers below measured on this
machine unless marked "docs record" (docs/performance.md, i7-8559U).

**Verification status:** Go layer fully measured (benches, EXPLAIN QUERY PLAN,
idle sampling, IPC latency). Swift layer audited by code evidence + compiled;
runtime numbers need a logged-in session (Instruments plan in §6). No real
WhatsApp account was connected during this audit.

---

## 1. Baseline metrics (measured)

| Metric | Result | Budget | Verdict |
|---|---|---|---|
| Storage: chat page 1 (50 of 150k msgs) | 0.82 ms/op (30 runs) | < 100 ms total | ✅ |
| Storage: chat list page | 0.12 ms/op | — | ✅ |
| Storage: FTS search, ~1% selectivity (150k) | 6.8 ms/op | < 100 ms | ✅ |
| Storage: inbox query (indexed, 150k) | 1.5 ms avg | — | ✅ |
| Storage: bulk ingest | 2,290 rows/s | — | ⚠️ same class as docs record; M4 candidate |
| IPC round-trip (localhost HTTP+JSON, empty DB) | 0.35 ms/req (200 reqs, conn reuse) | — | ✅ not a bottleneck; UDS not warranted |
| Idle sidecar CPU (logged out, 20 s sample) | 0.00 % | ~0 % | ✅ |
| Idle sidecar RSS (logged out) | 21.2 MB | < 60 MB | ✅ (docs record: 16.2 MB release build) |
| Go tests | all green, incl. `-race` on changed pkgs | — | ✅ |
| Swift app | `xcodebuild` BUILD SUCCEEDED | — | ✅ |

### EXPLAIN QUERY PLAN — all hot queries use indexes

Verified on a production-schema DB (300 chats / 150k messages, real migrations):

- Inbox main query → `SCAN m USING INDEX idx_messages_inbox` (migration v9) — 1.5 ms
- Message page → `SEARCH m USING COVERING INDEX idx_messages_chat_ts`
- Chat list → `SEARCH chats USING INDEX idx_chats_last_ts`
- FTS → `SCAN messages_fts VIRTUAL TABLE INDEX` + rowid join
- Receipts → `SEARCH ... sqlite_autoindex_messages_1` (UNIQUE chat+sender+message_id)
- UnreadIncoming → `SEARCH ... idx_messages_chat_ts (chat_jid=? AND timestamp>?)`

**No `SCAN messages` anywhere. No missing indexes.** Note: docs/schema.md's DDL
listing is stale — it omits migration v9's `idx_messages_inbox` /
`idx_media_evict`. A candidate `(from_me, timestamp DESC)` index was tested and
made no difference (1.50 → 1.50 ms) — not added.

### Verified-good (no action needed)

- **Startup order** — native UI first; sidecar spawns at app init; READY before
  WhatsApp connect; cached chats load immediately after handshake (~30 ms warm,
  docs record). Nothing blocks first frame.
- **No N+1 IPC** — chat list is a single DTO call; contacts bulk-loaded; no
  per-row requests anywhere.
- **Pagination** — keyset `(timestamp, id)` cursors everywhere; no OFFSET;
  Swift caps transcript window at ~200 messages.
- **SQLite runtime** — WAL, `synchronous=NORMAL`, `busy_timeout=5000`, 1 writer
  + 4 readers, history ingest in 500-row transactions.
- **SwiftUI discipline** — `List` (NSTableView virtualization), Equatable row
  wrappers, memoized attributed strings, isolated composer, stable IDs.

---

## 2. Critical bottlenecks and fixes

Priorities: P0 = directly causes noticeable UI latency · P1 = significant
resource problem · P2 = useful · P3 = micro.

### P0-1 — sync-progress events trigger full chat+contact reload per event

- **Location:** `AppState.apply(.syncProgress)` → `refreshChats()` (was
  AppState.swift:100-102); Go emitted *two* progress events per HistorySync
  payload (whatsapp/client.go `onHistorySync`), and initial sync delivers many
  payloads — each firing `GET /chats` **plus** `GET /contacts` (limit 2000).
- **Impact:** during first sync — the heaviest window — dozens to hundreds of
  full-list refetches, each decoding a 2000-contact JSON payload on the main
  actor and replacing the whole `chats` array. This is the "app feels slow
  while syncing" pattern.
- **Root cause:** event treated as "refetch everything"; contacts reloaded
  unconditionally inside `refreshChats`; Go signaled stage "done" after every
  conversation chunk.
- **Fixes (implemented):**
  - Go: `done` now emitted only at the server's final payload (`progress >= 100`).
  - Swift: sync-driven refreshes coalesce to ≥ 1 s spacing, trailing edge (final
    state always lands); contacts reload at most every 5 min instead of every
    refresh.
- **Effect (arithmetic):** N sync payloads ⇒ N full `/chats`+`/contacts(2000)`
  round trips ⇒ ≤ 1/s, typically ~10–30 total for a full first sync.

### P0-2 — message send not optimistic: bubble waits for WhatsApp round trip

- **Location:** `AppState.send` (awaited `POST /messages` before `upsert`);
  Go `SendText` awaits the whatsmeow server ack before responding.
- **Impact:** send→bubble latency = full WA network RTT; "instant send" budget
  missed on any slow link.
- **Fix (implemented):** optimistic pending row (negative local id,
  `receipt_status "pending"`, rendered as `…`) appears immediately;
  reconciliation swaps in the durable row; WS echo of the same message dedups
  by `message_id`; failure marks the row `✗ failed` with a context-menu Retry.
  No protocol change.

### P1-3 — 15 s poll reloads /chats + /contacts(2000) even with healthy WS

- **Location:** `AppState.startPolling` → `refreshSession` → `refreshChats` →
  `loadContacts`; `lastEventAt` gated only the inbox fetch.
- **Impact:** constant background HTTP + JSON-decode churn every 15 s forever,
  defeating "WS events make the poll redundant" and the ≤ 1 % idle-CPU goal.
- **Fix (implemented):** fresh WS (< 60 s since last event) + connected ⇒ poll
  does nothing at all.

### P1-4 — media decode ran on the main actor

- **Location:** `AppState.ensureMedia` called `downsampledImage`
  synchronously; `AppState` is `@MainActor`.
- **Impact:** each tapped image blocked the main thread for the ImageIO decode
  (10–30 ms per 720 px image on this CPU) — visible stutter when loading
  several bubbles.
- **Fix (implemented):** decode in `Task.detached` (`@unchecked Sendable`
  box; `downsampledImage` is `nonisolated`); main actor only stores the result.

### P1-5 — decoded-image cache budget allowed hundreds of MB

- **Location:** `ensureMedia` decoded at 720 px; `trimMediaImages(keep: 240)`.
- **Impact:** worst case 240 × ~1.5 MB RGBA ≈ 350–500 MB — blows the < 250 MB
  working-set budget by itself.
- **Fix (implemented):** bubbles decode at 480 px (covers 2× retina for the
  220×200 pt frame); cache bounded by bytes (~48 MB), evicting oldest-media
  first; tap-to-preview decodes a fresh 900 px render off-main.

### P1-7 — Go background name-resolution pass ran every 60 s forever; full
contact directory re-upserted on every reconnect

- **Location:** `app.Run` 60 s ticker → `resolveNames` (2,000 contacts + all
  chats + sender-rewrite pass each minute); `whatsapp/client.go emitContacts`
  on every `Connected` (each sleep/wake, each network blip).
- **Impact:** steady-state core never reaches zero background DB work; contact
  re-upsert storms on flaky links; needless GC churn.
- **Fix (implemented):** `namesPending` atomic flag — ticker skips the pass
  when no new name material arrived (contacts/chat upserts/sync-done set it);
  `emitContacts` throttled to once per 10 min (push-name/contact events keep
  names fresh between).

### P2-8 — media.updated refetched a 50-message page to patch one row

- **Location:** `AppState.refreshOpenChatRow` (deleted).
- **Fix (implemented):** the event already carries full media meta — Swift now
  decodes `chat_jid` + `media` and patches `messagesByChat` in place. Zero
  extra HTTP.

### P2-9 — rendered-line cache key omitted receipt_status (stale ✓✓)

- **Location:** `IRCLineText.attributed` cache key.
- **Fix (implemented):** key includes `receipt_status`; `failed` renders `✗`,
  `pending` renders `…`.

### P2-11 — sleep-prevention assertion held for entire sidecar lifetime

- **Location:** `SidecarManager.holdPowerAssertion` at spawn, released only on
  termination — the Mac could not idle-sleep while the app was open.
- **Fix (implemented):** assertion scoped to active sync (released on the now-
  truthful `done` event) with a 10-minute hard cap.

### P2-12 — ⌘K chat search only saw the 25 most recent chats

- **Location:** `app.Search` listed one chat page then substring-filtered.
- **Fix (implemented):** scans all chat rows (table is account-bounded),
  results capped at the search limit. Regression test added
  (`TestSearchMatchesOlderChats`).

### P3 (implemented, trivial) — dead `heartbeatLoop` in APIClient removed
(pong was already answered inline in `receiveLoop`).

---

## 3. Open items — recommended next, in order

| # | Item | Why | Sketch |
|---|---|---|---|
| 1 | **Receipt/message.updated coalescing** (P1) | Busy groups emit one WS event + one `messagesByChat` write per message; 100 receipts ⇒ 100 invalidations/s. | Coalesce `message.updated` patches in AppState for ~150 ms into one array write; or add a batched event Go-side (wire change). |
| 2 | **messagesByChat LRU across chats** (P2) | ~200 msgs/chat retained for every chat ever opened; unbounded over a long session. | Keep last ~10 chats' arrays; evict on `open`. |
| 3 | **CoreEvent double-parse** (P3) | JSONSerialization → re-encode → JSONDecoder per event. | Decode once via JSONDecoder against `data` sub-data. |
| 4 | **EvictLRU synchronous + per-iteration size query** (P3) | Runs inside `EnsureDownloaded`; O(evictions) SUM scans. | Background goroutine; batch deletes per size query. |
| 5 | **docs/schema.md stale** | Missing v9 indexes; audit tooling depended on it. | Regenerate from migrations.go. |
| 6 | **Single-message GET** (P3) | With P2-8 fixed, rarely needed; skip unless profiling asks. | — |

Explicitly **not** recommended (no evidence): Unix-domain sockets (0.35 ms/req),
leaving SQLite, leaving whatsmeow, state-management frameworks, storing
thumbnails at avatar scale (no avatars are rendered — weechat-style rows).

---

## 4. Change log (this audit)

Go (`core/internal/…`):

- `app/app.go` — `namesPending` gating for the 60 s name-resolution ticker;
  `EventContacts`/`EventChatUpsert` mark pending; `Search` scans all chats.
- `whatsapp/client.go` — terminal-only `done` sync stage; `emitContacts`
  10-min throttle; `lastContactsEmit` field.
- `app/search_test.go` — new regression test (older-chats search).

Swift (`apps/macos/WhatsAppWork/…`):

- `Core/AppState.swift` — sync-refresh coalescing; contacts 5-min throttle;
  poll no-ops on fresh WS; optimistic send/reconcile/retry; detached image
  decode; 48 MB byte-budget image cache (480 px bubbles, 900 px preview);
  in-place `media.updated` patch; sleep-prevention signal.
- `Core/APIClient.swift` — `mediaUpdated` carries chat+media; dead heartbeat
  loop removed.
- `Core/SidecarManager.swift` — `setSleepPrevention(_: Bool)` + 10-min cap.
- `Views/WhatsAppText.swift` — receipt_status in cache key; `✗`/`…` marks.
- `Views/TranscriptView.swift` — Retry-send menu; preview via `openPreview`.

Verification: `go test ./...` green; `go test -race` green on changed packages;
`go vet` clean; `xcodebuild` BUILD SUCCEEDED.

## 5. Expected post-fix profile (to confirm on a live account)

- Idle (connected, no traffic): zero periodic HTTP from Swift, zero ticker DB
  work from Go ⇒ ~0 % CPU both processes (matches the 0.00 % logged-out
  measurement).
- First sync: ≤ 1 chat refresh/s instead of one per conversation batch;
  progress bar no longer flickers (single terminal `done`).
- Send: bubble immediate; `…` → `✓/✓✓` as receipts land.
- Media-heavy chat: decoded-image RAM bounded ~48 MB; no main-thread decodes.
- Mac can idle-sleep with the app open outside active sync.

## 6. Live-account verification plan (next session with QR login)

1. Signposts (`os_signpost`) around: chat switch, page fetch, incoming→render,
   send→bubble, sync refresh — feeds the M2 verdict table in
   docs/performance.md.
2. Instruments: Time Profiler + Allocations during first sync (validates P0-1),
   Hangs during media-heavy scrolling (validates P1-4/P1-5).
3. `powermetrics` 5-min idle capture, both processes (validates P1-3/P1-7).
4. `go tool pprof` goroutine profile before/after 1 h + repeated reconnects
   (leak audit; dispatcher/hub reviewed clean by inspection).
