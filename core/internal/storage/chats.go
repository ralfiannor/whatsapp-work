package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// ErrNotFound is returned when a row does not exist.
var ErrNotFound = errors.New("storage: not found")

func now() int64 { return time.Now().Unix() }

// ChatFilter selects a chat-list subset.
type ChatFilter string

const (
	FilterAll      ChatFilter = "all"
	FilterUnread   ChatFilter = "unread"
	FilterMentions ChatFilter = "mentions"
)

// EnsureChat inserts a chat row if missing, or refreshes mutable metadata
// (display name) if already present. Counters and read state are preserved.
func (s *Store) EnsureChat(ctx context.Context, c core.Chat) error {
	if c.UpdatedAt == 0 {
		c.UpdatedAt = now()
	}
	kind := string(c.Kind)
	if kind != string(core.KindGroup) {
		kind = string(core.KindDirect)
	}
	_, err := s.w.ExecContext(ctx, `
		INSERT INTO chats (jid, kind, display_name, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT (jid) DO UPDATE SET
			display_name = CASE
				-- A name is only adopted when it is non-empty, NOT an
				-- identifier form, and actually different from the current
				-- value (prevents rename churn on every history re-sync).
				WHEN excluded.display_name = ''            THEN chats.display_name
				WHEN excluded.display_name LIKE '%@%'     THEN chats.display_name
				WHEN excluded.display_name LIKE '+%'      THEN chats.display_name
				WHEN excluded.display_name LIKE 'Group %' THEN chats.display_name
				WHEN excluded.display_name = chats.display_name THEN chats.display_name
				ELSE excluded.display_name
			END,
			updated_at = excluded.updated_at`,
		c.JID, kind, c.DisplayName, c.UpdatedAt)
	if err != nil {
		return fmt.Errorf("storage: ensure chat %s: %w", c.JID, err)
	}
	return nil
}

func scanChat(row interface{ Scan(...any) error }) (*core.Chat, error) {
	var c core.Chat
	var kind string
	var lastTS sql.NullInt64
	var pin, mute, arch, work, star int
	err := row.Scan(&c.JID, &kind, &c.DisplayName, &lastTS, &c.LastMessageID, &c.LastPreview,
		&c.LastReadTS, &c.UnreadCount, &c.MentionedUnread,
		&pin, &mute, &arch, &work, &star, &c.UpdatedAt)
	if err != nil {
		return nil, err
	}
	c.Kind = core.ChatKind(kind)
	if c.DisplayName == "" {
		c.DisplayName = core.FallbackChatName(c.JID, c.Kind)
	}
	c.LastMessageTS = lastTS.Int64
	c.IsPinned, c.IsMuted, c.IsArchived, c.IsWork, c.IsStarred = pin != 0, mute != 0, arch != 0, work != 0, star != 0
	return &c, nil
}

const chatCols = `jid, kind, display_name, last_message_ts, last_message_id, last_preview,
	last_read_ts, unread_count, mentioned_unread,
	is_pinned, is_muted, is_archived, is_work, is_starred, updated_at`

// GetChat returns one chat or ErrNotFound.
func (s *Store) GetChat(ctx context.Context, jid string) (*core.Chat, error) {
	row := s.r.QueryRowContext(ctx, `SELECT `+chatCols+` FROM chats WHERE jid = ?`, jid)
	c, err := scanChat(row)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("storage: get chat: %w", err)
	}
	return c, nil
}

// ListChats pages the chat list by keyset cursor (last_message_ts DESC,
// jid DESC). beforeJID disambiguates timestamps shared by many chats (bulk
// history sync); empty beforeJID keeps the legacy bare-ts behavior.
func (s *Store) ListChats(ctx context.Context, limit int, before int64, beforeJID string, filter ChatFilter) ([]core.Chat, error) {
	if limit < 1 || limit > 200 {
		limit = 50
	}
	q := `SELECT ` + chatCols + ` FROM chats WHERE last_message_ts IS NOT NULL`
	args := []any{}
	if before > 0 {
		if beforeJID != "" {
			q += ` AND (last_message_ts < ? OR (last_message_ts = ? AND jid < ?))`
			args = append(args, before, before, beforeJID)
		} else {
			q += ` AND last_message_ts < ?`
			args = append(args, before)
		}
	}
	switch filter {
	case FilterUnread:
		q += ` AND unread_count > 0`
	case FilterMentions:
		q += ` AND mentioned_unread > 0`
	case FilterAll, "":
	default:
		return nil, fmt.Errorf("storage: unknown chat filter %q", filter)
	}
	q += ` ORDER BY last_message_ts DESC, jid DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.r.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("storage: list chats: %w", err)
	}
	defer rows.Close()
	// Non-nil even for zero rows: JSON null fails Codable decoding of the
	// client's non-optional arrays and drops the whole response (fresh
	// accounts would never leave the sidebar spinner).
	out := make([]core.Chat, 0, 64)
	for rows.Next() {
		c, err := scanChat(rows)
		if err != nil {
			return nil, fmt.Errorf("storage: scan chat: %w", err)
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}

// RecomputeUnreadCounters rebuilds the denormalized unread counters from
// the messages table. Counters are maintained by live ingest only, so they
// drift when messages are read on another device, re-synced as history
// newer than the read position, or ingested by an older build — recomputing
// at startup makes the Unread/Mentions filters self-healing.
func (s *Store) RecomputeUnreadCounters(ctx context.Context) error {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("storage: recompute begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `
		UPDATE chats SET
			unread_count = (SELECT COUNT(*) FROM messages m
				WHERE m.chat_jid = chats.jid AND m.from_me = 0
				  AND m.revoked = 0 AND m.timestamp > chats.last_read_ts),
			mentioned_unread = (SELECT COUNT(*) FROM messages m
				WHERE m.chat_jid = chats.jid AND m.from_me = 0
				  AND m.revoked = 0 AND m.has_mention = 1
				  AND m.timestamp > chats.last_read_ts)
		WHERE last_message_ts IS NOT NULL`); err != nil {
		return fmt.Errorf("storage: recompute counters: %w", err)
	}
	return tx.Commit()
}

// MergeLIDChats folds direct chats keyed by a peer's LID into their
// phone-number twin (idempotent; new writes are canonical since Normalize
// resolves chat LIDs). Returns the merged lid→pn pairs so callers can
// invalidate both JIDs. The phone row is created on demand so the FK never
// orphans moved messages; read position and the newer last-message
// projection carry over, and counters re-derive from the merged history.
func (s *Store) MergeLIDChats(ctx context.Context, lidToPN map[string]string) (map[string]string, error) {
	merged := map[string]string{}
	if len(lidToPN) == 0 {
		return merged, nil
	}
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("storage: merge lid chats begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var firstErr error
	for lid, pn := range lidToPN {
		if !strings.HasSuffix(lid, "@lid") || pn == "" || pn == lid {
			continue
		}
		var isDirect bool
		if err := tx.QueryRowContext(ctx,
			`SELECT kind = 'direct' FROM chats WHERE jid = ?`, lid).Scan(&isDirect); err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				continue // no LID chat row: nothing to fold
			}
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: merge lid chat %s: probe: %w", lid, err)
			}
			continue // one bad mapping must not abort the rest
		}
		if !isDirect {
			continue
		}
		if _, err := tx.ExecContext(ctx, `
			INSERT INTO chats (jid, kind, display_name, updated_at)
			VALUES (?, 'direct', COALESCE((SELECT display_name FROM chats WHERE jid = ?), ''), ?)
			ON CONFLICT (jid) DO NOTHING`,
			pn, lid, now()); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: merge lid chat %s: ensure phone row: %w", lid, err)
			}
			continue
		}
		// The same logical message can exist under both keys (stored before
		// the mapping was learned): drop the LID twin first so the move
		// below cannot fire UNIQUE(chat_jid, sender_jid, message_id).
		if _, err := tx.ExecContext(ctx, `
			DELETE FROM messages WHERE chat_jid = ? AND EXISTS (
				SELECT 1 FROM messages p
				WHERE p.chat_jid = ? AND p.message_id = messages.message_id
				  AND p.sender_jid = messages.sender_jid)`, lid, pn); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: merge lid chat %s: dedupe: %w", lid, err)
			}
			continue
		}
		if _, err := tx.ExecContext(ctx,
			`UPDATE messages SET chat_jid = ? WHERE chat_jid = ?`, pn, lid); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: merge lid chat %s: move: %w", lid, err)
			}
			continue
		}
		// FTS stores a chat_jid copy but its triggers only watch text
		// updates — sync it explicitly so the index never disagrees. Runs
		// AFTER the move, so the subquery must match the rows' NEW key
		// (matching on `lid` here would find zero rows — a no-op).
		// chat_jid is UNINDEXED in the FTS table, so the WHERE must come
		// from the rowid set, not a full FTS scan.
		if _, err := tx.ExecContext(ctx,
			`UPDATE messages_fts SET chat_jid = ?
			 WHERE rowid IN (SELECT id FROM messages WHERE chat_jid = ?)`, pn, pn); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: merge lid chat %s: fts: %w", lid, err)
			}
			continue
		}
		// Carry the read position, the newer last-message projection, and
		// the work flags from the LID row before it goes away — losing the
		// snooze/star/work flags would resurrect a folded conversation in
		// the inbox or drop its star.
		if _, err := tx.ExecContext(ctx, `
			UPDATE chats AS dst SET
				last_read_ts    = MAX(dst.last_read_ts, src.last_read_ts),
				last_message_ts = CASE WHEN src.last_message_ts IS NOT NULL
					AND (dst.last_message_ts IS NULL OR src.last_message_ts > dst.last_message_ts)
					THEN src.last_message_ts ELSE dst.last_message_ts END,
				last_message_id = CASE WHEN src.last_message_ts IS NOT NULL
					AND (dst.last_message_ts IS NULL OR src.last_message_ts > dst.last_message_ts)
					THEN src.last_message_id ELSE dst.last_message_id END,
				last_preview    = CASE WHEN src.last_message_ts IS NOT NULL
					AND (dst.last_message_ts IS NULL OR src.last_message_ts > dst.last_message_ts)
					THEN src.last_preview ELSE dst.last_preview END,
				snoozed_until   = MAX(COALESCE(dst.snoozed_until, 0), COALESCE(src.snoozed_until, 0)),
				is_starred      = MAX(COALESCE(dst.is_starred, 0), COALESCE(src.is_starred, 0)),
				is_work         = MAX(COALESCE(dst.is_work, 0), COALESCE(src.is_work, 0)),
				updated_at = ?
			FROM (SELECT last_read_ts, last_message_ts, last_message_id, last_preview,
			             snoozed_until, is_starred, is_work
			      FROM chats WHERE jid = ?) AS src
			WHERE dst.jid = ?`, now(), lid, pn); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: merge lid chat %s: carry state: %w", lid, err)
			}
			continue
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM chats WHERE jid = ?`, lid); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: merge lid chat %s: drop row: %w", lid, err)
			}
			continue
		}
		merged[lid] = pn
	}
	if err := tx.Commit(); err != nil {
		return merged, fmt.Errorf("storage: merge lid chats commit: %w", err)
	}
	if firstErr != nil {
		return merged, firstErr
	}
	// Counters are denormalized: re-derive from the merged history. Only
	// when something actually merged — the recompute costs hundreds of ms
	// on an unread-heavy account and holds the single writer, while the
	// names pass calls this whenever any @lid traffic re-arms it.
	if len(merged) > 0 {
		if err := s.RecomputeUnreadCounters(ctx); err != nil {
			return merged, fmt.Errorf("storage: merge lid chats recompute: %w", err)
		}
	}
	return merged, nil
}

// MarkChatRead zeroes unread counters and advances the read position.
// Counters are zeroed only when the receipt advances to the current read
// position: read_self receipts can arrive out of order after a reconnect,
// and an older-position receipt must not hide newer unread traffic.
func (s *Store) MarkChatRead(ctx context.Context, jid string, upToTS int64) error {
	if _, err := s.w.ExecContext(ctx, `
		UPDATE chats SET
			unread_count = CASE WHEN ? >= COALESCE(last_read_ts, 0) THEN 0 ELSE unread_count END,
			mentioned_unread = CASE WHEN ? >= COALESCE(last_read_ts, 0) THEN 0 ELSE mentioned_unread END,
			last_read_ts = MAX(last_read_ts, ?),
			updated_at = ?
		WHERE jid = ?`, upToTS, upToTS, upToTS, now(), jid); err != nil {
		return fmt.Errorf("storage: mark read: %w", err)
	}
	return nil
}

// UnreadRef identifies one unread incoming message for read receipts.
type UnreadRef struct {
	MessageID string
	SenderJID string
	TS        int64
}

// UnreadIncoming lists unread incoming messages of a chat (newest first).
func (s *Store) UnreadIncoming(ctx context.Context, jid string, limit int) ([]UnreadRef, error) {
	if limit < 1 {
		limit = 100
	}
	rows, err := s.r.QueryContext(ctx, `
		SELECT message_id, sender_jid, timestamp FROM messages
		WHERE chat_jid = ? AND from_me = 0 AND revoked = 0
		  AND timestamp > (SELECT last_read_ts FROM chats WHERE jid = ?)
		ORDER BY timestamp DESC LIMIT ?`, jid, jid, limit)
	if err != nil {
		return nil, fmt.Errorf("storage: unread incoming: %w", err)
	}
	defer rows.Close()
	var out []UnreadRef
	for rows.Next() {
		var u UnreadRef
		if err := rows.Scan(&u.MessageID, &u.SenderJID, &u.TS); err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, rows.Err()
}

// MaxUnreadIncomingTS is the newest unread incoming timestamp (0 = none).
func (s *Store) MaxUnreadIncomingTS(ctx context.Context, jid string) (int64, error) {
	var ts sql.NullInt64
	if err := s.r.QueryRowContext(ctx, `
		SELECT MAX(timestamp) FROM messages
		WHERE chat_jid = ? AND from_me = 0 AND revoked = 0
		  AND timestamp > (SELECT COALESCE(last_read_ts, 0) FROM chats WHERE jid = ?)`,
		jid, jid).Scan(&ts); err != nil {
		return 0, fmt.Errorf("storage: max unread ts: %w", err)
	}
	return ts.Int64, nil
}

// SetOwnJID records the logged-in account.
func (s *Store) SetOwnJID(ctx context.Context, jid string) error {
	_, err := s.w.ExecContext(ctx, `
		INSERT INTO accounts (jid, platform, created_at, last_connected_at)
		VALUES (?, '', ?, ?)
		ON CONFLICT (jid) DO UPDATE SET last_connected_at = excluded.last_connected_at`,
		jid, now(), now())
	if err != nil {
		return fmt.Errorf("storage: set own jid: %w", err)
	}
	return nil
}

// RefreshDirectChatNames backfills direct-chat display names from the
// contacts table, preferring full name over push name over business name.
// Groups are untouched (their names come from group metadata). Empty contact
// fields never overwrite an existing name. Only rows whose name actually
// changes are rewritten; their jids are returned so the caller can emit
// chat.updated events — without this pass, a chat titled with a push name
// would never pick up the address-book name that arrives later via the
// contacts app state.
func (s *Store) RefreshDirectChatNames(ctx context.Context) ([]string, error) {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("storage: refresh names begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	rows, err := tx.QueryContext(ctx, `
		SELECT chats.jid
		FROM chats JOIN contacts c ON chats.jid = c.jid
		WHERE chats.kind = 'direct'
		  AND chats.display_name != COALESCE(NULLIF(c.full_name, ''), NULLIF(c.push_name, ''),
			NULLIF(c.business_name, ''), chats.display_name)`)
	if err != nil {
		return nil, fmt.Errorf("storage: refresh names select: %w", err)
	}
	var changed []string
	for rows.Next() {
		var jid string
		if err := rows.Scan(&jid); err != nil {
			_ = rows.Close()
			return nil, fmt.Errorf("storage: refresh names scan: %w", err)
		}
		changed = append(changed, jid)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, fmt.Errorf("storage: refresh names rows: %w", err)
	}
	_ = rows.Close()
	if len(changed) == 0 {
		return nil, tx.Commit()
	}

	if _, err := tx.ExecContext(ctx, `
		UPDATE chats SET
			display_name = COALESCE(NULLIF(c.full_name, ''), NULLIF(c.push_name, ''),
				NULLIF(c.business_name, ''), chats.display_name),
			updated_at = ?
		FROM contacts c
		WHERE chats.kind = 'direct' AND chats.jid = c.jid`, now()); err != nil {
		return nil, fmt.Errorf("storage: refresh chat names: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("storage: refresh names commit: %w", err)
	}
	return changed, nil
}

// MaxTimestampOf returns the newest timestamp among the given message ids in
// a chat (0 when none match) — used to advance the read position from
// read-self receipts.
func (s *Store) MaxTimestampOf(ctx context.Context, chatJID string, messageIDs []string) (int64, error) {
	if len(messageIDs) == 0 {
		return 0, nil
	}
	placeholders := strings.Repeat("?,", len(messageIDs))
	placeholders = placeholders[:len(placeholders)-1]
	args := make([]any, 0, len(messageIDs)+1)
	args = append(args, chatJID)
	for _, id := range messageIDs {
		args = append(args, id)
	}
	var ts int64
	err := s.r.QueryRowContext(ctx, `
		SELECT COALESCE(MAX(timestamp), 0) FROM messages
		WHERE chat_jid = ? AND message_id IN (`+placeholders+`)`, args...).Scan(&ts)
	if err != nil {
		return 0, fmt.Errorf("storage: max timestamp: %w", err)
	}
	return ts, nil
}

// RenameChat sets a chat's display name unconditionally (name resolution).
func (s *Store) RenameChat(ctx context.Context, jid, name string) error {
	if name == "" {
		return nil
	}
	_, err := s.w.ExecContext(ctx,
		`UPDATE chats SET display_name = ?, updated_at = ? WHERE jid = ?`,
		name, now(), jid)
	if err != nil {
		return fmt.Errorf("storage: rename chat: %w", err)
	}
	return nil
}

// SearchChatsByName matches chat display names by escaped substring over the
// whole chats table. ListChats clamps limits (keyset paging for the UI), so
// search needs this dedicated scan — the table is account-bounded (hundreds
// to low thousands of rows), which a LIKE scan handles in well under a ms.
func (s *Store) SearchChatsByName(ctx context.Context, query string, limit int) ([]core.Chat, error) {
	if limit < 1 {
		limit = 25
	}
	q := `SELECT ` + chatCols + ` FROM chats`
	var args []any
	if query != "" {
		pat := "%" + escapeLike(query) + "%"
		q += ` WHERE display_name LIKE ? ESCAPE '\'`
		args = append(args, pat)
	}
	q += ` ORDER BY last_message_ts DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.r.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("storage: search chats: %w", err)
	}
	defer rows.Close()
	// Non-nil even for zero rows: JSON null fails Codable decoding of the
	// client's non-optional arrays and drops the whole response.
	out := make([]core.Chat, 0, 64)
	for rows.Next() {
		c, err := scanChat(rows)
		if err != nil {
			return nil, fmt.Errorf("storage: scan chat: %w", err)
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}

// ListChatsForNames returns every chat row regardless of message presence —
// name resolution must also reach chats whose history batch failed early.
func (s *Store) ListChatsForNames(ctx context.Context) ([]core.Chat, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT `+chatCols+` FROM chats ORDER BY last_message_ts DESC`)
	if err != nil {
		return nil, fmt.Errorf("storage: list chats for names: %w", err)
	}
	defer rows.Close()
	var out []core.Chat
	for rows.Next() {
		c, err := scanChat(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, *c)
	}
	return out, rows.Err()
}
