// Package media implements on-demand media downloads with a bounded LRU
// file cache (docs/architecture.md R4, docs/schema.md "Media").
//
// Nothing downloads eagerly: a row's metadata (incl. the serialized proto)
// is persisted at receive time; bytes are fetched only when the UI asks.
// Downloads single-flight per media item and are capped at maxConcurrent.
package media

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"mime"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

// Downloader fetches and decrypts media bytes from the serialized message
// proto. Implemented by the whatsmeow adapter.
type Downloader interface {
	DownloadMedia(ctx context.Context, kind string, protoBlob []byte) ([]byte, error)
}

// UpdateFunc notifies the app layer of state transitions (→ media.updated
// events for the UI).
type UpdateFunc func(messageRowID int64, chatJID string, md core.MediaMeta)

// Manager owns the media cache directory and download lifecycle.

// maxMediaBytes caps a single media item's download: the proto's
// FileLength is attacker-supplied, so trust nothing above this. The value
// lives in core so the whatsapp transport-level bound (streaming) and this
// post-download re-check cannot drift apart.
const maxMediaBytes = core.MaxMediaBytes
type Manager struct {
	store    *storage.Store
	dl       Downloader
	dir      string
	maxBytes int64
	sem      chan struct{}
	onUpdate UpdateFunc

	mu       sync.Mutex
	inflight map[int64]chan struct{}

	logMu sync.RWMutex
	log   *slog.Logger

	ctx       context.Context
	cancel    context.CancelFunc
	evictCh   chan struct{}
	wg        sync.WaitGroup
	closeOnce sync.Once
	closed    atomic.Bool
	cacheMu   sync.Mutex
}

// New creates the cache dir and the manager. Run EvictLRU once at startup to
// reconcile the on-disk cache with the cap.
func New(store *storage.Store, dl Downloader, dir string, maxBytes int64, maxConcurrent int, onUpdate UpdateFunc) (*Manager, error) {
	if dl == nil {
		return nil, errors.New("media: nil downloader")
	}
	if maxConcurrent < 1 {
		maxConcurrent = 1
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("media: cache dir: %w", err)
	}
	workerCtx, cancel := context.WithCancel(context.Background())
	m := &Manager{
		store: store, dl: dl, dir: dir, maxBytes: maxBytes,
		sem: make(chan struct{}, maxConcurrent), log: slog.Default(),
		onUpdate: onUpdate, inflight: make(map[int64]chan struct{}),
		ctx: workerCtx, cancel: cancel, evictCh: make(chan struct{}, 1),
	}
	m.wg.Add(1)
	go m.evictionLoop()
	return m, nil
}

// SetLogger overrides the default slog logger.
func (m *Manager) SetLogger(l *slog.Logger) {
	if l == nil {
		l = slog.Default()
	}
	m.logMu.Lock()
	m.log = l
	m.logMu.Unlock()
}

// Dir returns the cache directory (diagnostics).
func (m *Manager) Dir() string { return m.dir }

// MaxBytes returns the cache cap in bytes.
func (m *Manager) MaxBytes() int64 { return m.maxBytes }

// Close stops and joins the eviction worker. In-flight downloads finish on
// their own contexts, but cannot replace cache state after Close begins.
func (m *Manager) Close() error {
	m.closeOnce.Do(func() {
		m.closed.Store(true)
		m.cancel()
		m.wg.Wait()
		// Join any explicit eviction or cache replacement that began before
		// closed was published.
		m.cacheMu.Lock()
		m.cacheMu.Unlock()
	})
	return nil
}

// EnsureDownloaded returns the media meta for a message, downloading bytes
// if needed. Cache hits are free; concurrent callers share one download.
func (m *Manager) EnsureDownloaded(ctx context.Context, messageRowID int64) (*core.MediaMeta, error) {
	row, err := m.store.GetMedia(ctx, messageRowID)
	if err != nil {
		return nil, err
	}
	if row.State == "downloaded" && row.LocalPath != "" {
		if _, err := os.Stat(row.LocalPath); err == nil {
			md := rowMeta(row, row.LocalPath)
			return &md, nil // cache hit
		}
		// File vanished (user cleared the dir): fall through and re-fetch.
	}

	wait, ok := m.joinInflight(messageRowID)
	if ok {
		select {
		case <-wait:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		fresh, err := m.store.GetMedia(ctx, messageRowID)
		if err != nil {
			return nil, err
		}
		if fresh.State != "downloaded" {
			return nil, fmt.Errorf("media: concurrent download ended in state %q", fresh.State)
		}
		md := rowMeta(fresh, fresh.LocalPath)
		return &md, nil
	}
	// We own the download.
	defer m.finishInflight(messageRowID)

	m.sem <- struct{}{}
	defer func() { <-m.sem }()

	if row.Size > maxMediaBytes {
		m.setState(ctx, row, "failed")
		return nil, fmt.Errorf("media: refusing %d-byte download over cap", row.Size)
	}
	m.setState(ctx, row, "downloading")
	data, err := m.dl.DownloadMedia(ctx, row.Kind, row.Proto)
	if err != nil {
		m.setState(ctx, row, "failed")
		m.logger().Warn("media: download failed", "row", messageRowID, "err", err)
		return nil, fmt.Errorf("media: download: %w", err)
	}
	// The pre-check trusted the sender-claimed FileLength; the actual byte
	// count is the only thing that bounds memory/disk. Re-verify post-fetch.
	if int64(len(data)) > maxMediaBytes {
		m.setState(ctx, row, "failed")
		m.logger().Warn("media: downloaded size over cap", "row", messageRowID,
			"bytes", len(data), "cap", maxMediaBytes)
		return nil, fmt.Errorf("media: refusing %d-byte download over cap", len(data))
	}

	m.cacheMu.Lock()
	if m.closed.Load() {
		m.cacheMu.Unlock()
		return nil, errors.New("media: manager closed")
	}
	path, err := m.writeAtomic(row, data)
	if err != nil {
		m.setState(ctx, row, "failed")
		m.cacheMu.Unlock()
		return nil, err
	}
	if err := m.store.SetMediaDownloaded(ctx, messageRowID, path, int64(len(data))); err != nil {
		// file is on disk but the row is stranded in "downloading"; mark it
		// failed so the UI gets a terminal state and retry stays possible
		m.setState(ctx, row, "failed")
		m.cacheMu.Unlock()
		return nil, err
	}
	m.cacheMu.Unlock()
	md := rowMeta(row, path)
	md.State = "downloaded"
	md.Size = int64(len(data))
	m.notify(messageRowID, row.ChatJID, md)
	m.ScheduleEviction()
	return &md, nil
}

// FileInfo returns the local path and stored MIME type of a downloaded item
// (path validated to exist). Serving must use the stored MIME, not the
// on-disk extension: extFor renders unknown MIME types as .bin, and a .bin
// Content-Type makes clients treat documents as opaque binaries.
func (m *Manager) FileInfo(ctx context.Context, messageRowID int64) (path, mimeType string, err error) {
	row, err := m.store.GetMedia(ctx, messageRowID)
	if err != nil {
		return "", "", err
	}
	if row.State != "downloaded" || row.LocalPath == "" {
		return "", "", storage.ErrNotFound
	}
	if _, err := os.Stat(row.LocalPath); err != nil {
		return "", "", storage.ErrNotFound
	}
	return row.LocalPath, row.MIME, nil
}

// ScheduleEviction coalesces cache checks onto the managed worker.
func (m *Manager) ScheduleEviction() {
	if m.closed.Load() {
		return
	}
	select {
	case m.evictCh <- struct{}{}:
	default:
	}
}

func (m *Manager) evictionLoop() {
	defer m.wg.Done()
	for {
		select {
		case <-m.ctx.Done():
			return
		case <-m.evictCh:
			m.EvictLRU(m.ctx)
		}
	}
}

// EvictLRU removes enough oldest-downloaded items to fit the cache in one
// candidate lookup and one state-clearing transaction.
func (m *Manager) EvictLRU(ctx context.Context) {
	m.cacheMu.Lock()
	defer m.cacheMu.Unlock()
	if m.closed.Load() {
		return
	}

	logger := m.logger()
	total, _, err := m.store.MediaCacheSize(ctx)
	if err != nil {
		logger.Error("media: cache size", "err", err)
		return
	}
	overflow := total - m.maxBytes
	if overflow <= 0 {
		return
	}
	victims, err := m.store.MediaEvictionCandidates(ctx, overflow)
	if err != nil {
		logger.Error("media: evict lookup", "err", err)
		return
	}
	ids := make([]int64, 0, len(victims))
	removed := make([]storage.MediaRow, 0, len(victims))
	for _, victim := range victims {
		if victim.LocalPath != "" {
			if err := os.Remove(victim.LocalPath); err != nil && !errors.Is(err, os.ErrNotExist) {
				logger.Error("media: evict remove", "row", victim.MessageRowID, "err", err)
				continue
			}
		}
		ids = append(ids, victim.MessageRowID)
		removed = append(removed, victim)
	}
	if err := m.store.ClearDownloadedMedia(ctx, ids); err != nil {
		logger.Error("media: evict state", "err", err)
		return
	}
	for _, victim := range removed {
		logger.Info("media: evicted", "row", victim.MessageRowID, "bytes", victim.Size)
	}
}

// ClearAll wipes the cache (logout): files first, then states.
func (m *Manager) ClearAll(ctx context.Context) error {
	m.cacheMu.Lock()
	defer m.cacheMu.Unlock()
	if m.closed.Load() {
		return errors.New("media: manager closed")
	}
	rows, err := m.store.OldestDownloaded(ctx, 100_000)
	if err != nil {
		return err
	}
	for _, r := range rows {
		if r.LocalPath != "" {
			if err := os.Remove(r.LocalPath); err != nil && !errors.Is(err, os.ErrNotExist) {
				// Keep the row claiming the file (stay consistent like
				// EvictLRU); an orphan here is invisible to the cache cap
				// because the caller wipes the media table right after.
				m.logger().Error("media: clear-all remove", "row", r.MessageRowID, "err", err)
				continue
			}
		}
		if err := m.store.SetMediaDownloadedClear(ctx, r.MessageRowID); err != nil {
			m.logger().Error("media: clear-all path", "row", r.MessageRowID, "err", err)
		}
		if err := m.store.SetMediaState(ctx, r.MessageRowID, "not_downloaded"); err != nil {
			m.logger().Error("media: clear-all state", "row", r.MessageRowID, "err", err)
		}
	}
	return nil
}

// ---- internals ----

// joinInflight registers interest in an ongoing download for rowID.
// Returns (wait chan, true) if one is running; (nil, false) if the caller
// becomes the owner (registered by the caller via finishInflight).
func (m *Manager) joinInflight(rowID int64) (<-chan struct{}, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if ch, ok := m.inflight[rowID]; ok {
		return ch, true
	}
	m.inflight[rowID] = make(chan struct{})
	return nil, false
}

func (m *Manager) finishInflight(rowID int64) {
	m.mu.Lock()
	ch, ok := m.inflight[rowID]
	delete(m.inflight, rowID)
	m.mu.Unlock()
	if ok {
		close(ch)
	}
}

func (m *Manager) setState(ctx context.Context, row *storage.MediaRow, state string) {
	if err := m.store.SetMediaState(ctx, row.MessageRowID, state); err != nil {
		m.logger().Error("media: set state", "err", err)
		return
	}
	md := rowMeta(row, row.LocalPath)
	md.State = state
	m.notify(row.MessageRowID, row.ChatJID, md)
}

func (m *Manager) logger() *slog.Logger {
	m.logMu.RLock()
	logger := m.log
	m.logMu.RUnlock()
	return logger
}

func (m *Manager) notify(rowID int64, chatJID string, md core.MediaMeta) {
	if m.onUpdate != nil {
		m.onUpdate(rowID, chatJID, md)
	}
}

// writeAtomic writes bytes into the cache dir via temp file + rename.
func (m *Manager) writeAtomic(row *storage.MediaRow, data []byte) (string, error) {
	name := fmt.Sprintf("%s%s", sanitize(row.MediaID), extFor(row.MIME))
	final := filepath.Join(m.dir, name)
	tmp, err := os.CreateTemp(m.dir, ".tmp-*")
	if err != nil {
		return "", fmt.Errorf("media: temp file: %w", err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // no-op after successful rename
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return "", fmt.Errorf("media: write: %w", err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return "", fmt.Errorf("media: chmod: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("media: close: %w", err)
	}
	if err := os.Rename(tmpName, final); err != nil {
		return "", fmt.Errorf("media: rename: %w", err)
	}
	return final, nil
}

func rowMeta(row *storage.MediaRow, localPath string) core.MediaMeta {
	return core.MediaMeta{
		ID: row.MediaID, Kind: row.Kind, MIME: row.MIME, Size: row.Size,
		State: row.State, LocalPath: localPath,
	}
}

func sanitize(id string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '-':
			return r
		default:
			return '_'
		}
	}, id)
}

func extFor(mimeType string) string {
	mt := strings.ToLower(strings.TrimSpace(mimeType))
	// Explicit picks where the stdlib/host table is wrong, ambiguous, or
	// absent: ExtensionsByType returns the alphabetically-first extension, so
	// a host mime.types can e.g. hand back ".ehtml" for text/html.
	switch mt {
	case "image/jpeg":
		return ".jpg" // stdlib lists .jpe first
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "video/mp4":
		return ".mp4"
	case "audio/ogg", "audio/opus":
		return ".ogg" // WhatsApp voice notes
	case "audio/mpeg":
		return ".mp3"
	case "application/pdf":
		return ".pdf"
	case "text/html":
		return ".html"
	case "text/plain":
		return ".txt"
	case "", "application/octet-stream":
		return ".bin"
	}
	if exts, err := mime.ExtensionsByType(mt); err == nil && len(exts) > 0 {
		return exts[0]
	}
	return ".bin"
}
