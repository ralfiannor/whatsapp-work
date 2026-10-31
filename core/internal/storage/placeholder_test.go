package storage_test

import (
	"context"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

// Decrypt-failure placeholders: born unread with a "waiting" preview, then
// upgraded in place by the re-sent copy — kind, text, media, preview and the
// mention badge follow, unread is not counted twice, and the copy never
// resurrects a row deleted in the meantime.
func TestPlaceholderUpgradesInPlace(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	grp, sender := "1203630000000000@g.us", "6285000000001@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(grp, core.KindGroup, "Sample AC Service")); err != nil {
		t.Fatal(err)
	}
	placeholder := func(id string, ts int64) core.Message {
		return core.Message{MessageID: id, ChatJID: grp, SenderJID: sender, Timestamp: ts,
			Kind: core.KindUnsupported, RawKind: core.RawKindPending, Source: "live"}
	}
	insert := func(m core.Message, want storage.InsertOutcome) core.Message {
		t.Helper()
		got, err := st.InsertMessage(ctx, &m)
		if err != nil || got != want {
			t.Fatalf("insert %s: outcome=%v err=%v, want %v", m.MessageID, got, err, want)
		}
		return m
	}
	chatState := func() *core.Chat {
		t.Helper()
		c, err := st.GetChat(ctx, grp)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}

	p := insert(placeholder("p1", 1700000100), storage.InsertNew)
	if c := chatState(); c.UnreadCount != 1 || c.LastPreview != "Waiting for this message" {
		t.Fatalf("after placeholder: unread=%d preview=%q", c.UnreadCount, c.LastPreview)
	}

	// The phone's copy: a captioned image that mentions us.
	img := core.Message{MessageID: "p1", ChatJID: grp, SenderJID: sender, Timestamp: 1700000100,
		Kind: core.KindImage, Text: "look at this", Source: "live",
		HasMention: true, MentionedJIDs: []string{"254700000001@s.whatsapp.net"},
		Media: &core.MediaMeta{ID: "aa11", Kind: "image", MIME: "image/jpeg", Size: 10,
			DirectPath: "/p", State: "not_downloaded", Proto: []byte("proto")}}
	up := insert(img, storage.InsertUpgraded)
	if up.ID != p.ID {
		t.Fatalf("upgrade wrote row %d, want placeholder row %d", up.ID, p.ID)
	}
	got, err := st.GetMessage(ctx, p.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.Kind != core.KindImage || got.RawKind != "" || got.Text != "look at this" ||
		!got.HasMention || got.Media == nil {
		t.Fatalf("upgraded row = %+v (media %v)", got, got.Media)
	}
	if c := chatState(); c.UnreadCount != 1 || c.MentionedUnread != 1 || c.LastPreview != "look at this" {
		t.Fatalf("after upgrade: unread=%d mentions=%d preview=%q",
			c.UnreadCount, c.MentionedUnread, c.LastPreview)
	}
	insert(img, storage.InsertDuplicate) // a second copy changes nothing
	if c := chatState(); c.MentionedUnread != 1 {
		t.Fatalf("second copy re-counted the mention: %d", c.MentionedUnread)
	}

	// A copy the core cannot render still replaces "waiting" with its kind.
	insert(placeholder("p2", 1700000200), storage.InsertNew)
	insert(core.Message{MessageID: "p2", ChatJID: grp, SenderJID: sender, Timestamp: 1700000200,
		Kind: core.KindUnsupported, RawKind: "poll", Source: "live"}, storage.InsertUpgraded)
	if c := chatState(); c.LastPreview != "Poll" {
		t.Fatalf("poll copy preview = %q", c.LastPreview)
	}

	// Never downgrade: a placeholder for a row we already have is a no-op.
	real := msg("t1", grp, sender, false, 1700000300, "already here")
	insert(real, storage.InsertNew)
	insert(placeholder("t1", 1700000300), storage.InsertDuplicate)
	if rows, _ := st.ListMessages(ctx, grp, 0, 0, 10); rows[0].Kind != core.KindText || rows[0].Text != "already here" {
		t.Fatalf("placeholder downgraded a real row: %+v", rows[0])
	}

	// Deleted while waiting: the late copy must not bring the text back.
	insert(placeholder("d1", 1700000400), storage.InsertNew)
	if err := st.SetRevoked(ctx, grp, "d1", sender, 1700000401); err != nil {
		t.Fatal(err)
	}
	insert(msg("d1", grp, sender, false, 1700000400, "secret"), storage.InsertDuplicate)
	if hits, err := st.SearchMessages(ctx, "secret", 10); err != nil || len(hits) != 0 {
		t.Fatalf("revoked row resurfaced in search: %v %v", hits, err)
	}
}
