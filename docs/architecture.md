# WhatsApp Work — Architecture

Status: v0.1 design, Milestone 0 implemented (Go core foundation).
Scope: native macOS "WhatsApp as a Work Inbox" client. SwiftUI front end + Go sidecar (whatsmeow) + SQLite/FTS5.

---

## 1. Critical review of the proposed architecture

The brief is sound overall: sidecar Go core, native SwiftUI shell, localhost IPC, SQLite with keyset
pagination, FTS5 search, media-on-demand, focus features as local state. The review below lists the
risks that will actually decide whether this product works, ordered by severity, with mitigations
wired into this design. Items marked **[D]** have a matching decision in §4.

### 1.1 Risks

| # | Risk | Severity | Notes / Mitigation |
|---|------|----------|--------------------|
| R1 | **Account ban.** whatsmeow is an unofficial client; WhatsApp ToS forbids it. Meta has banned numbers using unofficial clients; risk is real and cannot be engineered away. | Existential | Linked-device (QR) login only — never primary-device registration. No automation, no bulk send, no bots. Conservative send rates. Mature library (whatsmeow, used by mautrix-whatsapp). Ship an explicit warning in-app and in README. |
| R2 | **Protocol drift.** WhatsApp changes protocol without notice (e.g. the July 2025 media-URL HMAC change broke third-party clients until whatsmeow caught up). Expect periodic breakage. | High | whatsmeow fully isolated in `internal/whatsapp` (see §4). Pin versions. Domain layer never imports whatsmeow. Regression smoke-test script against a real account. |
| R3 | **History sync scale.** A mature account syncs 10⁵–10⁶ messages on first login. Naive per-message writes take minutes and peg CPU/disk. | High | Bulk ingest path: one transaction per ~500-message chunk, prepared statements, no per-message events during history (only `sync.progress`). FTS populated by triggers inside the same tx. UI paginates; never loads full history. |
| R4 | **Media URL expiry.** WhatsApp media URLs (esp. post-2025 ephemeral CDN tokens) expire. "Download on demand" of old media can fail outright. | High | Persist full re-download material at receive time: URL, direct path, media key, SHA-256 hashes **and the serialized media message protobuf** (`media.proto`). Rehydrate the proto to re-download; refresh URL when supported. Graceful `unavailable` state in UI. Thumbnails are also lazy; nothing is fetched eagerly. |
| R5 | **IPC exposure.** Localhost HTTP is reachable by every process of the local user; on shared accounts, by other sessions. | Medium | Bind `127.0.0.1` only, random port, 32-byte bearer token passed to Swift via stdout `READY` handshake (never on disk, never in argv). Constant-time token compare. `Host` header allow-list (`127.0.0.1:port`). No CORS. WS uses same token. |
| R6 | **Two-process memory budget.** Go runtime + SQLite + Swift/SwiftUI in separate processes; <150 MB combined idle is tight on Intel. | Medium | `GOMEMLIMIT` (64 MiB), SQLite `cache_size` capped (~16 MB), no decoded images retained, no polling (event-driven only). Budget tracked as two per-process numbers + combined (docs/performance.md). Measured, not assumed. |
| R7 | **SwiftUI list virtualization.** `LazyVStack` in a `ScrollView` is not O(visible) for long lists; chat transcripts and chat lists can stutter on Intel. | Medium | Chat list = `List` (NSTableView-backed virtualization). Transcript = windowed pagination (50/page) + `List`/TextKit-backed rows; never render thousands. Composer state isolated from transcript state. Signposts around render paths. |
| R8 | **State-sync semantics.** Unread counts, read receipts and send states span devices; the server does not push "unread count". Deriving it wrong makes the inbox lie. | Medium | Unread = local derivation: `messages.ts > chats.last_read_ts AND NOT from_me`, maintained transactionally as denormalized counters (updated only by live messages, never by history backfill). Read receipts sent explicitly (user action), privacy-first default. Outgoing receipts tracked per message (`pending → sent → delivered → read / failed`). |
| R9 | **SQLite concurrency.** Single-writer database; UI reads + bulk sync + whatsmeow session store writes can contend. | Medium | Two handles to the same file: 1 write connection + small read pool, WAL mode, `busy_timeout` 5 s, `synchronous=NORMAL`. whatsmeow session store in a **separate file** (`session.db`) so credential data is isolatable and never lock-coupled to app data. **[D]** |
| R10 | **Sidecar lifecycle.** Core crash loops, sleep/wake, stale instances after force-quit. | Medium | Swift owns lifecycle with defined contract (§6): stdout readiness handshake, restart with capped backoff, `flock` single-instance guard, clean SIGTERM shutdown. |
| R11 | **Unknown message types.** Polls, edits, view-once, newsletters, future protocol additions must not crash ingest or render. | Medium | Normalizer has an explicit `unsupported` kind + `raw_kind` label; UI renders a placeholder row. Revocations/edits handled as first-class paths. Everything else degrades gracefully. |
| R12 | **Plaintext data at rest.** Local DB contains full synced conversation history in cleartext. | Medium | DB dir `0700`, files `0600`, inside app-support. Session credentials = whatsmeow session file (sensitive; candidate for Keychain/encrypted store later). Full at-rest encryption is a v0.2 security work item (SQLCipher or app-level encryption), documented, not silently deferred. |
| R13 | **No server-side search / contact directory.** Contact names come from history sync + push names; search must be local. | Low | By design: FTS5 locally; contact index built incrementally; document that contact list is complete only after initial history sync. |
| R14 | **Distribution.** Unofficial client ⇒ no Mac App Store; Gatekeeper/notarization for external distribution. | Low | Developer-ID signing + notarization later; ad-hoc for development. Not a v0.1 blocker. |

### 1.2 whatsmeow facts that shape the design

Verified against the whatsmeow source in the module cache (see `core/go.mod` for the pinned version):

- Login is QR (linked device) or pair-code; linked-device QR is the safe default. Consumes one of the
  4 linked-device slots; primary phone can unlink us at any time (`events.LoggedOut`).
- The library auto-fills its own session store (chats, contacts, push names) from history sync;
  message bodies are delivered to the application via history-sync payloads that we must persist
  ourselves.
- Media download requires the original protobuf message fields (URL, direct path, media key,
  hashes) — hence persisting the serialized proto blob at receive time.
- Auto-reconnect exists but reconnect/backoff state still must be surfaced to the UI as
  `ConnectionChanged` events.
- No calls, no Status, no Communities/Channels — all non-goals anyway.

### 1.3 Changes vs. the original brief (all **[D]** decisions)

1. **Fewer, thicker packages.** The proposed `messages/`, `chats/`, `contacts/`, `groups/`, `search/`
   service packages would be anemic wrappers at this stage. Until a service grows real logic, it
   lives in `app` (orchestration) over `storage` (persistence). Package split is cheap later;
   premature split is coupling today.
2. **Pure-Go SQLite driver** (`modernc.org/sqlite`): no cgo, trivially reproducible builds inside
   Xcode, FTS5 compiled in by default. mattn/go-sqlite3 needs build tags for FTS5 and drags cgo into
   the app-bundle build. If profiling later shows a bottleneck, switching drivers is contained to
   `storage.Open`.
3. **Separate session DB** (`session.db` for whatsmeow store, `app.db` for domain data): avoids
   write-lock coupling between bulk sync and the protocol layer, and isolates credentials.
4. **IPC before Unix sockets.** As instructed: don't prematurely optimize. HTTP+WS on 127.0.0.1 with
   a bearer token; UDS migration is a contained change in `ipc` + Swift transport later.
5. **Logout wipes local data.** Simplest correct privacy default for v0.1 (session deleted, app DB
   cleared); refine to "keep history" opt-in later.
6. **Unread counts derived locally** (see R8) rather than trusting any server-side count.

---

## 2. System overview

```text
┌───────────────────────────────────────────────┐
│ WhatsAppWork.app (Swift/SwiftUI)             │
│  Inbox · Conversations · Chat · Search · Focus │
└───────────────┬───────────────────────────────┘
                │ HTTP  (commands/queries, 127.0.0.1:<random>, Bearer token)
                │ WS    (events, same port/token)
┌───────────────▼───────────────────────────────┐
│ whatsapp-core (Go sidecar)                    │
│  ipc (REST+WS) → app (services, ingest)       │
│  events (dispatcher)   storage (SQLite/FTS5)  │
│  whatsapp adapter → whatsmeow                 │
└───────────────┬───────────────────────────────┘
                ▼ WhatsApp network (linked device)
```

## 3. Module boundaries (final)

```text
core/  (Go module "github.com/ralfiannor/whatsapp-work")
├── cmd/whatsapp-core      # main: flags, lock, wiring, READY handshake, signals
└── internal/
    ├── core/              # pure domain types + ports (no deps)
    ├── events/            # dispatcher: typed event fan-out to subscribers
    ├── storage/           # SQLite: migrations, repos, FTS5 (depends on core)
    ├── whatsapp/          # whatsmeow adapter: normalization → core types
    ├── app/               # orchestration: ingest pipeline, login FSM, services
    └── ipc/               # HTTP+WS transport over app (depends on app)
```

Dependency rules (enforced by review, not lint yet):

- `core` imports nothing internal.
- `storage` → `core` only. Never whatsmeow.
- `whatsapp` → `core` + whatsmeow. **The only package allowed to import whatsmeow.**
- `app` → `core`, `events`, `storage`, and a **narrow `WAClient` port interface** implemented by
  `whatsapp` (send text/reply/react, mark read, connect, start QR). No whatsmeow types cross this
  boundary — the adapter normalizes everything into `core` types first.
- `ipc` → `app` (+ `core` for DTO shapes).
- `cmd` wires everything.

### Incoming message pipeline (ordering guarantee)

```text
whatsmeow event → adapter (normalize → core types, single goroutine)
                → app ingest loop (single goroutine; total order)
                    1. storage tx: upsert chat, message, counters, FTS trigger
                    2. events dispatcher → subscribers (WS hub, notifications)
```

- One ingest goroutine ⇒ deterministic total order; persistence happens **before** fan-out, so a UI
  event always has a durable row behind it.
- Subscribers get buffered channels (256); a slow subscriber drops events (counted, surfaced in
  `/healthz`) rather than blocking ingest. The UI refetches on reconnect; events are hints, not
  source of truth. Source of truth is always SQLite.
- History sync bypasses per-message dispatch; only `sync.progress` events are emitted.

### Domain ports (in `core`)

```go
type WAClient interface {
    Connect(ctx context.Context) error
    Disconnect() error
    Logout(ctx context.Context) error
    LoggedIn() bool
    StartQRLink(ctx context.Context) (<-chan QRUpdate, error)
    SendText(ctx context.Context, chat JID, text string, reply *ReplyRef) (SendAck, error)
    React(ctx context.Context, chat JID, target MessageRef, emoji string) error
    MarkRead(ctx context.Context, chat JID, ids []string) error
    Events() <-chan RawEvent // normalized; never whatsmeow types
}
```

The full internal event model (Go types) lives in `internal/core/events.go`; the wire catalog for
the SwiftUI side lives in docs/protocol.md.

## 4. Storage design

Summary here; full DDL and rationale in docs/schema.md.

- `app.db` (domain data, WAL, 1 writer + N readers) and `session.db` (whatsmeow session store).
- Keyset pagination everywhere (`(timestamp, id)` cursor); no `SELECT *`; no OFFSET.
- FTS5 maintained by triggers in the same transaction as message writes.
- Denormalized chat counters (`unread_count`, `mentioned_unread`) updated transactionally on live
  ingest only.

## 5. Security posture

- IPC: 127.0.0.1 + random port + 32-byte bearer token via stdout handshake; constant-time compare;
  `Host` allow-list.
- Logs: message **content is never logged**; only IDs/JIDs/error codes. whatsmeow's internal logger
  runs at `warn` for the same reason.
- FS: data dir `0700`, DB files `0600`. Session file is a credential (R12: encryption later).
- No telemetry. If ever added: opt-in, no conversation data.

## 6. Swift ↔ Go sidecar lifecycle contract

Spawn (Swift) → Handshake → Serve → Shutdown:

1. **Spawn.** `Process(exec: WhatsAppWork.app/Contents/MacOS/whatsapp-core,
   args: ["--data-dir", <app-support>/core])`, stderr piped to `os_log`, stdout line-buffered.
2. **Handshake.** Core prints one JSON line on stdout when the IPC server is listening:
   `{"event":"ready","port":52341,"token":"<64hex>","pid":123,"version":"0.1.0"}`.
   Token exists only in memory (parent + child). Malformed startup line or exit before ready ⇒
   restart with backoff.
3. **Single instance.** Core takes `flock` on `<data-dir>/core.lock`; second instance exits with
   code 2. Swift treats exit 2 as "stale core running": offer kill or surface error.
4. **Crash recovery (Swift).** `terminationHandler` → restart backoff 1s, 2s, 5s, 10s, cap 60s;
   reset after 5 min stable. UI shows "core restarting" state, keeps last-known data, refetches
   `/chats` after reconnect.
5. **Shutdown.** App quit ⇒ Swift sends SIGTERM, waits ≤2 s, SIGKILL. Core on SIGTERM: close WS,
   stop HTTP, disconnect WhatsApp, close DBs, exit 0.
6. **Sleep/wake.** Core relies on whatsmeow auto-reconnect; Swift pings `/healthz` on
   `NSWorkspace.wakeNotification`; if dead ⇒ normal crash-restart path.
7. **Exit codes.** `0` clean · `2` lock held · `3` storage/DB fatal · `4` bad flags.

## 7. Reliability handling matrix

| Scenario | Behavior |
|---|---|
| Network drop / Wi-Fi switch | whatsmeow auto-reconnect; `connection.changed` events; UI banner |
| Sleep/wake, lid close | Same as above; Swift healthz ping on wake |
| QR expiry | Adapter regenerates QR (QR channel loop); `session.qr` event updates UI |
| Logged out remotely (`LoggedOut`, `StreamReplaced`) | Session deleted, state `logged_out`, UI returns to login; local DB kept until user logs out |
| DB busy/locked | WAL + 5 s busy_timeout + single writer; errors counted in `/healthz`, never crash |
| Sidecar crash | Swift restart contract (§6.4) |
| Send failure | Message stays `failed` locally (row kept), error surfaced in UI; manual retry (v0.1) |
| Duplicate events (history + live) | Idempotent upsert on `(chat, sender, message_id)` |
| Partial media download | `media.state` machine: `not_downloaded → downloading → downloaded | failed | unavailable` |
| Unknown message type | `kind=unsupported`, placeholder row |

## 8. What is intentionally NOT here

Per the brief's non-goals: calls, video, status, channels, communities, sticker/avatar editors,
payments, Meta AI, any AI features, WhatsApp Web/Desktop cloning. Cross-platform: the Go core stays
platform-independent (no macOS-only imports outside `cmd`); UI is macOS-only and unapologetic.
