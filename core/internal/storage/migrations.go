package storage

import (
	"context"
	"fmt"
)

// Migrations are append-only. Never edit an applied migration — add a new one.
var migrations = []struct {
	Version int64
	Name    string
	SQL     string
}{
	{1, "initial schema", migrationV1},
	{2, "media id no longer globally unique", migrationV2},
	{3, "unsupported rows that gained text via re-delivery", migrationV3},
	{4, "repair senders concatenated without @", migrationV4},
	{5, "recompute chat previews after kind repairs", migrationV5},
	{6, "specific labels for empty unsupported previews", migrationV6},
	{7, "purge skdm noise rows and raw fallback names", migrationV7},
	{8, "repoint last message after skdm purge", migrationV8},
	{9, "consistent last-message recompute, inbox indexes, LID mask clamp", migrationV9},
	{10, "forwarded message flag", migrationV10},
	{11, "inbox becomes live-entry work state; baseline existing rows done", migrationV11},
	{12, "done_at timestamp for the recently-done inbox section", migrationV12},
	{13, "reopen baseline-done rows that are recent and still unread", migrationV13},
	{14, "conversation-level snooze on chats", migrationV14},
	{15, "pending-state index for the inbox query; drop superseded inbox indexes", migrationV15},
}

func (s *Store) migrate(ctx context.Context) error {
	if _, err := s.w.ExecContext(ctx, `
		CREATE TABLE IF NOT EXISTS schema_migrations (
			version    INTEGER PRIMARY KEY,
			name       TEXT NOT NULL,
			applied_at INTEGER NOT NULL
		)`); err != nil {
		return fmt.Errorf("storage: migrations table: %w", err)
	}

	var current int64
	if err := s.w.QueryRowContext(ctx, `SELECT COALESCE(MAX(version), 0) FROM schema_migrations`).Scan(&current); err != nil {
		return fmt.Errorf("storage: read schema version: %w", err)
	}

	for _, m := range migrations {
		if m.Version <= current {
			continue
		}
		tx, err := s.w.BeginTx(ctx, nil)
		if err != nil {
			return fmt.Errorf("storage: migrate v%d begin: %w", m.Version, err)
		}
		if _, err := tx.ExecContext(ctx, m.SQL); err != nil {
			tx.Rollback()
			return fmt.Errorf("storage: migrate v%d (%s): %w", m.Version, m.Name, err)
		}
		if _, err := tx.ExecContext(ctx,
			`INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, strftime('%s','now'))`,
			m.Version, m.Name); err != nil {
			tx.Rollback()
			return fmt.Errorf("storage: record v%d: %w", m.Version, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("storage: commit v%d: %w", m.Version, err)
		}
		s.log.Info("storage: applied migration", "version", m.Version, "name", m.Name)
	}
	return nil
}

const migrationV1 = `
CREATE TABLE accounts (
  id                INTEGER PRIMARY KEY,
  jid               TEXT NOT NULL UNIQUE,
  platform          TEXT NOT NULL DEFAULT '',
  created_at        INTEGER NOT NULL,
  last_connected_at INTEGER
);

CREATE TABLE contacts (
  jid           TEXT PRIMARY KEY,
  full_name     TEXT NOT NULL DEFAULT '',
  push_name     TEXT NOT NULL DEFAULT '',
  business_name TEXT NOT NULL DEFAULT '',
  updated_at    INTEGER NOT NULL
);

CREATE TABLE chats (
  jid              TEXT PRIMARY KEY,
  kind             TEXT NOT NULL CHECK (kind IN ('direct','group')),
  display_name     TEXT NOT NULL DEFAULT '',
  last_message_id  TEXT NOT NULL DEFAULT '',
  last_message_ts  INTEGER,
  last_preview     TEXT NOT NULL DEFAULT '',
  last_read_ts     INTEGER NOT NULL DEFAULT 0,
  unread_count     INTEGER NOT NULL DEFAULT 0,
  mentioned_unread INTEGER NOT NULL DEFAULT 0,
  is_pinned        INTEGER NOT NULL DEFAULT 0,
  is_muted         INTEGER NOT NULL DEFAULT 0,
  is_archived      INTEGER NOT NULL DEFAULT 0,
  is_work          INTEGER NOT NULL DEFAULT 0,
  is_starred       INTEGER NOT NULL DEFAULT 0,
  updated_at       INTEGER NOT NULL
);
CREATE INDEX idx_chats_last_ts ON chats(last_message_ts DESC);

CREATE TABLE messages (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id      TEXT NOT NULL,
  chat_jid        TEXT NOT NULL REFERENCES chats(jid),
  sender_jid      TEXT NOT NULL,
  from_me         INTEGER NOT NULL DEFAULT 0,
  timestamp       INTEGER NOT NULL,
  kind            TEXT NOT NULL,
  raw_kind        TEXT NOT NULL DEFAULT '',
  text            TEXT NOT NULL DEFAULT '',
  reply_to_id     TEXT NOT NULL DEFAULT '',
  reply_to_sender TEXT NOT NULL DEFAULT '',
  quoted_text     TEXT NOT NULL DEFAULT '',
  has_mention     INTEGER NOT NULL DEFAULT 0,
  mentioned_jids  TEXT NOT NULL DEFAULT '[]',
  receipt_status  TEXT NOT NULL DEFAULT '',
  source          TEXT NOT NULL DEFAULT 'live',
  revoked         INTEGER NOT NULL DEFAULT 0,
  edited_ts       INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  UNIQUE (chat_jid, sender_jid, message_id)
);
CREATE INDEX idx_messages_chat_ts ON messages(chat_jid, timestamp DESC, id DESC);
CREATE INDEX idx_messages_msgid   ON messages(message_id);
CREATE INDEX idx_messages_sender  ON messages(sender_jid);
CREATE INDEX idx_messages_mention ON messages(timestamp DESC)
  WHERE has_mention = 1 AND from_me = 0;

CREATE TABLE reactions (
  message_id  INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  reactor_jid TEXT NOT NULL,
  emoji       TEXT NOT NULL,
  timestamp   INTEGER NOT NULL,
  PRIMARY KEY (message_id, reactor_jid)
);

CREATE TABLE media (
  id               TEXT PRIMARY KEY,
  message_id       INTEGER NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
  kind             TEXT NOT NULL,
  mime             TEXT NOT NULL DEFAULT '',
  size             INTEGER NOT NULL DEFAULT 0,
  filename         TEXT NOT NULL DEFAULT '',
  width            INTEGER NOT NULL DEFAULT 0,
  height           INTEGER NOT NULL DEFAULT 0,
  duration_ms      INTEGER NOT NULL DEFAULT 0,
  caption          TEXT NOT NULL DEFAULT '',
  url              TEXT NOT NULL DEFAULT '',
  direct_path      TEXT NOT NULL DEFAULT '',
  media_key        BLOB,
  file_sha256      BLOB,
  file_enc_sha256  BLOB,
  proto            BLOB,
  state            TEXT NOT NULL DEFAULT 'not_downloaded',
  local_path       TEXT NOT NULL DEFAULT '',
  thumb_path       TEXT NOT NULL DEFAULT '',
  downloaded_at    INTEGER,
  updated_at       INTEGER NOT NULL
);

CREATE TABLE group_participants (
  group_jid    TEXT NOT NULL,
  member_jid   TEXT NOT NULL,
  display_name TEXT NOT NULL DEFAULT '',
  role         TEXT NOT NULL DEFAULT 'member',
  updated_at   INTEGER NOT NULL,
  PRIMARY KEY (group_jid, member_jid)
);

CREATE TABLE local_message_state (
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
`

// migrationV2: forwarded/re-shared media carries the same file hash in many
// messages; media.id must not be globally unique. Keep one row per message.
const migrationV2 = `
CREATE TABLE media_v2 (
  id               TEXT NOT NULL,
  message_id       INTEGER NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
  kind             TEXT NOT NULL,
  mime             TEXT NOT NULL DEFAULT '',
  size             INTEGER NOT NULL DEFAULT 0,
  filename         TEXT NOT NULL DEFAULT '',
  width            INTEGER NOT NULL DEFAULT 0,
  height           INTEGER NOT NULL DEFAULT 0,
  duration_ms      INTEGER NOT NULL DEFAULT 0,
  caption          TEXT NOT NULL DEFAULT '',
  url              TEXT NOT NULL DEFAULT '',
  direct_path      TEXT NOT NULL DEFAULT '',
  media_key        BLOB,
  file_sha256      BLOB,
  file_enc_sha256  BLOB,
  proto            BLOB,
  state            TEXT NOT NULL DEFAULT 'not_downloaded',
  local_path       TEXT NOT NULL DEFAULT '',
  thumb_path       TEXT NOT NULL DEFAULT '',
  downloaded_at    INTEGER,
  updated_at       INTEGER NOT NULL
);
INSERT INTO media_v2 SELECT id, message_id, kind, mime, size, filename, width, height,
  duration_ms, caption, url, direct_path, media_key, file_sha256, file_enc_sha256,
  proto, state, local_path, thumb_path, downloaded_at, updated_at FROM media;
DROP TABLE media;
ALTER TABLE media_v2 RENAME TO media;
CREATE INDEX idx_media_id ON media(id);
`

// migrationV3: retries deliver real content after an encryption-envelope-only
// first write; those rows kept kind=unsupported despite carrying text.
const migrationV3 = `
UPDATE messages SET kind = 'text', raw_kind = '' WHERE kind = 'unsupported' AND text != '';
`

// migrationV4: an LID-rewrite bug concatenated the user part with the server
// suffix ("6285…s.whatsapp.net"). Some broken rows duplicate a healthy row
// (message re-delivered after the bug) — UNIQUE(chat,sender,message) forbids
// a plain rewrite, so drop the broken duplicates first, then repair the rest.
const migrationV4 = `
DELETE FROM messages WHERE rowid IN (
  SELECT m.rowid FROM messages m
  JOIN messages h
    ON h.chat_jid = m.chat_jid
   AND h.message_id = m.message_id
   AND h.sender_jid = REPLACE(m.sender_jid, 's.whatsapp.net', '@s.whatsapp.net')
  WHERE m.sender_jid LIKE '%s.whatsapp.net' AND m.sender_jid NOT LIKE '%@%'
);
UPDATE messages SET sender_jid = REPLACE(sender_jid, 's.whatsapp.net', '@s.whatsapp.net')
 WHERE sender_jid LIKE '%s.whatsapp.net' AND sender_jid NOT LIKE '%@%';
`

// migrationV5: previews were written before kind repairs (v3) left many rows
// as "Unsupported message"; recompute every chat preview from its newest row.
const migrationV5 = `
UPDATE chats SET last_preview = COALESCE((
  SELECT CASE
    WHEN m.revoked = 1 THEN ''
    WHEN m.kind = 'text' OR m.kind = 'system' THEN substr(m.text, 1, 96)
    WHEN m.kind = 'image' THEN COALESCE(NULLIF(m.text, ''), 'Photo')
    WHEN m.kind = 'video' THEN COALESCE(NULLIF(m.text, ''), 'Video')
    WHEN m.kind = 'audio' THEN 'Audio message'
    WHEN m.kind = 'sticker' THEN 'Sticker'
    WHEN m.kind = 'document' THEN COALESCE(NULLIF(md.filename, ''), 'Document')
    WHEN m.kind = 'unsupported' THEN COALESCE(NULLIF(m.text, ''), 'Unsupported message')
    ELSE 'Message'
  END
  FROM messages m
  LEFT JOIN media md ON md.message_id = m.id
  WHERE m.chat_jid = chats.jid
    AND m.message_id = chats.last_message_id
  ORDER BY m.id DESC LIMIT 1
), last_preview);
`

// migrationV6: unsupported-empty previews become specific labels
// (re-sync will replace them with real content when available).
const migrationV6 = `
UPDATE chats SET last_preview = COALESCE((
  SELECT CASE
    WHEN m.kind != 'unsupported' OR COALESCE(m.text,'') != '' THEN NULL -- keep v5 result
    WHEN m.raw_kind IN ('template','interactive') THEN 'Interactive message'
    WHEN m.raw_kind = 'skdm' THEN 'Message not synced yet'
    WHEN m.raw_kind = 'contact_card' THEN 'Contact card'
    WHEN m.raw_kind = 'group_invite' THEN 'Group invite'
    WHEN m.raw_kind = 'album' THEN 'Album'
    ELSE 'Message'
  END
  FROM messages m
  WHERE m.chat_jid = chats.jid AND m.message_id = chats.last_message_id
  ORDER BY m.id DESC LIMIT 1
), last_preview)
WHERE last_preview = 'Unsupported message';
`

// migrationV7: sender-key envelopes were stored as content-less "skdm" rows
// (shown as "Message not synced yet" en masse); drop them, prettify raw
// fallback names, and recompute affected previews.
const migrationV7 = `
DELETE FROM messages WHERE kind = 'unsupported' AND raw_kind = 'skdm';

UPDATE chats SET display_name = CASE
  WHEN jid = '0@s.whatsapp.net' THEN 'WhatsApp'
  WHEN display_name LIKE '%@lid' THEN
    '•••' || substr(display_name, instr(display_name, '@') - 4, 4)
  ELSE display_name
END
WHERE kind = 'direct' AND (display_name LIKE '%@lid' OR display_name LIKE '%@s.whatsapp.net');

UPDATE chats SET last_preview = COALESCE((
  SELECT CASE
    WHEN m.revoked = 1 THEN ''
    WHEN m.kind IN ('text','system') OR COALESCE(m.text,'') != '' THEN substr(COALESCE(NULLIF(m.text,''), m.kind), 1, 96)
    WHEN m.kind = 'image' THEN COALESCE(NULLIF(m.text, ''), 'Photo')
    WHEN m.kind = 'video' THEN COALESCE(NULLIF(m.text, ''), 'Video')
    WHEN m.kind = 'audio' THEN 'Audio message'
    WHEN m.kind = 'sticker' THEN 'Sticker'
    WHEN m.kind = 'document' THEN COALESCE(NULLIF(md.filename, ''), 'Document')
    ELSE 'Message'
  END
  FROM messages m LEFT JOIN media md ON md.message_id = m.id
  WHERE m.chat_jid = chats.jid AND m.message_id = chats.last_message_id
  ORDER BY m.id DESC LIMIT 1
), last_preview)
WHERE last_preview IN ('Message not synced yet', 'Unsupported message');
`

// migrationV8: chats whose last_message_id pointed at a purged skdm row
// keep stale previews and timestamps; recompute from remaining messages
// and hide chats left with none.
const migrationV8 = `
UPDATE chats SET
  last_message_id = COALESCE((
    SELECT m.message_id FROM messages m WHERE m.chat_jid = chats.jid ORDER BY m.id DESC LIMIT 1), ''),
  last_message_ts = (
    SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE MAX(timestamp) END
    FROM messages m WHERE m.chat_jid = chats.jid),
  last_preview = COALESCE((
    SELECT CASE
      WHEN m.revoked = 1 THEN ''
      WHEN COALESCE(m.text, '') != '' THEN substr(m.text, 1, 96)
      WHEN m.kind = 'image' THEN 'Photo'
      WHEN m.kind = 'video' THEN 'Video'
      WHEN m.kind = 'audio' THEN 'Audio message'
      WHEN m.kind = 'sticker' THEN 'Sticker'
      WHEN m.kind = 'document' THEN COALESCE(NULLIF(md.filename, ''), 'Document')
      WHEN m.kind = 'system' THEN substr(COALESCE(m.text, ''), 1, 96)
      ELSE 'Message'
    END
    FROM messages m LEFT JOIN media md ON md.message_id = m.id
    WHERE m.chat_jid = chats.jid ORDER BY m.id DESC LIMIT 1), '');
`


// migrationV9: v8 derived last_message_ts from MAX(timestamp) but id/preview
// from the newest-insert row — out-of-order sync could mix two different
// messages into one chat row. Recompute all three from the same row, restore
// the specific unsupported labels v8 flattened, add covering indexes for the
// inbox poll and media eviction, and clamp the LID mask substr.
const migrationV9 = `
UPDATE chats SET
  last_message_id = COALESCE((
    SELECT m.message_id FROM messages m
    WHERE m.chat_jid = chats.jid ORDER BY m.timestamp DESC, m.id DESC LIMIT 1), ''),
  last_message_ts = (
    SELECT CASE WHEN COUNT(*) = 0 THEN NULL ELSE MAX(timestamp) END
    FROM messages m WHERE m.chat_jid = chats.jid),
  last_preview = COALESCE((
    SELECT CASE
      WHEN m.revoked = 1 THEN ''
      WHEN COALESCE(m.text, '') != '' THEN substr(m.text, 1, 96)
      WHEN m.kind = 'image' THEN 'Photo'
      WHEN m.kind = 'video' THEN 'Video'
      WHEN m.kind = 'audio' THEN 'Audio message'
      WHEN m.kind = 'sticker' THEN 'Sticker'
      WHEN m.kind = 'document' THEN COALESCE(NULLIF(md.filename, ''), 'Document')
      WHEN m.kind = 'system' THEN substr(COALESCE(m.text, ''), 1, 96)
      WHEN m.kind = 'unsupported' THEN CASE m.raw_kind
        WHEN 'template' THEN 'Interactive message'
        WHEN 'interactive' THEN 'Interactive message'
        WHEN 'contact_card' THEN 'Contact card'
        WHEN 'group_invite' THEN 'Group invite'
        WHEN 'poll' THEN 'Poll'
        WHEN 'album' THEN 'Album'
        WHEN 'location' THEN 'Location'
        WHEN 'live_location' THEN 'Location'
        WHEN 'product' THEN 'Product'
        WHEN 'event' THEN 'Event'
        ELSE 'Message' END
      ELSE 'Message'
    END
    FROM messages m LEFT JOIN media md ON md.message_id = m.id
    WHERE m.chat_jid = chats.jid ORDER BY m.timestamp DESC, m.id DESC LIMIT 1), '');

UPDATE chats SET display_name = '•••' || substr(display_name, MAX(instr(display_name, '@') - 4, 1), 4)
WHERE kind = 'direct' AND display_name LIKE '%@lid';

CREATE INDEX IF NOT EXISTS idx_messages_inbox
  ON messages(timestamp DESC) WHERE from_me = 0 AND revoked = 0;
CREATE INDEX IF NOT EXISTS idx_media_evict
  ON media(downloaded_at) WHERE state = 'downloaded';
`

// migrationV10: forwarded/re-shared messages carry WhatsApp's forwarding
// marker; persist it so the UI can distinguish them. No backfill — history
// rows before this migration simply render as normal (score is not stored
// anywhere else to recover it from).
const migrationV10 = `
ALTER TABLE messages ADD COLUMN forwarded INTEGER NOT NULL DEFAULT 0;
`

// migrationV11: the work inbox stops exiting on read state — items leave only
// via Done or a not-yet-due Snooze, and only LIVE incoming messages enter
// (history sync is born read by design). To keep the queue from flooding with
// every pre-existing incoming row the moment the gate changes, all existing
// incoming messages are baselined as done; the inbox fills from upgrade time
// forward. The inbox partial index follows the new WHERE shape.
const migrationV11 = `
INSERT INTO local_message_state (message_id, done, snoozed_until, starred, priority)
SELECT id, 1, NULL, 0, 0 FROM messages WHERE from_me = 0
ON CONFLICT (message_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_messages_inbox_live
  ON messages(timestamp DESC) WHERE from_me = 0 AND revoked = 0 AND source = 'live';
`

// migrationV12: when an item was marked done, so the inbox can show a
// "recently done" section ordered by completion time (message timestamps
// would interleave old items done today with today's items done long ago).
const migrationV12 = `
ALTER TABLE local_message_state ADD COLUMN done_at INTEGER;
CREATE INDEX IF NOT EXISTS idx_local_state_done_at
  ON local_message_state(done_at DESC) WHERE done = 1;
`

// migrationV13: the v11 baseline marked EVERY pre-existing incoming row done
// to keep the queue from flooding — which also swallowed the genuinely
// pending backlog (unread live traffic from the last week, e.g. a group the
// user just marked as Work). Reopen exactly those rows: recent (7 days),
// still unread (past the chat's read position), live-delivered. Rows the
// user explicitly done'd after v12 carry done_at and stay done; read chatter
// stays done; history stays done.
const migrationV13 = `
UPDATE local_message_state SET done = 0
WHERE done = 1 AND done_at IS NULL
  AND message_id IN (
    SELECT m.id FROM messages m JOIN chats c ON c.jid = m.chat_jid
    WHERE m.source = 'live' AND m.from_me = 0 AND m.revoked = 0 AND m.kind != 'system'
      AND m.timestamp > c.last_read_ts
      AND m.timestamp > CAST(strftime('%s','now') AS INTEGER) - 7*86400);
`

// migrationV14: conversation-level snooze. Per-message snooze cannot hold
// messages that arrive AFTER the snooze was set — a conversation put aside
// until tomorrow must stay hidden even as new traffic lands. The chat row
// carries the deadline; the inbox query gates on it.
const migrationV14 = `
ALTER TABLE chats ADD COLUMN snoozed_until INTEGER;
`

// migrationV15: the inbox query drives from the PENDING local-state rows
// (CROSS JOIN onto messages by rowid) instead of scanning all messages and
// probing local state per row. That requires every live incoming message
// to carry a local-state row (live ingest maintains it from now on; rows
// without one are backfilled as pending, which is exactly the old
// COALESCE(ls.done,0)=0 semantics). The two old partial message indexes
// served the pre-v11 query shapes and are planner-dead now — dropping them
// removes two index writes per ingested message (including history sync).
const migrationV15 = `
INSERT INTO local_message_state (message_id, done, snoozed_until, starred, priority)
SELECT id, 0, NULL, 0, 0 FROM messages
WHERE source = 'live' AND from_me = 0 AND revoked = 0 AND kind != 'system'
ON CONFLICT (message_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_local_state_pending
	ON local_message_state(message_id) WHERE done = 0;
DROP INDEX IF EXISTS idx_messages_inbox;
DROP INDEX IF EXISTS idx_messages_inbox_live;
`
