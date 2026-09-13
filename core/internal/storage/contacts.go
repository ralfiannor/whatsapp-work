package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// UpsertContacts merges contact name data. Empty fields never overwrite
// existing values (push-name-only updates must not erase full names).
// UpsertContacts merges name fields (empty incoming values never overwrite)
// and returns how many rows were inserted or actually CHANGED — the caller
// turns a nonzero count into a contacts.updated event so clients can refresh
// their name maps immediately instead of waiting for the next poll.
func (s *Store) UpsertContacts(ctx context.Context, cs []core.Contact) (int, error) {
	changed := 0
	if len(cs) == 0 {
		return 0, nil
	}
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return changed, fmt.Errorf("storage: contacts begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO contacts (jid, full_name, push_name, business_name, updated_at)
		VALUES (?,?,?,?,?)
		ON CONFLICT (jid) DO UPDATE SET
			full_name     = CASE WHEN excluded.full_name != '' THEN excluded.full_name ELSE contacts.full_name END,
			push_name     = CASE WHEN excluded.push_name != '' THEN excluded.push_name ELSE contacts.push_name END,
			business_name = CASE WHEN excluded.business_name != '' THEN excluded.business_name ELSE contacts.business_name END,
			updated_at    = excluded.updated_at
		WHERE (excluded.full_name != '' AND excluded.full_name != contacts.full_name)
		   OR (excluded.push_name != '' AND excluded.push_name != contacts.push_name)
		   OR (excluded.business_name != '' AND excluded.business_name != contacts.business_name)`)
	if err != nil {
		return changed, fmt.Errorf("storage: contacts prepare: %w", err)
	}
	defer stmt.Close()
	ts := now()
	for _, c := range cs {
		if c.JID == "" {
			continue
		}
		if c.UpdatedAt == 0 {
			c.UpdatedAt = ts
		}
		res, err := stmt.ExecContext(ctx, c.JID, c.FullName, c.PushName, c.BusinessName, c.UpdatedAt)
		if err != nil {
			return changed, fmt.Errorf("storage: upsert contact %s: %w", c.JID, err)
		}
		if n, _ := res.RowsAffected(); n > 0 {
			changed++
		}
	}
	if err := tx.Commit(); err != nil {
		return changed, fmt.Errorf("storage: contacts commit: %w", err)
	}
	return changed, nil
}

// ListContacts searches contacts by substring over any name field.
func (s *Store) ListContacts(ctx context.Context, query string, limit int) ([]core.Contact, error) {
	if limit < 1 || limit > 5000 {
		limit = 50
	}
	q := `SELECT jid, full_name, push_name, business_name, updated_at FROM contacts`
	var args []any
	fullFetch := false
	if query != "" {
		pat := "%" + escapeLike(query) + "%"
		q += ` WHERE full_name LIKE ? ESCAPE '\' OR push_name LIKE ? ESCAPE '\'
			OR business_name LIKE ? ESCAPE '\' OR jid LIKE ? ESCAPE '\'`
		args = append(args, pat, pat, pat, pat)
	} else {
		// Full-directory fetch: the client builds its jid→name map from
		// this (transcript sender labels). Truncating it rendered everyone
		// past the cutoff as raw phone numbers — a real bug at 2000 on a
		// 3.5k-contact account. The table is account-bounded, so return
		// all rows; the limit stays meaningful for searches only.
		fullFetch = true
	}
	q += ` ORDER BY CASE WHEN full_name != '' THEN full_name
			WHEN push_name != '' THEN push_name
			WHEN business_name != '' THEN business_name
			ELSE jid END`
	if !fullFetch {
		q += ` LIMIT ?`
		args = append(args, limit)
	}

	rows, err := s.r.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("storage: list contacts: %w", err)
	}
	defer rows.Close()
	// Non-nil even for zero rows: JSON null fails Codable decoding of the
	// client's non-optional arrays and drops the whole response.
	out := make([]core.Contact, 0, 64)
	for rows.Next() {
		var c core.Contact
		if err := rows.Scan(&c.JID, &c.FullName, &c.PushName, &c.BusinessName, &c.UpdatedAt); err != nil {
			return nil, fmt.Errorf("storage: scan contact: %w", err)
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// GetContact returns one contact row by exact JID (ErrNotFound when absent).
func (s *Store) GetContact(ctx context.Context, jid string) (*core.Contact, error) {
	var c core.Contact
	err := s.r.QueryRowContext(ctx,
		`SELECT jid, full_name, push_name, business_name, updated_at FROM contacts WHERE jid = ?`,
		jid).Scan(&c.JID, &c.FullName, &c.PushName, &c.BusinessName, &c.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("storage: get contact: %w", err)
	}
	return &c, nil
}

// SetGroupMembers replaces a group's participant list.
func (s *Store) SetGroupMembers(ctx context.Context, groupJID string, members []core.GroupMember) error {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("storage: members begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, `DELETE FROM group_participants WHERE group_jid = ?`, groupJID); err != nil {
		return fmt.Errorf("storage: members clear: %w", err)
	}
	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO group_participants (group_jid, member_jid, display_name, role, updated_at)
		VALUES (?,?,?,?,?)`)
	if err != nil {
		return fmt.Errorf("storage: members prepare: %w", err)
	}
	defer stmt.Close()
	ts := now()
	for _, mem := range members {
		if _, err := stmt.ExecContext(ctx, groupJID, mem.JID, mem.DisplayName, mem.Role, ts); err != nil {
			return fmt.Errorf("storage: member insert: %w", err)
		}
	}
	return tx.Commit()
}

// GetGroupMembers returns a group's cached participant list (empty when none
// stored yet — caller falls back to the network).
func (s *Store) GetGroupMembers(ctx context.Context, groupJID string) ([]core.GroupMember, error) {
	rows, err := s.r.QueryContext(ctx,
		`SELECT member_jid, display_name, role FROM group_participants WHERE group_jid = ?`, groupJID)
	if err != nil {
		return nil, fmt.Errorf("storage: get members: %w", err)
	}
	defer rows.Close()
	var out []core.GroupMember
	for rows.Next() {
		var m core.GroupMember
		if err := rows.Scan(&m.JID, &m.DisplayName, &m.Role); err != nil {
			return nil, fmt.Errorf("storage: scan member: %w", err)
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

// Wipe deletes all domain data (logout). Session data lives in a separate DB
// managed by the adapter.
func (s *Store) Wipe(ctx context.Context) error {
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("storage: wipe begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	for _, table := range []string{
		"reactions", "media", "local_message_state", "messages",
		"group_participants", "chats", "contacts", "accounts", "app_settings",
	} {
		if _, err := tx.ExecContext(ctx, `DELETE FROM `+table); err != nil {
			return fmt.Errorf("storage: wipe %s: %w", table, err)
		}
	}
	return tx.Commit()
}


// escapeLike neutralizes LIKE wildcards in user input so "%"/"_" match
// literally instead of broadening the search.
func escapeLike(q string) string {
	r := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	return r.Replace(q)
}

// MirrorLIDContactNames copies name fields between PN↔LID twin rows: fill
// only fields the twin lacks, never overwrite (a row's own data always
// wins). Returns how many rows gained something. Idempotent.
func (s *Store) MirrorLIDContactNames(ctx context.Context, lidToPN map[string]string) (int64, error) {
	if len(lidToPN) == 0 {
		return 0, nil
	}
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("storage: mirror contacts begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()
	var copied int64
	for lid, pn := range lidToPN {
		if lid == "" || pn == "" || lid == pn {
			continue
		}
		// Both directions: lid→pn and pn→lid.
		for _, pair := range [][2]string{{lid, pn}, {pn, lid}} {
			src, dst := pair[0], pair[1]
			res, err := tx.ExecContext(ctx, `
				INSERT INTO contacts (jid, full_name, push_name, business_name, updated_at)
				SELECT ?, c.full_name, c.push_name, c.business_name, ?
				FROM contacts c
				WHERE c.jid = ?
				  AND (NULLIF(c.full_name, '') IS NOT NULL
				    OR NULLIF(c.push_name, '') IS NOT NULL
				    OR NULLIF(c.business_name, '') IS NOT NULL)
				ON CONFLICT (jid) DO UPDATE SET
					full_name     = CASE WHEN excluded.full_name != '' AND contacts.full_name = '' THEN excluded.full_name ELSE contacts.full_name END,
					push_name     = CASE WHEN excluded.push_name != '' AND contacts.push_name = '' THEN excluded.push_name ELSE contacts.push_name END,
					business_name = CASE WHEN excluded.business_name != '' AND contacts.business_name = '' THEN excluded.business_name ELSE contacts.business_name END,
					updated_at    = excluded.updated_at
				WHERE (excluded.full_name != '' AND contacts.full_name = '')
				   OR (excluded.push_name != '' AND contacts.push_name = '')
				   OR (excluded.business_name != '' AND contacts.business_name = '')`,
				dst, now(), src)
			if err != nil {
				return copied, fmt.Errorf("storage: mirror contacts %s→%s: %w", src, dst, err)
			}
			if n, _ := res.RowsAffected(); n > 0 {
				copied += n
			}
		}
	}
	if err := tx.Commit(); err != nil {
		return copied, fmt.Errorf("storage: mirror contacts commit: %w", err)
	}
	return copied, nil
}
