// M3 IPC contract:
//   - POST /media/{rowid}/download triggers on-demand fetch, returns the message
//   - GET  /media/{rowid}/file serves the cached bytes with the stored MIME type
package ipc_test

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

type fakeMedia struct{}

func (fakeMedia) EnsureDownloaded(ctx context.Context, rowID int64) (*core.MediaMeta, error) {
	return &core.MediaMeta{
		ID: fmt.Sprintf("hex-%d", rowID), Kind: "image", MIME: "image/jpeg",
		Size: 3, State: "downloaded", LocalPath: mediaFileFor(rowID),
	}, nil
}

// Adversarial on purpose: bytes sit in a .bin file while the stored MIME is
// image/jpeg. The handler must set Content-Type from the stored MIME —
// extension sniffing serves application/octet-stream for every document whose
// type fell outside the on-disk naming table.
func (fakeMedia) FileInfo(ctx context.Context, rowID int64) (string, string, error) {
	if rowID == 999 {
		return "", "", storage.ErrNotFound // mimic: unknown row / not downloaded
	}
	return mediaFileFor(rowID), "image/jpeg", nil
}

func (fakeMedia) ClearAll(ctx context.Context) error { return nil }

func mediaFileFor(rowID int64) string {
	return filepath.Join(os.TempDir(), fmt.Sprintf("wf-ipc-media-%d.bin", rowID))
}

func TestMediaEndpoints(t *testing.T) {
	e := newEnv(t)
	// Seed a real message; its rowid drives both endpoints (the fake media
	// service resolves any row, the app still validates the message exists).
	code, res := e.post("/messages", fmt.Sprintf(`{"chat_jid":%q,"text":"pic"}`, alice))
	if code != http.StatusCreated {
		t.Fatalf("seed message = %d %v", code, res)
	}
	// POST /messages returns the message object itself.
	rowID := int(res["id"].(float64))

	// Bytes on disk where the fake service claims them.
	body := []byte{0xFF, 0xD8, 0xFF}
	mediaPath := mediaFileFor(int64(rowID))
	if err := os.WriteFile(mediaPath, body, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(mediaPath) })

	code, body2 := e.post(fmt.Sprintf("/media/%d/download", rowID), "")
	if code != http.StatusOK {
		t.Fatalf("download = %d %v", code, body2)
	}
	msg := body2["message"].(map[string]any)
	media := msg["media"].(map[string]any)
	if media["state"] != "downloaded" || media["mime"] != "image/jpeg" {
		t.Fatalf("media payload = %v", media)
	}

	req, _ := http.NewRequest("GET", fmt.Sprintf("%s/media/%d/file", e.srv.URL, rowID), nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("file = %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "image/jpeg" {
		t.Fatalf("content-type = %q", ct)
	}
	got, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(body) || got[0] != body[0] || got[2] != body[2] {
		t.Fatalf("served bytes differ: %v", got)
	}

	// Unknown row → 404.
	code, _ = e.get("/media/999/file")
	if code != http.StatusNotFound {
		t.Fatalf("missing media file = %d, want 404", code)
	}
	code, _ = e.post("/media/999/download", "")
	if code != http.StatusNotFound {
		t.Fatalf("missing media download = %d, want 404", code)
	}
}
