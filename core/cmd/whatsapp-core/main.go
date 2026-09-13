// Command whatsapp-core is the Go sidecar bundled inside WhatsAppWork.app.
//
// Lifecycle contract (docs/architecture.md §6): it takes an exclusive flock
// on <data-dir>/core.lock, starts the IPC server on a random 127.0.0.1 port,
// prints one READY JSON line with the port and bearer token on stdout, and
// shuts down cleanly on SIGINT/SIGTERM.
//
// Exit codes: 0 clean · 2 lock held · 3 storage fatal · 4 bad flags.
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"syscall"
	"time"

	"github.com/mdp/qrterminal/v3"

	"github.com/ralfiannor/whatsapp-work/internal/app"
	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/events"
	"github.com/ralfiannor/whatsapp-work/internal/ipc"
	"github.com/ralfiannor/whatsapp-work/internal/media"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
	"github.com/ralfiannor/whatsapp-work/internal/whatsapp"
)

const version = "0.1.0"

func main() {
	// Owner-only files regardless of inherited umask: the data dir holds
	// conversation plaintext and pairing credentials (R12), including the
	// -wal/-shm sidecars sqlite creates on its own.
	syscall.Umask(0o077)

	home, _ := os.UserHomeDir()
	defaultDir := filepath.Join(home, "Library", "Application Support", "WhatsAppWork")

	var dataDir string
	var mediaCacheMB int
	var showVersion bool
	flag.StringVar(&dataDir, "data-dir", defaultDir, "data directory (databases, media cache)")
	flag.IntVar(&mediaCacheMB, "media-cache-mb", 500, "media cache cap in megabytes (LRU-evicted)")
	flag.BoolVar(&showVersion, "version", false, "print version and exit")
	flag.Parse()
	if showVersion {
		fmt.Println(version)
		return
	}

	// Modest ceiling for the Go side; the app tracks the full budget.
	debug.SetMemoryLimit(64 << 20)

	logger := slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	if err := run(dataDir, mediaCacheMB, logger); err != nil {
		logger.Error("fatal", "err", err)
		var exitCode int
		switch {
		case errors.Is(err, errLockHeld):
			exitCode = 2
		case errors.Is(err, errStorage):
			exitCode = 3
		default:
			exitCode = 1
		}
		os.Exit(exitCode)
	}
}

var (
	errLockHeld = errors.New("another whatsapp-core holds the lock")
	errStorage  = errors.New("storage failure")
)

func run(dataDir string, mediaCacheMB int, logger *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return fmt.Errorf("data dir: %w", err)
	}
	release, err := acquireLock(filepath.Join(dataDir, "core.lock"))
	if err != nil {
		return err
	}
	defer release()

	st, err := storage.Open(ctx, dataDir, logger)
	if err != nil {
		return fmt.Errorf("%w: %v", errStorage, err)
	}
	defer st.Close()

	wa, err := whatsapp.New(ctx, dataDir, logger)
	if err != nil {
		return fmt.Errorf("whatsapp adapter: %w", err)
	}

	disp := events.NewDispatcher()
	application := app.New(logger, st, wa, disp)
	if err := application.Run(ctx); err != nil {
		return err
	}

	// Media: on-demand downloads into a bounded LRU cache.
	mediaMgr, err := media.New(st, wa, filepath.Join(dataDir, "media"),
		int64(mediaCacheMB)<<20, 2, application.MediaUpdateSink)
	if err != nil {
		return fmt.Errorf("media manager: %w", err)
	}
	defer mediaMgr.Close()
	mediaMgr.SetLogger(logger)
	application.SetMediaService(mediaMgr)
	mediaMgr.EvictLRU(ctx) // reconcile the on-disk cache with the cap after restarts

	// QR codes also render in the terminal (stderr) for CLI smoke tests.
	printQRTerminal(disp, logger)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	token := newToken()
	srv := ipc.New(application, disp, token, version, logger)
	serveErr := make(chan error, 1)
	go func() { serveErr <- srv.Serve(ln) }()

	port := ln.Addr().(*net.TCPAddr).Port
	ready := map[string]any{
		"event":   "ready",
		"port":    port,
		"token":   token,
		"pid":     os.Getpid(),
		"version": version,
		"db":      st.DSN(),
	}
	readyJSON, _ := json.Marshal(ready)
	fmt.Fprintln(os.Stdout, string(readyJSON)) // handshake for the Swift parent

	logger.Info("core ready", "port", port, "version", version)

	// With a stored session, connect immediately; otherwise wait for
	// POST /session/link from the UI.
	if wa.LoggedIn() {
		if err := wa.Connect(ctx); err != nil {
			logger.Error("initial connect failed; auto-reconnect will retry", "err", err)
		}
	}

	select {
	case <-ctx.Done():
		logger.Info("shutting down")
	case err := <-serveErr:
		if err != nil {
			return fmt.Errorf("ipc serve: %w", err)
		}
	}

	shCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shCtx)
	wa.Disconnect()
	_ = mediaMgr.Close()
	_ = st.Close()
	return nil
}

// acquireLock takes an exclusive flock; a held lock means a stale core.
func acquireLock(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("lock file: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("%w: %s", errLockHeld, path)
	}
	return func() {
		syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
	}, nil
}

func newToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand unavailable: " + err.Error())
	}
	return hex.EncodeToString(b)
}

func printQRTerminal(disp *events.Dispatcher, logger *slog.Logger) {
	id, ch := disp.Subscribe(8)
	go func() {
		for ev := range ch {
			if ev.Type != "session.qr" {
				continue
			}
			qr, ok := ev.Data.(*core.QRInfo)
			if !ok {
				continue
			}
			// Terminal QR only when run by a human (stderr is a TTY). When
			// piped into the app it would land in core.log — a live pairing
			// credential written to disk.
			if fi, err := os.Stderr.Stat(); err == nil && fi.Mode()&os.ModeCharDevice != 0 {
				logger.Info("new QR code (scan with WhatsApp → Linked Devices)")
				qrterminal.GenerateWithConfig(qr.Code, qrterminal.Config{
					Level: qrterminal.L, Writer: os.Stderr, HalfBlocks: true, QuietZone: 1,
				})
			}
		}
		_ = id
	}()
}
