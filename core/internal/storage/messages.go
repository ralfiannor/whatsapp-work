package storage

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

const msgCols = `m.id, m.message_id, m.chat_jid, m.sender_jid, m.from_me, m.timestamp, m.kind,
	m.raw_kind, m.text, m.reply_to_id, m.reply_to_sender, m.quoted_text,
	m.has_mention, m.mentioned_jids, m.receipt_status, m.revoked, m.forwarded, m.edited_ts,
	m.created_at, m.updated_at,
	COALESCE(ls.starred, 0), COALESCE(ls.done, 0)`

// localStateJoin attaches the per-message work state (starred/done) to a
// message query using msgCols.
const localStateJoin = ` LEFT JOIN local_message_state ls ON ls.message_id = m.id`

const mediaCols = `md.id, md.kind, md.mime, md.size, md.filename, md.width, md.height, md.duration_ms,
	md.state, md.local_path`

// InsertMessage inserts one message idempotently (UNIQUE chat+sender+message_id)
// and updates chat counters, preview, and the media row in one transaction.
//
// Counter rules (docs/schema.md): only live-source incoming messages newer
// than the chat's read position bump unread counts; history backfill never
// marks anything unread. Returns whether the row was newly inserted; m.ID is
// filled either way.
func (s *Store) InsertMessage(ctx context.Context, m *core.Message) (isNew bool, err error) {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return false, fmt.Errorf("storage: insert begin: %w", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()
	isNew, err = s.insertMessageTx(ctx, tx, m)
	if err != nil {
		return false, err
	}
	if err = tx.Commit(); err != nil {
		return false, fmt.Errorf("storage: insert commit: %w", err)
	}
	return isNew, nil
}

// InsertMessages ingests a history batch inside shared transactions, one per
// chunk. Same semantics as InsertMessage; history rows never bump unread
// counters (that rule lives in insertMessageTx). Returns newly inserted rows.
func (s *Store) InsertMessages(ctx context.Context, msgs []core.Message) (inserted int, err error) {
	const chunkSize = 500
	for start := 0; start < len(msgs); start += chunkSize {
		end := start + chunkSize
		if end > len(msgs) {
			end = len(msgs)
		}
		chunk := msgs[start:end]
		tx, txErr := s.w.BeginTx(ctx, nil)
		if txErr != nil {
			return inserted, fmt.Errorf("storage: batch begin: %w", txErr)
		}
		chunkInserted := 0
		for i := range chunk {
			isNew, insErr := s.insertMessageTx(ctx, tx, &chunk[i])
			if insErr != nil {
				_ = tx.Rollback()
				return inserted, insErr
			}
			if isNew {
				chunkInserted++
			}
		}
		if err = tx.Commit(); err != nil {
			return inserted, fmt.Errorf("storage: batch commit: %w", err)
		}
		inserted += chunkInserted
	}
	return inserted, nil
}

// insertMessageTx does the per-message work inside a caller-owned tx.
func (s *Store) insertMessageTx(ctx context.Context, tx *sql.Tx, m *core.Message) (isNew bool, err error) {
	if m.SenderJID == "" {
		m.SenderJID = m.ChatJID
	}
	if m.MentionedJIDs == nil {
		m.MentionedJIDs = []string{}
	}
	if m.CreatedAt == 0 {
		m.CreatedAt = now()
	}
	m.UpdatedAt = now()
	mentioned, _ := json.Marshal(m.MentionedJIDs)

	res, err := tx.ExecContext(ctx, `
		INSERT INTO messages (
			message_id, chat_jid, sender_jid, from_me, timestamp, kind, raw_kind, text,
			reply_to_id, reply_to_sender, quoted_text, has_mention, mentioned_jids,
			receipt_status, source, revoked, forwarded, created_at, updated_at
		) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (chat_jid, sender_jid, message_id) DO NOTHING`,
		m.MessageID, m.ChatJID, m.SenderJID, m.FromMe, m.Timestamp, string(m.Kind), m.RawKind, m.Text,
		m.ReplyToID, m.ReplyToSender, m.QuotedText, m.HasMention, string(mentioned),
		m.ReceiptStatus, m.Source, m.Revoked, m.Forwarded, m.CreatedAt, m.UpdatedAt)
	if err != nil {
		return false, fmt.Errorf("storage: insert message %s: %w", m.MessageID, err)
	}

	if n, _ := res.RowsAffected(); n == 1 {
		isNew = true
		if m.ID, err = res.LastInsertId(); err != nil {
			return false, fmt.Errorf("storage: message rowid: %w", err)
		}
	} else {
		if err = tx.QueryRowContext(ctx, `
			SELECT id FROM messages WHERE chat_jid = ? AND sender_jid = ? AND message_id = ?`,
			m.ChatJID, m.SenderJID, m.MessageID).Scan(&m.ID); err != nil {
			return false, fmt.Errorf("storage: existing message rowid: %w", err)
		}
		// A re-delivery may carry richer content than the first attempt
		// (e.g. retry after an encryption-envelope-only skdm message): refresh
		// text, and escalate an "unsupported" row to the real kind — never
		// downgrade a classified row. Mention/reply/forwarded metadata follows
		// the same escalate-only rule: a full re-delivery carries the real
		// ContextInfo, and dropping it here left mention-flagged content
		// permanently invisible to the Mentions filter and the inbox.
		if m.Text != "" || m.Kind != core.KindUnsupported || m.HasMention || m.ReplyToID != "" {
			if _, err = tx.ExecContext(ctx, `
				UPDATE messages SET
					text = CASE WHEN ? != '' THEN ? ELSE text END,
					kind = CASE WHEN kind = 'unsupported' AND ? != 'unsupported' THEN ? ELSE kind END,
					raw_kind = CASE WHEN ? != 'unsupported' THEN '' ELSE raw_kind END,
					has_mention = CASE WHEN ? != 0 THEN 1 ELSE has_mention END,
					mentioned_jids = CASE WHEN ? != '[]' THEN ? ELSE mentioned_jids END,
					reply_to_id = CASE WHEN ? != '' THEN ? ELSE reply_to_id END,
					reply_to_sender = CASE WHEN ? != '' THEN ? ELSE reply_to_sender END,
					quoted_text = CASE WHEN ? != '' THEN ? ELSE quoted_text END,
					forwarded = CASE WHEN ? != 0 THEN 1 ELSE forwarded END,
					updated_at = ?
				WHERE id = ?`,
				m.Text, m.Text, string(m.Kind), string(m.Kind), string(m.Kind),
				m.HasMention, string(mentioned), string(mentioned),
				m.ReplyToID, m.ReplyToID,
				m.ReplyToSender, m.ReplyToSender,
				m.QuotedText, m.QuotedText,
				m.Forwarded, m.UpdatedAt, m.ID); err != nil {
				return false, fmt.Errorf("storage: update message content: %w", err)
			}
		}
	}

	if isNew {
		if m.Source == "live" && !m.FromMe {
			mention := 0
			if m.HasMention {
				mention = 1
			}
			if _, err = tx.ExecContext(ctx, `
				UPDATE chats SET
					unread_count = unread_count + 1,
					mentioned_unread = mentioned_unread + ?
				WHERE jid = ? AND ? > last_read_ts`,
				mention, m.ChatJID, m.Timestamp); err != nil {
				return false, fmt.Errorf("storage: bump unread: %w", err)
			}
			// The inbox reads pending items from local_message_state — a
			// live incoming row must exist there from birth (done=0).
			if _, err = tx.ExecContext(ctx, `
				INSERT INTO local_message_state (message_id, done, snoozed_until, starred, priority)
				VALUES (?, 0, NULL, 0, 0)
				ON CONFLICT (message_id) DO NOTHING`, m.ID); err != nil {
				return false, fmt.Errorf("storage: inbox state row: %w", err)
			}
		}
		if _, err = tx.ExecContext(ctx, `
			UPDATE chats SET
				last_message_ts = ?, last_message_id = ?, last_preview = ?, updated_at = ?
			WHERE jid = ? AND (last_message_ts IS NULL OR last_message_ts <= ?)`,
			m.Timestamp, m.MessageID, previewOf(m), m.UpdatedAt, m.ChatJID, m.Timestamp); err != nil {
			return false, fmt.Errorf("storage: advance preview: %w", err)
		}
	}

	if m.Media != nil {
		if err = insertMedia(ctx, tx, m.ID, m.Media); err != nil {
			return false, err
		}
	}
	return isNew, nil
}

func insertMedia(ctx context.Context, tx *sql.Tx, rowID int64, md *core.MediaMeta) error {
	if md.ID == "" {
		if len(md.FileEncSHA256) > 0 {
			md.ID = hex.EncodeToString(md.FileEncSHA256)
		} else {
			md.ID = fmt.Sprintf("row-%d", rowID)
		}
	}
	if md.State == "" {
		md.State = "not_downloaded"
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO media (
			id, message_id, kind, mime, size, filename, width, height, duration_ms, caption,
			url, direct_path, media_key, file_sha256, file_enc_sha256, proto, state, updated_at
		) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (message_id) DO UPDATE SET
			url = excluded.url,
			direct_path = excluded.direct_path,
			-- re-delivered messages must not reset a finished download
			state = CASE WHEN media.state = 'downloaded' THEN media.state ELSE excluded.state END,
			updated_at = excluded.updated_at`,
		md.ID, rowID, md.Kind, md.MIME, md.Size, md.Filename, md.Width, md.Height, md.DurationMS, "",
		md.URL, md.DirectPath, md.MediaKey, md.FileSHA256, md.FileEncSHA256, md.Proto, md.State, now())
	if err != nil {
		return fmt.Errorf("storage: insert media: %w", err)
	}
	return nil
}

// previewOf derives the chat-list preview line for a message. Remote text
// is unbounded until Normalize clamps it, but previews must also survive
// re-derivation from older rows — clamp here so a hostile message can never
// pin megabytes into chats.last_preview (re-serialized on every /chats
// fetch and chat.updated event).
func previewOf(m *core.Message) string {
	return truncatePreview(previewText(m))
}

func previewText(m *core.Message) string {
	if m.Revoked {
		return ""
	}
	// A re-delivered row may still carry its kind label but always carries
	// text — the text is the better preview either way.
	if m.Kind == core.KindUnsupported {
		if strings.TrimSpace(m.Text) != "" {
			return m.Text
		}
		return UnsupportedLabel(m.RawKind)
	}
	switch m.Kind {
	case core.KindText, core.KindSystem:
		return m.Text
	case core.KindImage:
		return captionOr(m.Text, "Photo")
	case core.KindVideo:
		return captionOr(m.Text, "Video")
	case core.KindAudio:
		return "Audio message"
	case core.KindSticker:
		return "Sticker"
	case core.KindDocument:
		if m.Media != nil && m.Media.Filename != "" {
			return m.Media.Filename
		}
		return "Document"
	case core.KindUnsupported:
		return "Unsupported message"
	default:
		return captionOr(m.Text, "Message")
	}
}

func captionOr(caption, fallback string) string {
	if strings.TrimSpace(caption) != "" {
		return caption
	}
	return fallback
}

// truncatePreview bounds a preview line to 96 runes (the same width the
// v5/v7/v9 migrations clamp historical previews to), never splitting one.
func truncatePreview(s string) string {
	if len(s) <= 96 {
		return s
	}
	r := []rune(s)
	if len(r) <= 96 {
		return s
	}
	return string(r[:96])
}

func scanMessages(rows *sql.Rows) ([]core.Message, error) {
	// Non-nil even for zero rows: JSON null fails Codable decoding of the
	// client's non-optional arrays and drops the whole response.
	out := make([]core.Message, 0, 128)
	for rows.Next() {
		var m core.Message
		var kind string
		var fromMe, hasMention, revoked, forwarded, starred, done int
		var mentionedJSON string
		var replyToID, replyToSender, quotedText, receiptStatus, rawKind string
		var editedTS sql.NullInt64
		var mediaID, mediaKind, mediaMIME, mediaState, mediaLocal sql.NullString
		var mediaSize, mediaW, mediaH, mediaDur sql.NullInt64
		var mediaFilename sql.NullString

		err := rows.Scan(&m.ID, &m.MessageID, &m.ChatJID, &m.SenderJID, &fromMe, &m.Timestamp, &kind,
			&rawKind, &m.Text, &replyToID, &replyToSender, &quotedText,
			&hasMention, &mentionedJSON, &receiptStatus, &revoked, &forwarded, &editedTS,
			&m.CreatedAt, &m.UpdatedAt, &starred, &done,
			&mediaID, &mediaKind, &mediaMIME, &mediaSize, &mediaFilename, &mediaW, &mediaH, &mediaDur,
			&mediaState, &mediaLocal)
		if err != nil {
			return nil, fmt.Errorf("storage: scan message: %w", err)
		}
		m.Kind = core.MessageKind(kind)
		m.RawKind = rawKind
		m.FromMe = fromMe != 0
		m.HasMention = hasMention != 0
		m.Revoked = revoked != 0
		m.Forwarded = forwarded != 0
		m.Starred = starred != 0
		m.Done = done != 0
		m.ReplyToID, m.ReplyToSender, m.QuotedText = replyToID, replyToSender, quotedText
		m.ReceiptStatus = receiptStatus
		if editedTS.Valid {
			m.EditedTS = editedTS.Int64
		}
		_ = json.Unmarshal([]byte(mentionedJSON), &m.MentionedJIDs)
		if mediaID.Valid {
			md := &core.MediaMeta{
				ID: mediaID.String, Kind: mediaKind.String, MIME: mediaMIME.String,
				Size: mediaSize.Int64, Filename: mediaFilename.String,
				Width: int(mediaW.Int64), Height: int(mediaH.Int64),
				DurationMS: mediaDur.Int64, State: mediaState.String, LocalPath: mediaLocal.String,
			}
			m.Media = md
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// ListMessages pages a chat's history by keyset cursor (timestamp,id DESC).
// beforeTS/beforeID of 0 start from the newest. Max page 200.
func (s *Store) ListMessages(ctx context.Context, chatJID string, beforeTS, beforeID int64, limit int) ([]core.Message, error) {
	if limit < 1 || limit > 200 {
		limit = 50
	}
	q := `SELECT ` + msgCols + `, ` + mediaCols + `
		FROM messages m` + localStateJoin + `
		LEFT JOIN media md ON md.message_id = m.id
		WHERE m.chat_jid = ?`
	args := []any{chatJID}
	if beforeTS > 0 {
		q += ` AND (m.timestamp < ? OR (m.timestamp = ? AND m.id < ?))`
		args = append(args, beforeTS, beforeTS, beforeID)
	}
	q += ` ORDER BY m.timestamp DESC, m.id DESC LIMIT ?`
	args = append(args, limit)

	rows, err := s.r.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("storage: list messages: %w", err)
	}
	defer rows.Close()
	msgs, err := scanMessages(rows)
	if err != nil {
		return nil, err
	}
	s.attachReactions(ctx, msgs)
	return msgs, nil
}

// GetMessage returns one message by local row id.
func (s *Store) GetMessage(ctx context.Context, rowID int64) (*core.Message, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT `+msgCols+`, `+mediaCols+`
		FROM messages m`+localStateJoin+`
		LEFT JOIN media md ON md.message_id = m.id
		WHERE m.id = ?`, rowID)
	if err != nil {
		return nil, fmt.Errorf("storage: get message: %w", err)
	}
	defer rows.Close()
	msgs, err := scanMessages(rows)
	if err != nil {
		return nil, err
	}
	if len(msgs) == 0 {
		return nil, ErrNotFound
	}
	return &msgs[0], nil
}

// ReceiptUpdate is one message whose receipt status changed.
type ReceiptUpdate struct {
	RowID     int64
	MessageID string
	Status    string
}

// UpdateReceiptStatus advances outgoing messages' delivery state and returns
// the affected rows (for message.updated events). Incoming messages are
// ignored — their read state lives on chats.last_read_ts.
func (s *Store) UpdateReceiptStatus(ctx context.Context, chatJID, senderJID string, messageIDs []string, status string) ([]ReceiptUpdate, error) {
	if len(messageIDs) == 0 {
		return nil, nil
	}
	placeholders := strings.Repeat("?,", len(messageIDs))
	placeholders = placeholders[:len(placeholders)-1]
	args := make([]any, 0, len(messageIDs)+3)
	args = append(args, chatJID, senderJID)
	for _, id := range messageIDs {
		args = append(args, id)
	}

	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("storage: receipts begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	rank := receiptRank(status)
	rows, err := tx.QueryContext(ctx, `
		SELECT id, message_id FROM messages
		WHERE chat_jid = ? AND sender_jid = ? AND from_me = 1
		  AND message_id IN (`+placeholders+`) AND (`+receiptRankExpr+`) < ?`,
		append(args, rank)...)
	if err != nil {
		return nil, fmt.Errorf("storage: receipts select: %w", err)
	}
	var updates []ReceiptUpdate
	var updArgs []any
	for rows.Next() {
		var u ReceiptUpdate
		if err := rows.Scan(&u.RowID, &u.MessageID); err != nil {
			rows.Close()
			return nil, err
		}
		u.Status = status
		updates = append(updates, u)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(updates) > 0 {
		updPH := strings.Repeat("?,", len(updates))
		updPH = updPH[:len(updPH)-1]
		updArgs = append(updArgs, status, now())
		for _, u := range updates {
			updArgs = append(updArgs, u.RowID)
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE messages SET receipt_status = ?, updated_at = ?
			WHERE from_me = 1 AND id IN (`+updPH+`) AND (`+receiptRankExpr+`) < ?`,
			append(updArgs, rank)...); err != nil {
			return nil, fmt.Errorf("storage: receipts update: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("storage: receipts commit: %w", err)
	}
	return updates, nil
}

// receiptRankExpr orders delivery states inside SQL; ” counts lowest so an
// empty status never blocks an incoming receipt.
const receiptRankExpr = `CASE receipt_status WHEN 'sent' THEN 1 WHEN 'delivered' THEN 2 WHEN 'read' THEN 3 ELSE 0 END`

func receiptRank(status string) int {
	switch status {
	case "sent":
		return 1
	case "delivered":
		return 2
	case "read":
		return 3
	default:
		return 0
	}
}

// SetRevoked marks a message deleted-for-everyone and clears the chat-list
// preview when this message was the newest in its chat.
func (s *Store) SetRevoked(ctx context.Context, chatJID, messageID, senderJID string, ts int64) error {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("storage: revoke begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	res, err := tx.ExecContext(ctx, `
		UPDATE messages SET revoked = 1, text = '', updated_at = ?
		WHERE chat_jid = ? AND message_id = ? AND sender_jid = ? AND revoked = 0`,
		now(), chatJID, messageID, senderJID)
	if err != nil {
		return fmt.Errorf("storage: revoke: %w", err)
	}
	if n, _ := res.RowsAffected(); n > 0 {
		// The live insert already bumped the unread counters, and the
		// startup recompute excludes revoked rows — decrement here or the
		// badge shows unread traffic that isn't there until restart.
		var fromMe, hasMention, msgTS, lastRead int64
		if err := tx.QueryRowContext(ctx, `
			SELECT m.from_me, m.has_mention, m.timestamp, COALESCE(c.last_read_ts, 0)
			FROM messages m JOIN chats c ON c.jid = m.chat_jid
			WHERE m.chat_jid = ? AND m.message_id = ? AND m.sender_jid = ?`,
			chatJID, messageID, senderJID).Scan(&fromMe, &hasMention, &msgTS, &lastRead); err == nil {
			if fromMe == 0 && msgTS > lastRead {
				if _, err := tx.ExecContext(ctx, `
					UPDATE chats SET
						unread_count = MAX(unread_count - 1, 0),
						mentioned_unread = CASE WHEN ? > 0 THEN MAX(mentioned_unread - 1, 0) ELSE mentioned_unread END,
						updated_at = ?
					WHERE jid = ?`, hasMention, now(), chatJID); err != nil {
					return fmt.Errorf("storage: revoke counters: %w", err)
				}
			}
		}
		if _, err := tx.ExecContext(ctx, `
			UPDATE chats SET last_preview = '', updated_at = ?
			WHERE jid = ? AND last_message_id = ?`, now(), chatJID, messageID); err != nil {
			return fmt.Errorf("storage: revoke preview: %w", err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("storage: revoke commit: %w", err)
	}
	return nil
}

// SetEdited applies an edit to an existing message. The edited payload is
// authoritative for mention metadata: an edit can add (or drop) mentions, so
// the flag and the JID list are set, not escalated.
func (s *Store) SetEdited(ctx context.Context, chatJID, senderJID, messageID, newText string,
	editedTS int64, hasMention bool, mentionedJIDs []string) error {
	if mentionedJIDs == nil {
		mentionedJIDs = []string{}
	}
	mentioned, _ := json.Marshal(mentionedJIDs)
	// An empty text means the edit payload carried no text we understand
	// (e.g. a media caption edit whose payload is the media message itself)
	// — keep the stored text AND its mention metadata instead of wiping the
	// caption and its FTS row / mention flag.
	if _, err := s.w.ExecContext(ctx, `
		UPDATE messages SET
			text = CASE WHEN ? = '' THEN text ELSE ? END,
			edited_ts = ?,
			has_mention = CASE WHEN ? = '' THEN has_mention ELSE ? END,
			mentioned_jids = CASE WHEN ? = '' THEN mentioned_jids ELSE ? END,
			updated_at = ?
		WHERE chat_jid = ? AND sender_jid = ? AND message_id = ?`,
		newText, newText, editedTS,
		newText, hasMention,
		newText, string(mentioned),
		now(), chatJID, senderJID, messageID); err != nil {
		return fmt.Errorf("storage: edit: %w", err)
	}
	return nil
}

// QuotedTextOf returns a display snippet for the message a reply points
// at (text, or an honest kind label for media). Empty string when the
// original is not stored locally (older than history) — the UI then shows
// the reply without a preview.
func (s *Store) QuotedTextOf(ctx context.Context, chatJID, messageID string) (string, error) {
	var text sql.NullString
	var kind, rawKind string
	err := s.r.QueryRowContext(ctx, `
		SELECT text, kind, raw_kind FROM messages
		WHERE chat_jid = ? AND message_id = ?
		ORDER BY id DESC LIMIT 1`, chatJID, messageID).Scan(&text, &kind, &rawKind)
	if errors.Is(err, sql.ErrNoRows) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("storage: quoted text: %w", err)
	}
	if text.Valid && strings.TrimSpace(text.String) != "" {
		return text.String, nil
	}
	switch kind {
	case "image":
		return "Photo", nil
	case "video":
		return "Video", nil
	case "audio":
		return "Audio message", nil
	case "sticker":
		return "Sticker", nil
	case "document":
		return "Document", nil
	case "unsupported":
		return UnsupportedLabel(rawKind), nil
	default:
		return "", nil
	}
}

// LookupMessageRow resolves a chat+message_id to the local row id.
func (s *Store) LookupMessageRow(ctx context.Context, chatJID, messageID string) (int64, error) {
	var id int64
	err := s.r.QueryRowContext(ctx, `
		SELECT id FROM messages WHERE chat_jid = ? AND message_id = ?
		ORDER BY id DESC LIMIT 1`,
		chatJID, messageID).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, ErrNotFound
	}
	if err != nil {
		return 0, fmt.Errorf("storage: lookup message: %w", err)
	}
	return id, nil
}

// UpsertReaction stores (or removes, when emoji == "") a reaction row.
func (s *Store) UpsertReaction(ctx context.Context, messageRowID int64, reactorJID, emoji string, ts int64) error {
	if emoji == "" {
		if _, err := s.w.ExecContext(ctx,
			`DELETE FROM reactions WHERE message_id = ? AND reactor_jid = ?`,
			messageRowID, reactorJID); err != nil {
			return fmt.Errorf("storage: delete reaction: %w", err)
		}
		return nil
	}
	if _, err := s.w.ExecContext(ctx, `
		INSERT INTO reactions (message_id, reactor_jid, emoji, timestamp) VALUES (?,?,?,?)
		ON CONFLICT (message_id, reactor_jid) DO UPDATE SET emoji = excluded.emoji, timestamp = excluded.timestamp`,
		messageRowID, reactorJID, emoji, ts); err != nil {
		return fmt.Errorf("storage: upsert reaction: %w", err)
	}
	return nil
}

// RewriteSenderJIDs canonicalizes LID sender JIDs to phone JIDs across
// existing rows (idempotent; new writes are already canonical).
func (s *Store) RewriteSenderJIDs(ctx context.Context, lidToPN map[string]string) (int64, error) {
	if len(lidToPN) == 0 {
		return 0, nil
	}
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("storage: rewrite senders begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var total int64
	var firstErr error
	for lid, pn := range lidToPN {
		if !strings.HasSuffix(lid, "@lid") || pn == "" {
			continue
		}
		// The same logical message is often stored twice: once early (raw
		// LID sender, before the mapping was learned) and once canonical.
		// Deleting the LID twin first keeps the rewrite below from hitting
		// UNIQUE(chat, sender, message_id) — which previously aborted the
		// whole pass and left hundreds of duplicates behind.
		if _, err := tx.ExecContext(ctx, `
			DELETE FROM messages WHERE sender_jid = ? AND EXISTS (
				SELECT 1 FROM messages p
				WHERE p.chat_jid = messages.chat_jid
				  AND p.message_id = messages.message_id
				  AND p.sender_jid = ?)`, lid, pn); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: dedupe lid sender %s: %w", lid, err)
			}
			continue // one bad mapping must not abort the rest
		}
		// NOT EXISTS guard: immune to twins inserted between the map build
		// and this tx (concurrent live ingest) — those are next pass's food.
		res, err := tx.ExecContext(ctx, `
			UPDATE messages SET sender_jid = ? WHERE sender_jid = ? AND sender_jid != ?
			  AND NOT EXISTS (
				SELECT 1 FROM messages p
				WHERE p.chat_jid = messages.chat_jid
				  AND p.message_id = messages.message_id
				  AND p.sender_jid = ?)`,
			pn, lid, pn, pn)
		if err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("storage: rewrite sender %s: %w", lid, err)
			}
			continue
		}
		if n, _ := res.RowsAffected(); n > 0 {
			total += n
		}
	}
	if err := tx.Commit(); err != nil {
		return total, fmt.Errorf("storage: rewrite senders commit: %w", err)
	}
	// A partial pass must not report success: the caller clears
	// namesPending on nil and would not arm a retry.
	if firstErr != nil {
		return total, firstErr
	}
	return total, nil
}

// UnsupportedLabel gives empty-content rows an honest, specific placeholder.
func UnsupportedLabel(rawKind string) string {
	switch rawKind {
	case "skdm":
		return "Message not synced yet"
	case "template", "interactive":
		return "Interactive message"
	case "contact_card":
		return "Contact card"
	case "group_invite":
		return "Group invite"
	case "poll":
		return "Poll"
	case "album":
		return "Album"
	case "location", "live_location":
		return "Location"
	case "product":
		return "Product"
	case "event":
		return "Event"
	default:
		return "Message"
	}
}

// DeriveSenderMappings learns lid→PN mappings from our own rows: the same
// message_id stored under both sender forms (early delivery pre-mapping,
// then canonical). whatsmeow's LID store only knows mappings it observed
// live — accounts that never carried SenderAlt (business senders are the
// usual case) stay unmapped there, so the stored evidence is the only
// source. Fresh mappings win on conflict.
func (s *Store) DeriveSenderMappings(ctx context.Context, into map[string]string) error {
	// MATERIALIZED forces the LID side to resolve first (a few hundred rows
	// via a single scan) so the join per row stays index-driven. Unhinted,
	// modernc's planner drove from the PN side — a 534k-row nested loop that
	// burned a full core for minutes per names pass.
	rows, err := s.r.QueryContext(ctx, `
		WITH lid_rows AS MATERIALIZED (
			SELECT chat_jid, message_id, sender_jid FROM messages
			WHERE sender_jid LIKE '%@lid'
		)
		SELECT DISTINCT lid_rows.sender_jid, p.sender_jid
		FROM lid_rows
		JOIN messages p ON p.chat_jid = lid_rows.chat_jid
			AND p.message_id = lid_rows.message_id
			AND p.sender_jid LIKE '%@s.whatsapp.net'`)
	if err != nil {
		return fmt.Errorf("storage: derive sender mappings: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var lid, pn string
		if err := rows.Scan(&lid, &pn); err != nil {
			return fmt.Errorf("storage: derive sender mappings scan: %w", err)
		}
		into[lid] = pn
	}
	return rows.Err()
}

// DirectChatPhoneFallbacks titles chats whose only identity is a masked
// "@lid" jid: for each such direct chat with a fallback/empty name it
// returns the canonical phone sender observed inside the chat, so the
// caller can retitle it (e.g. "+62811…") instead of leaving a mask.
func (s *Store) DirectChatPhoneFallbacks(ctx context.Context) (map[string]string, error) {
	rows, err := s.r.QueryContext(ctx, `
		SELECT c.jid, (SELECT m.sender_jid FROM messages m
			WHERE m.chat_jid = c.jid AND m.sender_jid LIKE '%@s.whatsapp.net'
			ORDER BY m.timestamp DESC LIMIT 1)
		FROM chats c
		WHERE c.kind = 'direct' AND c.jid LIKE '%@lid'
		  AND (c.display_name = '' OR c.display_name LIKE '%@lid%')`)
	if err != nil {
		return nil, fmt.Errorf("storage: chat phone fallbacks: %w", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var chatJID string
		var pn sql.NullString // no PN message in the chat → NULL, not an error
		if err := rows.Scan(&chatJID, &pn); err != nil {
			return nil, fmt.Errorf("storage: chat phone fallbacks scan: %w", err)
		}
		if pn.Valid && pn.String != "" {
			out[chatJID] = pn.String
		}
	}
	return out, rows.Err()
}
