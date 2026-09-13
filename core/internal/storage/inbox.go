package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// SetMessageDone marks a message done (or re-opens it) — purely local state;
// the WhatsApp message itself is never touched. done_at records when, so the
// inbox's recently-done section orders by completion, and clears on reopen.
func (s *Store) SetMessageDone(ctx context.Context, rowID int64, done bool) error {
	var doneAt *int64
	if done {
		ts := now()
		doneAt = &ts
	}
	return s.upsertLocalState(ctx, rowID, func(set *localStateSet) {
		set.done, set.doneSet = &done, true
		set.doneAt, set.doneAtSet = doneAt, true
	})
}

// SetMessageSnoozed hides a message from the inbox until untilTS (0 = clear).
func (s *Store) SetMessageSnoozed(ctx context.Context, rowID int64, untilTS int64) error {
	return s.upsertLocalState(ctx, rowID, func(set *localStateSet) { set.snoozed, set.snoozedSet = &untilTS, true })
}

// SetMessageStarred stars a message locally.
func (s *Store) SetMessageStarred(ctx context.Context, rowID int64, starred bool) error {
	return s.upsertLocalState(ctx, rowID, func(set *localStateSet) { set.starred, set.starredSet = &starred, true })
}

// SetChatStarred toggles a chat's starred-work-contact flag.
func (s *Store) SetChatStarred(ctx context.Context, jid string, starred bool) error {
	res, err := s.w.ExecContext(ctx, `UPDATE chats SET is_starred = ?, updated_at = ? WHERE jid = ?`,
		starred, now(), jid)
	if err != nil {
		return fmt.Errorf("storage: chat star: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// SetChatWork marks a group as a work group (v0.2 focus classification).
func (s *Store) SetChatWork(ctx context.Context, jid string, work bool) error {
	res, err := s.w.ExecContext(ctx, `UPDATE chats SET is_work = ?, updated_at = ? WHERE jid = ?`,
		work, now(), jid)
	if err != nil {
		return fmt.Errorf("storage: chat work: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

type localStateSet struct {
	done        *bool
	doneSet     bool
	snoozed     *int64
	snoozedSet  bool
	starred     *bool
	starredSet  bool
	doneAt      *int64
	doneAtSet   bool
}

func (s *Store) upsertLocalState(ctx context.Context, rowID int64, patch func(*localStateSet)) error {
	var set localStateSet
	patch(&set)

	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("storage: local state begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	// Read-merge-write: partial updates must not clobber other columns.
	done, snoozed, starred := false, int64(0), false
	var doneAt sql.NullInt64
	err = tx.QueryRowContext(ctx,
		`SELECT done, COALESCE(snoozed_until,0), starred, done_at FROM local_message_state WHERE message_id = ?`,
		rowID).Scan(&done, &snoozed, &starred, &doneAt)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("storage: local state read: %w", err)
	}
	if set.doneSet {
		done = *set.done
	}
	if set.snoozedSet {
		snoozed = *set.snoozed
	}
	if set.starredSet {
		starred = *set.starred
	}
	if set.doneAtSet {
		doneAt.Valid, doneAt.Int64 = set.doneAt != nil, 0
		if set.doneAt != nil {
			doneAt.Int64 = *set.doneAt
		}
	}

	if _, err := tx.ExecContext(ctx, `
		INSERT INTO local_message_state (message_id, done, snoozed_until, starred, priority, done_at)
		VALUES (?, ?, ?, ?, 0, ?)
		ON CONFLICT (message_id) DO UPDATE SET
			done = excluded.done,
			snoozed_until = excluded.snoozed_until,
			starred = excluded.starred,
			done_at = excluded.done_at`,
		rowID, done, nullableInt(snoozed), starred, nullableNullInt(doneAt)); err != nil {
		return fmt.Errorf("storage: local state write: %w", err)
	}
	return tx.Commit()
}

func nullableNullInt(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return v.Int64
}

func nullableInt(v int64) any {
	if v == 0 {
		return nil
	}
	return v
}

// Inbox returns the actionable work inbox at instant nowTS as CONVERSATIONS:
// for each chat with pending items (live, incoming, not done, snooze lapsed
// — and the chat itself not snoozed), one digest row with the newest item,
// the pending count and whether anything mentions me. Busy groups are one
// row to Done, not fifty.
//
// Read state is deliberately NOT an exit: an item leaves only via Done or a
// not-yet-due Snooze (docs/feature-audit-2026-08-30.md §P0-1). Entry is
// restricted to source='live' so the initial history sync (whose read
// position starts at the newest synced timestamp) cannot flood the queue; a
// one-time migration marked pre-existing rows done as the baseline, and v13
// reopened the recent-unread backlog.
func (s *Store) Inbox(ctx context.Context, nowTS int64, limit int) (*core.Inbox, error) {
	if limit < 1 || limit > 200 {
		limit = 50
	}
	// Non-nil slices so JSON carries [] (not null): a null array fails
	// Codable decoding of non-optional arrays on the client.
	out := &core.Inbox{
		Mentions:     []core.InboxConversation{},
		Direct:       []core.InboxConversation{},
		WorkGroups:   []core.InboxConversation{},
		StarredChats: []core.Chat{},
		DoneRecent:   []core.InboxItem{},
	}

	// One conversation row per chat: window functions rank the newest
	// pending item and aggregate the rest in the same scan.
	//
	// Driven from the PENDING local-state rows (CROSS JOIN so the planner
	// cannot reorder it back to a full messages scan — done lives in
	// another table, so no messages index can filter it). Cost scales with
	// pending items, not total history: the old shape scanned every
	// message row (~230 ms at 256k) on every /inbox refetch.
	rows, err := s.r.QueryContext(ctx, `
		SELECT j.chat_jid, j.display_name, j.chat_kind, j.is_work, j.is_starred,
		       j.id, j.message_id, j.sender_jid, j.timestamp, j.msg_kind, j.text,
		       j.cnt, j.anym
		FROM (
			SELECT m.chat_jid, c.display_name, c.kind AS chat_kind, c.is_work, c.is_starred,
			       m.id, m.message_id, m.sender_jid, m.timestamp, m.kind AS msg_kind, m.text,
			       m.has_mention,
			       COUNT(*)   OVER (PARTITION BY m.chat_jid) AS cnt,
			       MAX(m.has_mention) OVER (PARTITION BY m.chat_jid) AS anym,
			       ROW_NUMBER() OVER (PARTITION BY m.chat_jid ORDER BY m.timestamp DESC, m.id DESC) AS rn
			FROM local_message_state ls
			CROSS JOIN messages m ON m.id = ls.message_id
			JOIN chats c ON c.jid = m.chat_jid
			WHERE ls.done = 0
			  AND (ls.snoozed_until IS NULL OR ls.snoozed_until <= ?)
			  AND (c.snoozed_until IS NULL OR c.snoozed_until <= ?)
			  AND m.from_me = 0
			  AND m.source = 'live'
			  AND m.revoked = 0
			  AND m.kind != 'system'
		) j
		WHERE j.rn = 1
		ORDER BY j.timestamp DESC
		LIMIT ?`, nowTS, nowTS, limit)
	if err != nil {
		return nil, fmt.Errorf("storage: inbox: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var conv core.InboxConversation
		var kind, msgKind string
		var work, star, anym int
		if err := rows.Scan(&conv.ChatJID, &conv.ChatName, &kind, &work, &star,
			&conv.LastRowID, &conv.LastMessageID, &conv.LastSenderJID,
			&conv.LastTimestamp, &msgKind, &conv.LastText,
			&conv.Count, &anym); err != nil {
			return nil, err
		}
		conv.Kind = kind
		conv.IsWork = work != 0
		conv.IsStarred = star != 0
		conv.LastKind = msgKind
		conv.HasMention = anym != 0
		switch {
		case conv.HasMention:
			out.Mentions = append(out.Mentions, conv)
		case kind == "group" && conv.IsWork:
			out.WorkGroups = append(out.WorkGroups, conv)
		case kind != "group":
			out.Direct = append(out.Direct, conv)
		}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	out.Counts.Mentions = len(out.Mentions)
	out.Counts.Direct = len(out.Direct)
	out.Counts.Work = len(out.WorkGroups)
	out.Counts.Total = out.Counts.Mentions + out.Counts.Direct + out.Counts.Work

	// Starred chats that still have unread traffic.
	sc, err := s.r.QueryContext(ctx, `
		SELECT `+chatCols+` FROM chats
		WHERE is_starred = 1 AND unread_count > 0
		ORDER BY last_message_ts DESC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("storage: inbox starred: %w", err)
	}
	defer sc.Close()
	for sc.Next() {
		c, err := scanChat(sc)
		if err != nil {
			return nil, err
		}
		out.StarredChats = append(out.StarredChats, *c)
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	return out, s.fillDoneRecent(ctx, out, nowTS)
}

// fillDoneRecent loads the recently-completed audit section (message rows —
// newest completion first). Capped small: an audit trail with a Reopen
// button, not a second work queue.
func (s *Store) fillDoneRecent(ctx context.Context, out *core.Inbox, nowTS int64) error {
	dn, err := s.r.QueryContext(ctx, `
		SELECT m.id, m.message_id, m.chat_jid, c.display_name, m.sender_jid,
		       m.timestamp, m.kind, m.text, m.has_mention,
		       COALESCE(ls.starred, 0)
		FROM messages m
		JOIN chats c ON c.jid = m.chat_jid
		JOIN local_message_state ls ON ls.message_id = m.id
		WHERE ls.done = 1 AND ls.done_at IS NOT NULL AND ls.done_at > ?
		  AND m.from_me = 0 AND m.source = 'live' AND m.revoked = 0 AND m.kind != 'system'
		ORDER BY ls.done_at DESC
		LIMIT ?`, nowTS-7*24*3600, doneRecentLimit)
	if err != nil {
		return fmt.Errorf("storage: inbox done recent: %w", err)
	}
	defer dn.Close()
	for dn.Next() {
		var it core.InboxItem
		var kind string
		var starred int
		if err := dn.Scan(&it.RowID, &it.MessageID, &it.ChatJID, &it.ChatName,
			&it.SenderJID, &it.Timestamp, &kind, &it.Text, &it.HasMention, &starred); err != nil {
			return err
		}
		it.Starred = starred != 0
		out.DoneRecent = append(out.DoneRecent, it)
	}
	return dn.Err()
}

// doneRecentLimit bounds the recently-done section independently of the
// caller's limit — it must not crowd out actionable rows on small requests.
const doneRecentLimit = 20

// SetChatDone completes (or reopens) EVERY pending inbox item of a
// conversation in one write — the bulk action behind a conversation-level
// Done. Only live incoming content rows are touched; done stamps done_at so
// the audit section can order by completion.
func (s *Store) SetChatDone(ctx context.Context, jid string, done bool) error {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("storage: chat done begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	// Chats carry a snooze deadline that hides the conversation wholesale;
	// an explicit Done (or Reopen) clears it — mixing the two states would
	// make a reopened conversation invisible until the old deadline passed.
	// The unconditional snooze clear doubles as the existence check: the
	// sibling mutations 404 on an unknown jid, and a silent 204 here made
	// "Done" appear to work while nothing changed.
	res, err := tx.ExecContext(ctx,
		`UPDATE chats SET snoozed_until = NULL, updated_at = ? WHERE jid = ?`, now(), jid)
	if err != nil {
		return fmt.Errorf("storage: chat done clear snooze: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}

	var doneAt any
	if done {
		doneAt = now()
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO local_message_state (message_id, done, done_at, snoozed_until, starred, priority)
		SELECT m.id, ?, ?, NULL, COALESCE(ls.starred, 0), 0
		FROM messages m
		LEFT JOIN local_message_state ls ON ls.message_id = m.id
		WHERE m.chat_jid = ? AND m.from_me = 0 AND m.source = 'live'
		  AND m.revoked = 0 AND m.kind != 'system'
		ON CONFLICT (message_id) DO UPDATE SET
			done = excluded.done,
			done_at = excluded.done_at,
			snoozed_until = NULL`,
		done, doneAt, jid); err != nil {
		return fmt.Errorf("storage: chat done: %w", err)
	}
	return tx.Commit()
}

// SetChatSnooze defers a whole conversation until untilTS (0 = clear). The
// deadline lives on the chat row so messages arriving AFTER the snooze are
// held too — per-message snooze could not do that.
func (s *Store) SetChatSnooze(ctx context.Context, jid string, untilTS int64) error {
	res, err := s.w.ExecContext(ctx,
		`UPDATE chats SET snoozed_until = ?, updated_at = ? WHERE jid = ?`,
		nullableInt(untilTS), now(), jid)
	if err != nil {
		return fmt.Errorf("storage: chat snooze: %w", err)
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return ErrNotFound
	}
	return nil
}

// attachReactions loads reactions for a page of messages in one query.
// It is an enrichment whose failure must not eat the page: log and serve
// the rows without reactions (the reactions table stays authoritative).
func (s *Store) attachReactions(ctx context.Context, msgs []core.Message) {
	if len(msgs) == 0 {
		return
	}
	ids := make([]string, 0, len(msgs))
	for i := range msgs {
		ids = append(ids, fmt.Sprintf("%d", msgs[i].ID))
	}
	q := `SELECT message_id, reactor_jid, emoji FROM reactions
	      WHERE message_id IN (` + strings.Join(ids, ",") + `) ORDER BY timestamp ASC`
	rows, err := s.r.QueryContext(ctx, q)
	if err != nil {
		s.log.Warn("storage: attach reactions", "err", err)
		return
	}
	defer rows.Close()
	byRow := map[int64][]core.Reaction{}
	for rows.Next() {
		var rowID int64
		var r core.Reaction
		if err := rows.Scan(&rowID, &r.ReactorJID, &r.Emoji); err != nil {
			s.log.Warn("storage: attach reactions scan", "err", err)
			return
		}
		byRow[rowID] = append(byRow[rowID], r)
	}
	if err := rows.Err(); err != nil {
		s.log.Warn("storage: attach reactions rows", "err", err)
		return
	}
	for i := range msgs {
		msgs[i].Reactions = byRow[msgs[i].ID]
	}
}
