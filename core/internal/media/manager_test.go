// Package media_test covers the on-demand download manager:
//   - happy path: download → file on disk (0600), state downloaded, event fired
//   - cache hits never re-download; concurrent requests single-flight
//   - failures mark the row failed and are retryable
//   - LRU eviction trims the cache to its cap (oldest first)
//   - a missing file with state=downloaded is detected and re-fetched
//   - ClearAll removes every cached file (logout wipe)
package media_test

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/media"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

type fakeDL struct {
	mu    sync.Mutex
	calls atomic.Int64
	data  []byte
	err   error
	gate  <-chan struct{} // optional barrier to prove single-flight
}

func (f *fakeDL) DownloadMedia(ctx context.Context, kind string, proto []byte) ([]byte, error) {
	f.calls.Add(1)
	if f.gate != nil {
		<-f.gate
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return nil, f.err
	}
	return append([]byte(nil), f.data...), nil
}

type update struct {
	rowID int64
	state string
}

func newManager(t *testing.T, cap int64, dl *fakeDL) (*media.Manager, *storage.Store, chan update) {
	t.Helper()
	st := openStore(t)
	dir := filepath.Join(t.TempDir(), "media")
	updates := make(chan update, 16)
	m, err := media.New(st, dl, dir, cap, 2,
		func(rowID int64, chatJID string, md core.MediaMeta) {
			updates <- update{rowID: rowID, state: md.State}
		})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = m.Close() })
	return m, st, updates
}

func openStore(t *testing.T) *storage.Store {
	t.Helper()
	st, err := storage.Open(context.Background(), t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	return st
}

func seed(t *testing.T, st *storage.Store, id string, ts int64) core.Message {
	t.Helper()
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, core.Chat{JID: jid, Kind: core.KindDirect, DisplayName: "A"}); err != nil {
		t.Fatal(err)
	}
	m := core.Message{
		MessageID: id, ChatJID: jid, SenderJID: jid, Timestamp: ts,
		Kind: core.KindImage, Source: "live", MentionedJIDs: []string{},
		Media: &core.MediaMeta{
			Kind: "image", MIME: "image/jpeg", Size: 6,
			URL: "u", DirectPath: "/p", Proto: []byte("blob-" + id),
		},
	}
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	return m
}

func waitUpdate(t *testing.T, ch chan update, state string) update {
	t.Helper()
	for {
		select {
		case u := <-ch:
			if u.state == state {
				return u
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for %q update", state)
		}
	}
}

func TestDownloadHappyPath(t *testing.T) {
	dl := &fakeDL{data: []byte("JPEGDATA")}
	m, st, updates := newManager(t, 1<<20, dl)
	msg := seed(t, st, "m1", 1700000100)

	md, err := m.EnsureDownloaded(context.Background(), msg.ID)
	if err != nil {
		t.Fatal(err)
	}
	if md.State != "downloaded" || md.LocalPath == "" {
		t.Fatalf("meta = %+v", md)
	}
	data, err := os.ReadFile(md.LocalPath)
	if err != nil || string(data) != "JPEGDATA" {
		t.Fatalf("file content = %q err=%v", data, err)
	}
	info, _ := os.Stat(md.LocalPath)
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("file mode = %v, want 0600", info.Mode())
	}
	u := waitUpdate(t, updates, "downloaded")
	if u.rowID != msg.ID {
		t.Fatalf("update row = %d, want %d", u.rowID, msg.ID)
	}
}

func TestCacheHitNoRedownload(t *testing.T) {
	dl := &fakeDL{data: []byte("XYZ")}
	m, st, _ := newManager(t, 1<<20, dl)
	msg := seed(t, st, "m1", 1700000100)

	for i := 0; i < 3; i++ {
		if _, err := m.EnsureDownloaded(context.Background(), msg.ID); err != nil {
			t.Fatal(err)
		}
	}
	if got := dl.calls.Load(); got != 1 {
		t.Fatalf("downloads = %d, want 1 (cache hits must not re-fetch)", got)
	}
}

func TestSingleFlight(t *testing.T) {
	gate := make(chan struct{})
	dl := &fakeDL{data: []byte("ABC"), gate: gate}
	m, st, _ := newManager(t, 1<<20, dl)
	msg := seed(t, st, "m1", 1700000100)

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, _ = m.EnsureDownloaded(context.Background(), msg.ID)
		}()
	}
	time.Sleep(200 * time.Millisecond) // let them pile up on the barrier
	close(gate)
	wg.Wait()
	if got := dl.calls.Load(); got != 1 {
		t.Fatalf("downloads = %d, want 1 (single-flight)", got)
	}
}

func TestFailureMarksRowAndRetries(t *testing.T) {
	dl := &fakeDL{err: os.ErrDeadlineExceeded}
	m, st, updates := newManager(t, 1<<20, dl)
	msg := seed(t, st, "m1", 1700000100)

	if _, err := m.EnsureDownloaded(context.Background(), msg.ID); err == nil {
		t.Fatal("expected download error")
	}
	waitUpdate(t, updates, "failed")
	row, _ := st.GetMedia(context.Background(), msg.ID)
	if row.State != "failed" {
		t.Fatalf("state = %q, want failed", row.State)
	}

	// Retry succeeds once the downloader recovers.
	dl.mu.Lock()
	dl.err = nil
	dl.data = []byte("OK")
	dl.mu.Unlock()
	md, err := m.EnsureDownloaded(context.Background(), msg.ID)
	if err != nil || md.State != "downloaded" {
		t.Fatalf("retry: %+v err=%v", md, err)
	}
}

func TestLRUEviction(t *testing.T) {
	const body = "6bytes"
	dl := &fakeDL{data: []byte(body)}
	// Cap fits exactly one 6-byte item.
	m, st, updates := newManager(t, int64(len(body)), dl)

	m1 := seed(t, st, "m1", 1700000100)
	m2 := seed(t, st, "m2", 1700000200)

	md1, err := m.EnsureDownloaded(context.Background(), m1.ID)
	if err != nil {
		t.Fatal(err)
	}
	waitUpdate(t, updates, "downloaded")
	if _, err := m.EnsureDownloaded(context.Background(), m2.ID); err != nil {
		t.Fatal(err)
	}
	waitUpdate(t, updates, "downloaded")
	m.ScheduleEviction()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		row1, _ := st.GetMedia(context.Background(), m1.ID)
		if row1.State == "not_downloaded" {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// m1 must have been evicted (oldest), m2 kept.
	row1, _ := st.GetMedia(context.Background(), m1.ID)
	row2, _ := st.GetMedia(context.Background(), m2.ID)
	if row1.State != "not_downloaded" {
		t.Fatalf("oldest not evicted: %+v", row1)
	}
	if row1.LocalPath != "" {
		t.Fatalf("evicted row kept local_path: %+v", row1)
	}
	if _, err := os.Stat(md1.LocalPath); !os.IsNotExist(err) {
		t.Fatal("evicted file still on disk")
	}
	if row2.State != "downloaded" {
		t.Fatalf("newest evicted instead: %+v", row2)
	}
}

func TestEvictionKeepsDownloadedStateWhenFileRemovalFails(t *testing.T) {
	m, st, _ := newManager(t, 0, &fakeDL{data: []byte("x")})
	msg := seed(t, st, "remove-fails", 1700000100)
	dirPath := filepath.Join(t.TempDir(), "non-empty")
	if err := os.Mkdir(dirPath, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dirPath, "child"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMediaDownloaded(context.Background(), msg.ID, dirPath, 1); err != nil {
		t.Fatal(err)
	}

	m.EvictLRU(context.Background())

	row, err := st.GetMedia(context.Background(), msg.ID)
	if err != nil {
		t.Fatal(err)
	}
	if row.State != "downloaded" || row.LocalPath != dirPath {
		t.Fatalf("failed removal cleared downloaded state: %+v", row)
	}
}

func TestCloseIsIdempotentAndIgnoresNewSchedules(t *testing.T) {
	m, _, _ := newManager(t, 1, &fakeDL{data: []byte("x")})
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
	m.ScheduleEviction()
	if err := m.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestMissingFileRefetched(t *testing.T) {
	dl := &fakeDL{data: []byte("DATA")}
	m, st, _ := newManager(t, 1<<20, dl)
	msg := seed(t, st, "m1", 1700000100)

	md, err := m.EnsureDownloaded(context.Background(), msg.ID)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(md.LocalPath); err != nil {
		t.Fatal(err)
	}
	if _, err := m.EnsureDownloaded(context.Background(), msg.ID); err != nil {
		t.Fatal(err)
	}
	if got := dl.calls.Load(); got != 2 {
		t.Fatalf("downloads = %d, want 2 (missing file must re-fetch)", got)
	}
}

func TestFileInfoValidation(t *testing.T) {
	dl := &fakeDL{data: []byte("DATA")}
	m, st, _ := newManager(t, 1<<20, dl)
	msg := seed(t, st, "m1", 1700000100)
	if _, err := m.EnsureDownloaded(context.Background(), msg.ID); err != nil {
		t.Fatal(err)
	}

	p, mime, err := m.FileInfo(context.Background(), msg.ID)
	if err != nil || p == "" || mime != "image/jpeg" {
		t.Fatalf("FileInfo = %q %q err=%v", p, mime, err)
	}
	if _, _, err := m.FileInfo(context.Background(), 424242); err == nil {
		t.Fatal("unknown row must error")
	}
}

func TestClearAll(t *testing.T) {
	dl := &fakeDL{data: []byte("DATA")}
	m, st, _ := newManager(t, 1<<20, dl)
	msg := seed(t, st, "m1", 1700000100)
	md, _ := m.EnsureDownloaded(context.Background(), msg.ID)

	if err := m.ClearAll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(md.LocalPath); !os.IsNotExist(err) {
		t.Fatal("cached file survived ClearAll")
	}
	row, _ := st.GetMedia(context.Background(), msg.ID)
	if row.State != "not_downloaded" {
		t.Fatalf("state after ClearAll = %q", row.State)
	}
}

func BenchmarkEvictLRU100(b *testing.B) {
	ctx := context.Background()
	st, err := storage.Open(ctx, b.TempDir(), nil)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = st.Close() })
	cacheDir := b.TempDir()
	m, err := media.New(st, &fakeDL{data: []byte("x")}, cacheDir, 1, 1, nil)
	if err != nil {
		b.Fatal(err)
	}
	b.Cleanup(func() { _ = m.Close() })
	m.SetLogger(slog.New(slog.NewTextHandler(io.Discard, nil)))
	jid := "bench@s.whatsapp.net"
	if err := st.EnsureChat(ctx, core.Chat{JID: jid, Kind: core.KindDirect, DisplayName: "Bench"}); err != nil {
		b.Fatal(err)
	}
	rowIDs := make([]int64, 101)
	paths := make([]string, 101)
	for i := range rowIDs {
		message := core.Message{
			MessageID: fmt.Sprintf("bench-%03d", i), ChatJID: jid, SenderJID: jid,
			Timestamp: int64(1_700_000_000 + i), Kind: core.KindImage,
			Source: "live", MentionedJIDs: []string{},
			Media: &core.MediaMeta{Kind: "image", MIME: "image/png", Size: 1,
				URL: "u", DirectPath: "/p", Proto: []byte("p")},
		}
		if _, err := st.InsertMessage(ctx, &message); err != nil {
			b.Fatal(err)
		}
		rowIDs[i] = message.ID
		paths[i] = filepath.Join(cacheDir, fmt.Sprintf("bench-%03d.bin", i))
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		b.StopTimer()
		for j, rowID := range rowIDs {
			_ = os.WriteFile(paths[j], []byte("x"), 0o600)
			if err := st.SetMediaDownloaded(ctx, rowID, paths[j], 1); err != nil {
				b.Fatal(err)
			}
		}
		b.StartTimer()
		m.EvictLRU(ctx)
	}
}
