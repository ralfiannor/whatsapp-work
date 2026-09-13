# SQLite Schema — app.db v1

Driver: `modernc.org/sqlite` (pure Go, FTS5 enabled). Two files in the data dir:

- `app.db` — domain data (this document). WAL, `synchronous=NORMAL`, `busy_timeout=5000`,
  `foreign_keys=ON`, `cache_size=-16000` (16 MB cap). Handles: 1 writer connection + 4-read pool.
- `session.db` — whatsmeow session store (its own schema, managed by whatsmeow). Treated as a
  credential: `0600`, never logged.

Migrations: append-only list in `internal/storage/migrations.go`, applied in a transaction, tracked
in `schema_migrations`. `AUTOINCREMENT` on `messages.id` so rowids are never reused (FTS rowid
mapping and API `rowid` references must stay stable).

Timestamps: unix **seconds** (WhatsApp server timestamps), stored as INTEGER. Local wall-clock
columns (`created_at`, `updated_at`) also unix seconds.

## DDL

```sql
CREATE TABLE accounts (
  id                 INTEGER PRIMARY KEY,
  jid                TEXT NOT NULL UNIQUE,      -- own JID once logged in
  platform           TEXT NOT NULL DEFAULT '',
  created_at         INTEGER NOT NULL,
  last_connected_at  INTEGER
);

CREATE TABLE contacts (
  jid            TEXT PRIMARY KEY,
  full_name      TEXT NOT NULL DEFAULT '',
  push_name      TEXT NOT NULL DEFAULT '',
  business_name  TEXT NOT NULL DEFAULT '',
  updated_at     INTEGER NOT NULL
);

CREATE TABLE chats (
  jid              TEXT PRIMARY KEY,            -- chat JID (person or @g.us group)
  kind             TEXT NOT NULL CHECK (kind IN ('direct','group')),
  display_name     TEXT NOT NULL DEFAULT '',    -- contact name | group subject | JID
  last_message_id  TEXT NOT NULL DEFAULT '',
  last_message_ts  INTEGER,                     -- NULL = no messages yet
  last_preview     TEXT NOT NULL DEFAULT '',
  last_read_ts     INTEGER NOT NULL DEFAULT 0,  -- local read position
  unread_count     INTEGER NOT NULL DEFAULT 0,  -- denormalized; live ingest only
  mentioned_unread INTEGER NOT NULL DEFAULT 0,
  is_pinned        INTEGER NOT NULL DEFAULT 0,
  is_muted         INTEGER NOT NULL DEFAULT 0,
  is_archived      INTEGER NOT NULL DEFAULT 0,
  is_work          INTEGER NOT NULL DEFAULT 0,  -- v0.2 focus features
  is_starred       INTEGER NOT NULL DEFAULT 0,  -- v0.2
  updated_at       INTEGER NOT NULL
);
CREATE INDEX idx_chats_last_ts ON chats(last_message_ts DESC);

CREATE TABLE messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id      TEXT NOT NULL,                -- WhatsApp stanza id
  chat_jid        TEXT NOT NULL REFERENCES chats(jid),
  sender_jid      TEXT NOT NULL,
  from_me         INTEGER NOT NULL DEFAULT 0,
  timestamp       INTEGER NOT NULL,
  kind            TEXT NOT NULL,                -- text|image|video|audio|document|sticker|system|unsupported
  raw_kind        TEXT NOT NULL DEFAULT '',
  text            TEXT NOT NULL DEFAULT '',     -- body or caption; FTS-indexed
  reply_to_id     TEXT NOT NULL DEFAULT '',
  reply_to_sender TEXT NOT NULL DEFAULT '',
  quoted_text     TEXT NOT NULL DEFAULT '',     -- preview snippet of the replied-to message
  has_mention     INTEGER NOT NULL DEFAULT 0,   -- mentions ME (own JID)
  mentioned_jids  TEXT NOT NULL DEFAULT '[]',   -- JSON array (v0.2 inbox)
  receipt_status  TEXT NOT NULL DEFAULT '',     -- outgoing: pending|sent|delivered|read|failed
  source          TEXT NOT NULL DEFAULT 'live', -- live|history
  revoked         INTEGER NOT NULL DEFAULT 0,
  edited_ts       INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  UNIQUE (chat_jid, sender_jid, message_id)     -- idempotent ingest (history+live overlap)
);
CREATE INDEX idx_messages_chat_ts ON messages(chat_jid, timestamp DESC, id DESC);
CREATE INDEX idx_messages_msgid   ON messages(message_id);
CREATE INDEX idx_messages_sender  ON messages(sender_jid);
CREATE INDEX idx_messages_mention ON messages(timestamp DESC)
  WHERE has_mention = 1 AND from_me = 0;

CREATE TABLE reactions (
  message_id  INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  reactor_jid TEXT NOT NULL,
  emoji       TEXT NOT NULL,                    -- '' row = removed
  timestamp   INTEGER NOT NULL,
  PRIMARY KEY (message_id, reactor_jid)
);

CREATE TABLE media (
  id              TEXT PRIMARY KEY,             -- hex(file_enc_sha256), fallback rowid-based
  message_id      INTEGER NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
  kind            TEXT NOT NULL,
  mime            TEXT NOT NULL DEFAULT '',
  size            INTEGER NOT NULL DEFAULT 0,
  filename        TEXT NOT NULL DEFAULT '',
  width           INTEGER NOT NULL DEFAULT 0,
  height          INTEGER NOT NULL DEFAULT 0,
  duration_ms     INTEGER NOT NULL DEFAULT 0,
  caption         TEXT NOT NULL DEFAULT '',
  url             TEXT NOT NULL DEFAULT '',     -- re-download material (URLs expire)
  direct_path     TEXT NOT NULL DEFAULT '',
  media_key       BLOB,
  file_sha256     BLOB,
  file_enc_sha256 BLOB,
  proto           BLOB,                         -- serialized waE2E media message; rehydrated on demand
  state           TEXT NOT NULL DEFAULT 'not_downloaded',
  local_path      TEXT NOT NULL DEFAULT '',
  thumb_path      TEXT NOT NULL DEFAULT '',
  downloaded_at   INTEGER,
  updated_at      INTEGER NOT NULL
);

CREATE TABLE group_participants (
  group_jid    TEXT NOT NULL,
  member_jid   TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  role         TEXT NOT NULL DEFAULT 'member',
  updated_at   INTEGER NOT NULL,
  PRIMARY KEY (group_jid, member_jid)
);

CREATE TABLE local_message_state (               -- v0.2 work inbox; schema present from day one
  message_id    INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
  done          INTEGER NOT NULL DEFAULT 0,
  snoozed_until INTEGER,
  starred       INTEGER NOT NULL DEFAULT 0,
  priority      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);

CREATE VIRTUAL TABLE messages_fts USING fts5(text, chat_jid UNINDEXED);

CREATE TRIGGER messages_fts_ai AFTER INSERT ON messages WHEN NEW.text != '' BEGIN
  INSERT INTO messages_fts(rowid, text, chat_jid) VALUES (NEW.rowid, NEW.text, NEW.chat_jid);
END;
CREATE TRIGGER messages_fts_ad AFTER DELETE ON messages WHEN OLD.text != '' BEGIN
  DELETE FROM messages_fts WHERE rowid = OLD.rowid;
END;
CREATE TRIGGER messages_fts_au AFTER UPDATE OF text ON messages
WHEN NEW.text != '' OR OLD.text != '' BEGIN
  DELETE FROM messages_fts WHERE rowid = OLD.rowid;
  INSERT INTO messages_fts(rowid, text, chat_jid) VALUES (NEW.rowid, NEW.text, NEW.chat_jid);
END;
```

## Design notes

- **Idempotency.** `UNIQUE (chat_jid, sender_jid, message_id)` + `INSERT … ON CONFLICT DO NOTHING`
  makes ingest idempotent; history+live double delivery converges to one row. `sender_jid` is always
  set by the normalizer (fallback: chat JID) because SQLite UNIQUE treats NULLs as distinct.
- **Unread derivation.** `unread_count`/`mentioned_unread` are maintained in the same transaction as
  the message insert, and **only for live-source incoming messages newer than `last_read_ts`**.
  History backfill never marks anything unread. Read marking zeroes counters and advances
  `last_read_ts` atomically.
- **Pagination.** All message queries are keyset: `(timestamp, id)` descending, `LIMIT n`, cursor
  = `<ts>,<id>` of the last row. `idx_messages_chat_ts` covers it. No `SELECT *`, no OFFSET.
- **FTS.** Content lives in the FTS table itself (self-contented), so `snippet()`/`rank` work.
  Triggers run inside the message write transaction — index and rows can't diverge. User queries are
  tokenized and each term quoted (`"deployment" "staging"`) to avoid FTS5 grammar injection.
- **Media.** Metadata (incl. keys + proto blob) persisted at receive time; nothing downloaded
  eagerly. `state` machine drives the UI; `unavailable` is a legitimate terminal state (URL expiry).
- **What is NOT here.** Receipt rows per-recipient (v0.2+), ephemeral-message retention enforcement
  (v0.2 policy question), per-chat message retention caps (measure growth first).
