// M3 storage contract for media rows:
//   - GetMedia joins media with its message row (chat context + proto blob)
//   - SetMediaDownloaded / SetMediaState drive the state machine
//   - MediaCacheSize / OldestDownloaded back LRU eviction
package storage_test

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func seedMediaMessage(t *testing.T, st *storage.Store, id string) core.Message {
	t.Helper()
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	m := core.Message{
		MessageID: id, ChatJID: jid, SenderJID: jid, Timestamp: 1700000100,
		Kind: core.KindImage, Text: "cap", Source: "live", MentionedJIDs: []string{},
		Media: &core.MediaMeta{
			Kind: "image", MIME: "image/jpeg", Size: 10,
			URL: "u", DirectPath: "/p", Proto: []byte("proto-blob-" + id),
		},
	}
	isNew, err := st.InsertMessage(ctx, &m)
	if err != nil || !isNew {
		t.Fatalf("seed: isNew=%v err=%v", isNew, err)
	}
	return m
}

func TestMediaRowLifecycle(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	m := seedMediaMessage(t, st, "m1")

	row, err := st.GetMedia(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if row.ChatJID != m.ChatJID || row.State != "not_downloaded" || string(row.Proto) != "proto-blob-m1" {
		t.Fatalf("row = %+v", row)
	}

	if err := st.SetMediaState(ctx, m.ID, "downloading"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMediaDownloaded(ctx, m.ID, "/tmp/x.jpg", 4321); err != nil {
		t.Fatal(err)
	}
	row, _ = st.GetMedia(ctx, m.ID)
	if row.State != "downloaded" || row.LocalPath != "/tmp/x.jpg" {
		t.Fatalf("after download: %+v", row)
	}

	size, count, err := st.MediaCacheSize(ctx)
	if err != nil || size != 4321 || count != 1 {
		t.Fatalf("cache size = %d/%d err=%v", size, count, err)
	}

	oldest, err := st.OldestDownloaded(ctx, 10)
	if err != nil || len(oldest) != 1 || oldest[0].MessageRowID != m.ID {
		t.Fatalf("oldest = %+v err=%v", oldest, err)
	}

	if err := st.SetMediaState(ctx, m.ID, "not_downloaded"); err != nil {
		t.Fatal(err)
	}
	if size, count, _ := st.MediaCacheSize(ctx); size != 0 || count != 0 {
		t.Fatalf("evicted row still counted: %d/%d", size, count)
	}
}

func TestGetMediaNotFound(t *testing.T) {
	st := openTestStore(t)
	if _, err := st.GetMedia(context.Background(), 999); err == nil {
		t.Fatal("expected error for missing media row")
	}
}

func TestMediaEvictionCandidatesAndBatchClear(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	dir := t.TempDir()

	for i, size := range []int64{4, 5, 6} {
		message := seedMediaMessage(t, st, fmt.Sprintf("evict-%d", i))
		path := filepath.Join(dir, fmt.Sprintf("evict-%d.bin", i))
		if err := st.SetMediaDownloaded(ctx, message.ID, path, size); err != nil {
			t.Fatal(err)
		}
	}

	victims, err := st.MediaEvictionCandidates(ctx, 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(victims) != 2 || victims[0].Size != 4 || victims[1].Size != 5 {
		t.Fatalf("victims = %+v, want oldest 4+5 bytes", victims)
	}
	ids := []int64{victims[0].MessageRowID, victims[1].MessageRowID}
	if err := st.ClearDownloadedMedia(ctx, ids); err != nil {
		t.Fatal(err)
	}
	for _, id := range ids {
		row, err := st.GetMedia(ctx, id)
		if err != nil {
			t.Fatal(err)
		}
		if row.State != "not_downloaded" || row.LocalPath != "" {
			t.Fatalf("row %d not cleared: %+v", id, row)
		}
	}
}

func TestMediaEvictionQueryPlan(t *testing.T) {
	st := openTestStore(t)
	db, err := sql.Open("sqlite", st.DSN())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	rows, err := db.QueryContext(context.Background(), `EXPLAIN QUERY PLAN
		WITH ranked AS (
			SELECT message_id, local_path, size,
			       SUM(size) OVER (ORDER BY downloaded_at ASC, rowid ASC) AS reclaimed
			FROM media WHERE state = 'downloaded'
		)
		SELECT message_id, local_path, size FROM ranked
		WHERE reclaimed - size < 8
		ORDER BY reclaimed ASC`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var details []string
	for rows.Next() {
		var id, parent, unused int
		var detail string
		if err := rows.Scan(&id, &parent, &unused, &detail); err != nil {
			t.Fatal(err)
		}
		details = append(details, detail)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	plan := strings.Join(details, "\n")
	t.Logf("query plan:\n%s", plan)
	if !strings.Contains(plan, "idx_media_evict") {
		t.Fatalf("query plan does not use idx_media_evict:\n%s", plan)
	}
	if strings.Contains(plan, "SCAN messages") {
		t.Fatalf("query plan scans messages:\n%s", plan)
	}
}
