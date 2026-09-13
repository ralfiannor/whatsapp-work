# IPC Protocol — Swift ↔ Go Core (v0.1)

Transport: HTTP/1.1 + WebSocket on `127.0.0.1:<random-port>`.
Auth: `Authorization: Bearer <token>` on every request (including WS). Constant-time compare.
Host header must be `127.0.0.1:<port>`. JSON bodies; UTF-8; empty-body POSTs allowed.

The token and port are delivered once via the sidecar's stdout `READY` line (see
docs/architecture.md §6). No version prefix in paths during 0.x — the contract is allowed to break
until 1.0; `GET /healthz` reports the version for diagnostics.

## Errors

Non-2xx responses carry `{"error": {"code": "not_found", "message": "..."}}`.
Codes: `bad_request` · `unauthorized` · `not_found` · `conflict` · `internal`.

## Endpoints

### Session / connection

```
GET /healthz
→ 200 {"status":"ok","version":"0.1.0","uptime_s":123,
        "connection":{"state":"connected"},
        "stats":{"messages_ingested":10,"ingest_errors":0,"events_dropped":0}}
```

States: `logged_out` · `linking` · `connecting` · `connected` · `offline`.

```
GET /session
→ 200 {"state":"linking",
        "account":"2547…@s.whatsapp.net" | null,
        "qr":{"code":"2@…","expires_ts":1724700000} | null,
        "sync":{"stage":"messages","progress":42.5} | null}
```

```
POST /session/link        {"mode":"qr"}          # starts QR login (only from logged_out)
POST /session/logout      → 204                  # WhatsApp logout + local wipe, state → logged_out
```

### Chats

```
GET /chats?limit=50&cursor=<last_message_ts>,<last_jid>&filter=all|unread|mentions
→ 200 {"chats":[{ "jid":"…","kind":"direct|group","display_name":"Person A",
                  "last_message_ts":1724…,"last_preview":"…","last_message_id":"…",
                  "unread_count":2,"mentioned_unread":1,
                  "is_pinned":false,"is_muted":false,"is_archived":false,
                  "is_work":false,"is_starred":false }],
        "next_cursor":"1724…" | null}
```

Order: `last_message_ts DESC`, pinned first (v0.1: time order only). Cursor is opaque — pass back
verbatim.

```
GET /chats/{jid}/messages?before=<cursor>&limit=50
→ 200 {"messages":[ Message… ], "next_cursor":"<ts>,<id>" | null}
```

Keyset pagination: `before` is the cursor from the previous page (first page: omit).
`limit` is clamped to 1–199 (the server probes with limit+1 against a 200-row store max).

```
POST /chats/{jid}/read
→ 204        # marks chat read locally + sends WhatsApp read receipt for unread incoming ids
```

### Messages

```jsonc
// Message shape (REST + WS payloads use the same shape)
{ "id": 481,                     // local rowid, stable
  "message_id": "3EB0…",         // WhatsApp stanza id
  "chat_jid": "2547…@s.whatsapp.net",
  "sender_jid": "2547…@s.whatsapp.net",
  "from_me": false,
  "timestamp": 1724700000,       // unix seconds, server time
  "kind": "text",                // text|image|video|audio|document|sticker|system|unsupported
  "raw_kind": "",                // underlying type label when kind=unsupported
  "text": "Can you review this?",// searchable text (body or media caption)
  "reply_to_id": "…",            // flat reply reference (empty when not a reply)
  "reply_to_sender": "…",
  "quoted_text": "…",
  "has_mention": true,
  "mentioned_jids": ["…"],
  "receipt_status": "",          // outgoing only: pending|sent|delivered|read|failed
  "revoked": false,
  "forwarded": false,
  "edited_ts": 0,                // nonzero when the message was edited
  "reactions": [],               // [{reactor_jid, emoji}] (GET lists only)
  "starred": false,               // local work state (LEFT JOIN local_message_state)
  "done": false,                  // local work state; true hides the row from /inbox
  "media": { "id":"…","kind":"image","mime":"image/jpeg","size":183241,
             "filename":"","width":1280,"height":960,"duration_ms":0,
             "state":"not_downloaded|downloading|downloaded|failed|unavailable",
             "local_path":"" } | null }
```

```
POST /messages                  {"chat_jid":"…","text":"…",
                                 "reply_to":{"id":"…","sender":"…"}?,
                                 "mentioned_jids":["…"]?}
→ 201 Message                   // persisted as sent (receipt_status="sent")

POST /messages/{rowid}/react    {"emoji":"✅"}   // "" removes the reaction
→ 204

POST /chats/{jid}/media?kind=image&mime=image/jpeg&filename=…[&caption=…]
  body: raw bytes (≤ 20 MiB)    // reply context via `reply_id` /
                                 // `reply_sender` query params
→ 201 Message
```

### Contacts / groups

```
GET /contacts?q=<substring>&limit=50
→ 200 {"contacts":[{"jid":"…","full_name":"…","push_name":"…","business_name":"…"}]}

GET /groups/{jid}/members
→ 200 {"members":[{"jid":"…","display_name":"…","role":"admin|member","lid":"…"?}]}

GET /contacts/{jid}/profile
→ 200 {"jid":"…","lid":"…"?,"full_name":"…","push_name":"…",
        "business_name":"…","avatar":{"id":"…","url":"…"}?}

GET /contacts/{jid}/identity    // reserved: PN↔LID mapping probe (unused by
→ 200 {"pn":"…","lid":"…"}       // the app today; treat as diagnostic)
```

### Search

```
GET /search?q=deployment%20staging&limit=25
→ 200 {"messages":[{"rowid":481,"chat_jid":"…","timestamp":1724…,
                    "kind":"text","snippet":"… deployment on ⟪staging⟫ failed …"}],
        "chats":[{"jid":"…","display_name":"…"}],
        "contacts":[{"jid":"…","full_name":"…"}]}
```

FTS5 under the hood: terms are ANDed; exact-token matching (no prefix search in v0.1).
Chats/contacts matched by substring on display name.

### Media (on-demand)

Nothing downloads eagerly. A message row carries `media.state`; the UI asks
for bytes when a bubble becomes visible:

```
POST /media/{rowid}/download
→ 200 {"message": Message}      // media.state → downloaded, local_path set
→ 404 no media for that message · 500 download failed (state → failed, retryable)

GET /media/{rowid}/file
→ 200 <bytes>                   // Content-Type from stored MIME; 404 if not downloaded
```

`media.state` machine: `not_downloaded → downloading → downloaded | failed |
unavailable`. The core evicts least-recently-downloaded items to honor the
cache cap (`--media-cache-mb`, default 500 MB) — evicted rows return to
`not_downloaded` and can be fetched again. State transitions also arrive as
`media.updated` events.

## WebSocket

`GET ws://127.0.0.1:<port>/ws` (same bearer token, header or `?token=`).

Envelope:

```json
{"type":"message.received","seq":17,"data":{ … }}
```

- `seq` is per-connection, monotonically increasing. On reconnect, the client refetches state
  (`/chats`, open chat page 1) — events are hints; SQLite via REST is the source of truth.
- Server sends `{"type":"ping"}` every 25 s; client must reply `{"type":"pong"}` (or any frame)
  within the 60 s read timeout or the connection is closed.

### Event catalog

| `type` | `data` | When |
|---|---|---|
| `connection.changed` | `{state, reason?}` | connect/disconnect/logged-out transitions |
| `session.qr` | `{code, expires_ts}` | new QR available during linking |
| `sync.progress` | `{stage: chats\|messages\|done, progress: 0–100}` | history sync |
| `message.received` | `{message: Message}` | new message (in or out), post-persist |
| `message.updated` | `{message: Message}` | edit, revoke, receipt status change |
| `chat.updated` | `{chat: Chat}` | chat row changed (preview, counters, name) |
| `chat.removed` | `{jid}` | chat row dropped (LID thread folded into its phone twin) — purge stale copies |
| `contacts.updated` | `{changed}` | contact name data actually changed (insert/rename, not a no-op re-upsert) — clients refresh their name maps |
| `inbox.changed` | `{reason}` | work-inbox membership moved (done/snooze/star/chat work flag); refetch `/inbox` if visible |
| `reaction.received` | `{message_rowid, chat_jid, reactor_jid, emoji}` | reaction added/removed (a `message.updated` with the full row follows) |
| `media.updated` | `{message_rowid, chat_jid, media: Media}` | media state transition (downloading/downloaded/failed/evicted) |

Reconnect strategy: there is no replay. On (re)connect — or on detecting a seq
gap — the client refetches `/chats` and the currently open chat's first page;
events are hints, SQLite via REST is the source of truth.

Slow consumers: the hub closes a connection that stays unresponsive with
close code 1008; under sudden backpressure the dispatcher can also drop
events (counted in `/healthz` → `events_dropped`, visible as a seq jump). A
client that notices a gap refetches.

## Work inbox (v0.2)

`GET /inbox?limit=100` — the local work queue as **conversations**: one digest
row per chat with pending items, so a busy group is one Done, not fifty:

```json
{
  "mentions":        [InboxConversation…],
  "direct_messages": [InboxConversation…],
  "work_groups":     [InboxConversation…],
  "starred_chats":   [Chat…],
  "done_recent":     [InboxItem…],
  "counts": {"total": n, "mentions": n, "direct": n, "work": n}
}
```

`InboxConversation` carries the chat identity plus `last_message_id` /
`last_rowid` / `last_sender_jid` / `last_text` / `last_timestamp` (newest
pending item, for deep-linking), `has_mention` (any pending item mentions me)
and `count` (pending items). `done_recent` is a message-level audit trail of
the last 7 days with `done_at` ordering.

Semantics (docs/feature-audit-2026-08-30.md):

- **Entry**: a live-delivered incoming message that is a mention, a direct
  message, or traffic in a work-marked group. History-sync rows never enter
  (they are born read); the v11 baseline marked pre-existing rows done and v13
  reopened the recent-unread backlog.
- **Exit**: conversation `done` (all items at once), or a not-yet-due
  conversation snooze. **Read state is not an exit** — reading a chat (on
  this device or the phone) keeps its items actionable. `Unread`/`Mentions`
  chat filters remain read-coupled; the inbox is pure local work state.
- A conversation snoozed via the chat deadline stays hidden even for messages
  arriving AFTER the snooze was set, until the deadline passes.

Local state (server-side persistent, per message/chat):

- `POST /messages/{rowid}/done` `{done: true|false}` (single item)
- `POST /messages/{rowid}/snooze` `{until: <unix seconds>}` (preferred;
  `{minutes: n}` still accepted as a legacy relative form; `0`/omitted clears)
- `POST /messages/{rowid}/star` `{starred: true|false}`
- `POST /chats/{jid}/done` `{done: true|false}` — bulk: completes (or
  reopens) EVERY pending inbox item of the conversation; also clears any
  conversation snooze
- `POST /chats/{jid}/snooze` `{until: <unix seconds>}` — bulk: defers the
  whole conversation, holding messages that arrive later
- `POST /chats/{jid}/star` `{starred: true|false}` / `POST /chats/{jid}/work` `{work: true|false}`

`done`/`star` on messages emit `message.updated` over the WebSocket; every
work-state mutation also emits `inbox.changed`; chat flags emit `chat.updated`.
Snooze deadlines are evaluated against server wall-clock at query time
(`snoozed_until <= now`) — there are no core timers, so clients refresh
`/inbox` periodically while their inbox view is visible.
