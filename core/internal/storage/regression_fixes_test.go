// Regression tests for the pre-publication bug audit (2026-09-13):
//   - a revoked unread message must give its unread/mention counter bump back
//   - an edit with no parsable text (media caption edit) must not wipe the row
//   - an out-of-order read_self receipt must not hide newer unread traffic
//   - Done on an unknown chat must 404 like its sibling mutations
package storage_test

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func TestSetRevokedDecrementsUnreadCounters(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "254700000002@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "")); err != nil {
		t.Fatal(err)
	}
	m := msg("rv1", jid, jid, false, 1700000100, "about to vanish")
	m.HasMention = true
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if c, _ := st.GetChat(ctx, jid); c == nil || c.UnreadCount != 1 || c.MentionedUnread != 1 {
		t.Fatalf("unread before revoke = %+v", c)
	}
	if err := st.SetRevoked(ctx, jid, "rv1", jid, 1700000200); err != nil {
		t.Fatal(err)
	}
	c, err := st.GetChat(ctx, jid)
	if err != nil {
		t.Fatal(err)
	}
	if c.UnreadCount != 0 || c.MentionedUnread != 0 {
		t.Fatalf("unread after revoke = %d/%d, want 0/0", c.UnreadCount, c.MentionedUnread)
	}
}

func TestSetEditedEmptyTextKeepsStoredText(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "254700000002@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "")); err != nil {
		t.Fatal(err)
	}
	m := msg("ed1", jid, jid, false, 1700000100, "original caption")
	m.Kind = core.KindImage
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	// A media caption edit arrives as the media payload itself; textOf
	// yields "" — the stored caption must survive.
	if err := st.SetEdited(ctx, jid, jid, "ed1", "", 1700000200, false, nil); err != nil {
		t.Fatal(err)
	}
	got, err := st.GetMessage(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Text != "original caption" {
		t.Fatalf("text after empty edit = %q, want the original caption", got.Text)
	}
}

func TestMarkChatReadOlderReceiptKeepsCounters(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "254700000002@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "")); err != nil {
		t.Fatal(err)
	}
	if _, err := st.InsertMessage(ctx, msgPtr("o1", jid, 1700000100, "read early")); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkChatRead(ctx, jid, 1700000200); err != nil {
		t.Fatal(err)
	}
	if _, err := st.InsertMessage(ctx, msgPtr("o2", jid, 1700000300, "unread one")); err != nil {
		t.Fatal(err)
	}
	if _, err := st.InsertMessage(ctx, msgPtr("o3", jid, 1700000400, "unread two")); err != nil {
		t.Fatal(err)
	}
	// Out-of-order read_self receipt covering only the already-read prefix
	// (older than the current read position).
	if err := st.MarkChatRead(ctx, jid, 1700000150); err != nil {
		t.Fatal(err)
	}
	c, err := st.GetChat(ctx, jid)
	if err != nil {
		t.Fatal(err)
	}
	if c.UnreadCount != 2 {
		t.Fatalf("unread after older receipt = %d, want 2", c.UnreadCount)
	}
	// An advancing receipt still zeroes.
	if err := st.MarkChatRead(ctx, jid, 1700000500); err != nil {
		t.Fatal(err)
	}
	if c, _ = st.GetChat(ctx, jid); c.UnreadCount != 0 {
		t.Fatalf("unread after advancing receipt = %d, want 0", c.UnreadCount)
	}
}

func TestSetChatDoneUnknownChatIsNotFound(t *testing.T) {
	st := openTestStore(t)
	err := st.SetChatDone(context.Background(), "404-404@g.us", true)
	if !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}

// A revoke replayed by history re-sync must not decrement the unread
// counters a second time (SQLite counts matched rows on no-op updates).
func TestSetRevokedIsIdempotent(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "254700000003@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "")); err != nil {
		t.Fatal(err)
	}
	m1 := msgPtr("idem1", jid, 1700000100, "one")
	m2 := msgPtr("idem2", jid, 1700000200, "two")
	if _, err := st.InsertMessage(ctx, m1); err != nil {
		t.Fatal(err)
	}
	if _, err := st.InsertMessage(ctx, m2); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ { // live revoke + history replays
		if err := st.SetRevoked(ctx, jid, "idem1", jid, 1700000300); err != nil {
			t.Fatal(err)
		}
	}
	c, err := st.GetChat(ctx, jid)
	if err != nil {
		t.Fatal(err)
	}
	if c.UnreadCount != 1 {
		t.Fatalf("unread after revoke replays = %d, want 1 (only idem2)", c.UnreadCount)
	}
}

// Chat previews are re-serialized on every /chats fetch and chat.updated
// event — a hostile long body must never pin megabytes into the row.
func TestPreviewIsClamped(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "254700000004@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "")); err != nil {
		t.Fatal(err)
	}
	long := strings.Repeat("あ", 500) // multibyte: byte-slicing would split runes
	m := msg("pv1", jid, jid, false, 1700000100, long)
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	c, err := st.GetChat(ctx, jid)
	if err != nil {
		t.Fatal(err)
	}
	if runes := len([]rune(c.LastPreview)); runes > 96 {
		t.Fatalf("preview = %d runes, want ≤ 96", runes)
	}
}

func msgPtr(id, jid string, ts int64, text string) *core.Message {
	m := msg(id, jid, jid, false, ts, text)
	return &m
}
