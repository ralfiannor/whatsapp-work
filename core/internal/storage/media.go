package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// MediaRow is the persistence view of one media item: state machine fields
// plus the re-download material (proto blob) and chat context.
type MediaRow struct {
	MessageRowID int64
	ChatJID      string
	MediaID      string
	Kind         string
	MIME         string
	State        string
	LocalPath    string
	Size         int64
	Proto        []byte
}

// GetMedia fetches one media row by its message row id.
func (s *Store) GetMedia(ctx context.Context, messageRowID int64) (*MediaRow, error) {
	var r MediaRow
	err := s.r.QueryRowContext(ctx, `
		SELECT md.message_id, m.chat_jid, md.id, md.kind, md.mime, md.state, md.local_path, md.size, md.proto
		FROM media md JOIN messages m ON m.id = md.message_id
		WHERE md.message_id = ?`, messageRowID).
		Scan(&r.MessageRowID, &r.ChatJID, &r.MediaID, &r.Kind, &r.MIME, &r.State, &r.LocalPath, &r.Size, &r.Proto)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("storage: get media: %w", err)
	}
	return &r, nil
}

// SetMediaDownloaded marks a media item downloaded at localPath.
func (s *Store) SetMediaDownloaded(ctx context.Context, messageRowID int64, localPath string, size int64) error {
	_, err := s.w.ExecContext(ctx, `
		UPDATE media SET
			state = 'downloaded', local_path = ?, size = ?,
			downloaded_at = strftime('%s','now'), updated_at = strftime('%s','now')
		WHERE message_id = ?`, localPath, size, messageRowID)
	if err != nil {
		return fmt.Errorf("storage: media downloaded: %w", err)
	}
	return nil
}

// SetMediaState moves a media item in the state machine
// (not_downloaded | downloading | downloaded | failed | unavailable).
func (s *Store) SetMediaState(ctx context.Context, messageRowID int64, state string) error {
	_, err := s.w.ExecContext(ctx, `
		UPDATE media SET state = ?, updated_at = strftime('%s','now')
		WHERE message_id = ?`, state, messageRowID)
	if err != nil {
		return fmt.Errorf("storage: media state: %w", err)
	}
	return nil
}

// SetMediaDownloadedClear drops the local-path claim without touching state
// (used by eviction and cache wipes).
func (s *Store) SetMediaDownloadedClear(ctx context.Context, messageRowID int64) error {
	_, err := s.w.ExecContext(ctx, `
		UPDATE media SET local_path = '', downloaded_at = NULL, updated_at = strftime('%s','now')
		WHERE message_id = ?`, messageRowID)
	if err != nil {
		return fmt.Errorf("storage: media clear path: %w", err)
	}
	return nil
}

// MediaCacheSize reports total bytes and item count of downloaded media.
func (s *Store) MediaCacheSize(ctx context.Context) (bytes int64, count int, err error) {
	err = s.r.QueryRowContext(ctx,
		`SELECT COALESCE(SUM(size), 0), COUNT(*) FROM media WHERE state = 'downloaded'`).
		Scan(&bytes, &count)
	if err != nil {
		return 0, 0, fmt.Errorf("storage: media cache size: %w", err)
	}
	return bytes, count, nil
}

// MediaEvictionCandidates returns the oldest downloaded rows whose cumulative
// size reaches bytesToFree. The partial eviction index supplies the LRU order.
func (s *Store) MediaEvictionCandidates(ctx context.Context, bytesToFree int64) ([]MediaRow, error) {
	rows, err := s.r.QueryContext(ctx, `
		WITH ranked AS (
			SELECT message_id, local_path, size,
			       SUM(size) OVER (ORDER BY downloaded_at ASC, rowid ASC) AS reclaimed
			FROM media WHERE state = 'downloaded'
		)
		SELECT message_id, local_path, size FROM ranked
		WHERE reclaimed - size < ?
		ORDER BY reclaimed ASC`, bytesToFree)
	if err != nil {
		return nil, fmt.Errorf("storage: media eviction candidates: %w", err)
	}
	defer rows.Close()

	var victims []MediaRow
	for rows.Next() {
		var row MediaRow
		if err := rows.Scan(&row.MessageRowID, &row.LocalPath, &row.Size); err != nil {
			return nil, fmt.Errorf("storage: media eviction candidate scan: %w", err)
		}
		victims = append(victims, row)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("storage: media eviction candidates rows: %w", err)
	}
	return victims, nil
}

// ClearDownloadedMedia clears a batch of successfully removed cache entries
// in one writer transaction.
func (s *Store) ClearDownloadedMedia(ctx context.Context, rowIDs []int64) error {
	if len(rowIDs) == 0 {
		return nil
	}
	tx, err := s.w.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("storage: media eviction begin: %w", err)
	}
	defer tx.Rollback()
	stmt, err := tx.PrepareContext(ctx, `UPDATE media SET state='not_downloaded',
		local_path='', downloaded_at=NULL, updated_at=strftime('%s','now') WHERE message_id=?`)
	if err != nil {
		return fmt.Errorf("storage: media eviction prepare: %w", err)
	}
	defer stmt.Close()
	for _, id := range rowIDs {
		if _, err := stmt.ExecContext(ctx, id); err != nil {
			return fmt.Errorf("storage: media eviction row %d: %w", id, err)
		}
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("storage: media eviction commit: %w", err)
	}
	return nil
}

// OldestDownloaded lists downloaded media by least-recently-downloaded first
// (downloaded_at second resolution; rowid breaks ties deterministically).
func (s *Store) OldestDownloaded(ctx context.Context, limit int) ([]MediaRow, error) {
	rows, err := s.r.QueryContext(ctx, `
		SELECT message_id, local_path, size FROM media
		WHERE state = 'downloaded'
		ORDER BY downloaded_at ASC, rowid ASC LIMIT ?`, limit)
	if err != nil {
		return nil, fmt.Errorf("storage: oldest media: %w", err)
	}
	defer rows.Close()
	var out []MediaRow
	for rows.Next() {
		var r MediaRow
		if err := rows.Scan(&r.MessageRowID, &r.LocalPath, &r.Size); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
