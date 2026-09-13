package storage

import (
	"context"
	"fmt"
	"strings"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// SearchMessages runs an FTS5 query over message text.
//
// User input is never passed raw into MATCH: terms are tokenized and each is
// double-quoted (doubling inner quotes), yielding an implicit-AND phrase
// query that cannot inject FTS5 grammar.
func (s *Store) SearchMessages(ctx context.Context, query string, limit int) (hits []core.SearchHit, err error) {
	match := buildMatchQuery(query)
	if match == "" {
		return []core.SearchHit{}, nil
	}
	if limit < 1 || limit > 100 {
		limit = 25
	}
	rows, err := s.r.QueryContext(ctx, `
		SELECT m.id, m.message_id, m.chat_jid, m.timestamp, m.kind,
		       snippet(messages_fts, 0, '⟪', '⟫', ' … ', 14)
		FROM messages_fts
		JOIN messages m ON m.id = messages_fts.rowid
		WHERE messages_fts MATCH ?
		ORDER BY rank
		LIMIT ?`, match, limit)
	if err != nil {
		return nil, fmt.Errorf("storage: search: %w", err)
	}
	defer rows.Close()
	// Non-nil even for zero rows: JSON null fails Codable decoding of the
	// client's non-optional arrays and drops the whole response (including
	// the chat/contact sections of the same search).
	hits = make([]core.SearchHit, 0, 16)
	for rows.Next() {
		var h core.SearchHit
		if err := rows.Scan(&h.RowID, &h.MessageID, &h.ChatJID, &h.Timestamp, &h.Kind, &h.Snippet); err != nil {
			return nil, err
		}
		hits = append(hits, h)
	}
	return hits, rows.Err()
}

func buildMatchQuery(query string) string {
	var terms []string
	for _, t := range strings.Fields(query) {
		t = strings.ReplaceAll(t, `"`, `""`)
		if t == "" {
			continue
		}
		terms = append(terms, `"`+t+`"`)
	}
	return strings.Join(terms, " ")
}
