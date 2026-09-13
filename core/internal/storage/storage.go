// Package storage is the SQLite persistence layer: migrations, chat/message
// repositories, keyset pagination and FTS5 search.
//
// Concurrency model: one write connection + a small read pool against the
// same WAL database (docs/schema.md). Everything a write path needs for one
// message happens in a single transaction so rows, counters, preview and the
// FTS index can never diverge.
package storage

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	_ "modernc.org/sqlite"
)

// ensureOwnerOnly pins the database file to 0600: it holds conversation
// plaintext, and files created by older builds (umask 022) are 0644.
// sqlite keeps the mode of a pre-created file; new -wal/-shm sidecars are
// covered by the sidecar's umask(077).
func ensureOwnerOnly(path string) error {
	if _, err := os.Stat(path); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
		if err != nil {
			return err
		}
		return f.Close()
	}
	return os.Chmod(path, 0o600)
}

const pragmas = "_pragma=busy_timeout(5000)" +
	"&_pragma=journal_mode(WAL)" +
	"&_pragma=synchronous(NORMAL)" +
	"&_pragma=foreign_keys(ON)" +
	"&_pragma=cache_size(-16000)"

// Store owns the app.db handles.
type Store struct {
	w   *sql.DB // single writer
	r   *sql.DB // read pool
	log *slog.Logger
	dsn string
}

// Open creates/opens <dir>/app.db and applies migrations. dir is created if
// missing with 0700 — it holds conversation plaintext (R12).
func Open(ctx context.Context, dir string, log *slog.Logger) (*Store, error) {
	if log == nil {
		log = slog.Default()
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("storage: mkdir: %w", err)
	}
	path := filepath.Join(dir, "app.db")
	if err := ensureOwnerOnly(path); err != nil {
		return nil, fmt.Errorf("storage: secure db file: %w", err)
	}
	// No "file:" URI scheme on purpose: modernc strips the ?query from a plain
	// path DSN and opens the remainder verbatim, which keeps paths with spaces
	// (e.g. "Application Support") working without URI escaping.
	dsn := path + "?" + pragmas

	w, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("storage: open writer: %w", err)
	}
	w.SetMaxOpenConns(1) // SQLite single writer; serializes all writes
	w.SetMaxIdleConns(1)

	r, err := sql.Open("sqlite", dsn)
	if err != nil {
		w.Close()
		return nil, fmt.Errorf("storage: open reader: %w", err)
	}
	r.SetMaxOpenConns(4)
	r.SetMaxIdleConns(4)

	s := &Store{w: w, r: r, log: log, dsn: path}
	if err := s.ping(ctx); err != nil {
		s.Close()
		return nil, err
	}
	if err := s.migrate(ctx); err != nil {
		s.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) ping(ctx context.Context) error {
	if err := s.w.PingContext(ctx); err != nil {
		return fmt.Errorf("storage: ping writer: %w", err)
	}
	if err := s.r.PingContext(ctx); err != nil {
		return fmt.Errorf("storage: ping reader: %w", err)
	}
	return nil
}

// Ping is the health probe.
func (s *Store) Ping(ctx context.Context) error { return s.ping(ctx) }

// DSN returns the database file path (diagnostics/READY line).
func (s *Store) DSN() string { return s.dsn }

// Close closes both handles.
func (s *Store) Close() error {
	errW := s.w.Close()
	errR := s.r.Close()
	if errW != nil {
		return errW
	}
	return errR
}
