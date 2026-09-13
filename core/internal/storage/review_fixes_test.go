// Regression tests for the full-codebase review fixes:
//   - receipts only ever advance (read never regresses to delivered)
//   - re-delivered messages keep a finished media download
//   - chat-list keyset pagination survives timestamp ties
package storage_test

import (
	"context"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func TestReceiptNeverDowngrades(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	peer := "p@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(peer, core.KindDirect, "P")); err != nil {
		t.Fatal(err)
	}
	m := msg("m1", peer, peer, true, 1700000000, "outgoing")
	m.ReceiptStatus = "sent"
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}

	upd, err := st.UpdateReceiptStatus(ctx, peer, peer, []string{"m1"}, "read")
	if err != nil || len(upd) != 1 {
		t.Fatalf("read receipt not applied: %+v err=%v", upd, err)
	}
	// A late batched "delivered" must NOT regress the read state.
	upd, err = st.UpdateReceiptStatus(ctx, peer, peer, []string{"m1"}, "delivered")
	if err != nil {
		t.Fatal(err)
	}
	if len(upd) != 0 {
		t.Fatalf("downgrade applied: %+v", upd)
	}
	got, err := st.GetMessage(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if got.ReceiptStatus != "read" {
		t.Fatalf("receipt status = %q, want read", got.ReceiptStatus)
	}
}

func TestRedeliveryKeepsDownloadedMedia(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "m@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "M")); err != nil {
		t.Fatal(err)
	}
	m := msg("mm1", jid, jid, false, 1700000000, "")
	m.Kind = core.KindImage
	m.Media = &core.MediaMeta{Kind: "image", MIME: "image/jpeg", Size: 10, URL: "u1", DirectPath: "/p1"}
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMediaDownloaded(ctx, m.ID, "/cache/x.jpg", 10); err != nil {
		t.Fatal(err)
	}

	// Same message re-delivered (fresh URL, default state) — download must win.
	m2 := m
	m2.Media = &core.MediaMeta{Kind: "image", MIME: "image/jpeg", Size: 10, URL: "u2", DirectPath: "/p2"}
	if _, err := st.InsertMessage(ctx, &m2); err != nil {
		t.Fatal(err)
	}
	md, err := st.GetMedia(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if md.State != "downloaded" || md.LocalPath == "" {
		t.Fatalf("media state = %q path=%q, want downloaded with path", md.State, md.LocalPath)
	}
}

func TestListChatsTiebreakPagination(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	const ts = int64(1700000000)
	// Many chats sharing one timestamp — the old bare-ts cursor skipped all
	// but the first of them.
	for _, jid := range []string{"c1@s.whatsapp.net", "c2@s.whatsapp.net", "c3@s.whatsapp.net"} {
		if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, jid)); err != nil {
			t.Fatal(err)
		}
		m := msg("m-"+jid, jid, jid, false, ts, "hi")
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
	}

	var seen []string
	var cursorTS int64
	var cursorJID string
	for page := 0; page < 5; page++ {
		chats, err := st.ListChats(ctx, 2, cursorTS, cursorJID, storage.FilterAll)
		if err != nil {
			t.Fatal(err)
		}
		if len(chats) == 0 {
			break
		}
		for _, c := range chats {
			seen = append(seen, c.JID)
		}
		last := chats[len(chats)-1]
		cursorTS, cursorJID = last.LastMessageTS, last.JID
		if len(chats) < 2 {
			break
		}
	}
	for _, want := range []string{"c1@s.whatsapp.net", "c2@s.whatsapp.net", "c3@s.whatsapp.net"} {
		found := false
		for _, s := range seen {
			if s == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("chat %s missing from pages: %v", want, seen)
		}
	}
}

// Regression: the same logical message ingested twice (raw-LID sender before
// the mapping was learned, then canonical PN) used to survive as two rows —
// the rewrite UPDATE hit UNIQUE(chat, sender, message_id), errored, and
// aborted the whole pass, leaving hundreds of duplicates. The LID twin must
// be deleted when its PN twin exists; standalone LID rows get rewritten.
func TestRewriteSenderJIDsDedupesLIDTwin(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	lid := "100000000000001@lid"
	pn := "6281234500001@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(lid, core.KindDirect, "")); err != nil {
		t.Fatal(err)
	}
	m1 := msg("M1", lid, pn, false, 1700000100, "AC technician crew")
	if _, err := st.InsertMessage(ctx, &m1); err != nil {
		t.Fatal(err)
	}
	twin := msg("M1", lid, lid, false, 1700000100, "AC technician crew")
	if _, err := st.InsertMessage(ctx, &twin); err != nil {
		t.Fatal(err)
	}
	m2 := msg("M2", lid, lid, false, 1700000200, "standalone message without a twin")
	if _, err := st.InsertMessage(ctx, &m2); err != nil {
		t.Fatal(err)
	}

	n, err := st.RewriteSenderJIDs(ctx, map[string]string{lid: pn})
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("rewritten rows = %d, want 1 (only the standalone twin)", n)
	}

	msgs, err := st.ListMessages(ctx, lid, 0, 0, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(msgs) != 2 {
		t.Fatalf("rows after dedupe = %d, want 2", len(msgs))
	}
	seen := map[string]bool{}
	for _, m := range msgs {
		if m.SenderJID != pn {
			t.Fatalf("row %s still carries LID sender: %q", m.MessageID, m.SenderJID)
		}
		if seen[m.MessageID] {
			t.Fatalf("message %s still duplicated", m.MessageID)
		}
		seen[m.MessageID] = true
	}

	// The deleted twin's FTS row must go with it (delete trigger).
	hits, err := st.SearchMessages(ctx, "technician", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 {
		t.Fatalf("FTS hits after dedupe = %d, want 1", len(hits))
	}
}

// DeriveSenderMappings recovers lid→PN pairs from rows stored under both
// sender forms — the only mapping source for accounts whatsmeow never saw
// carry SenderAlt (business senders).
func TestDeriveSenderMappings(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	lid := "100000000000002@lid"
	pn := "6281234500002@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(lid, core.KindDirect, "")); err != nil {
		t.Fatal(err)
	}
	m1 := msg("D1", lid, lid, false, 1700000100, "first ingested under the lid form")
	if _, err := st.InsertMessage(ctx, &m1); err != nil {
		t.Fatal(err)
	}
	m2 := msg("D1", lid, pn, false, 1700000100, "first ingested under the lid form")
	if _, err := st.InsertMessage(ctx, &m2); err != nil {
		t.Fatal(err)
	}

	got := map[string]string{}
	if err := st.DeriveSenderMappings(ctx, got); err != nil {
		t.Fatal(err)
	}
	if got[lid] != pn {
		t.Fatalf("derived[%q] = %q, want %q", lid, got[lid], pn)
	}
}
