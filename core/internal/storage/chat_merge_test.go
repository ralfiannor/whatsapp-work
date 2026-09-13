// Regression tests for the split-thread bug: a direct chat the server moved
// to LID addressing spawned a second chat row for the same contact.
// MergeLIDChats folds the LID-keyed chat into its phone twin.
package storage_test

import (
	"context"
	"errors"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func TestMergeLIDChatsFoldsDuplicateThread(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	me := "254700000001@s.whatsapp.net"
	pn := "254799000111@s.whatsapp.net"
	lid := "999000111222333@lid"

	for _, jid := range []string{pn, lid} {
		if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "Bot")); err != nil {
			t.Fatal(err)
		}
	}
	// The bug as shipped: outgoing in the phone thread, the peer's
	// LID-addressed reply in a separate row with an already-canonical sender.
	out := msg("m1", pn, me, true, 1700000000, "pasar")
	reply := msg("m2", lid, pn, false, 1700000008, "Ah, datang ke pasar ya?")
	for _, m := range []*core.Message{&out, &reply} {
		if _, err := st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	if err := st.MarkChatRead(ctx, pn, 1700000000); err != nil {
		t.Fatal(err)
	}

	merged, err := st.MergeLIDChats(ctx, map[string]string{lid: pn})
	if err != nil || len(merged) != 1 || merged[lid] != pn {
		t.Fatalf("merge: merged=%v err=%v", merged, err)
	}

	// Messages all live in the phone thread now.
	if _, err := st.LookupMessageRow(ctx, pn, "m1"); err != nil {
		t.Fatalf("outgoing lost: %v", err)
	}
	if _, err := st.LookupMessageRow(ctx, pn, "m2"); err != nil {
		t.Fatalf("reply not moved: %v", err)
	}
	if _, err := st.LookupMessageRow(ctx, lid, "m2"); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("LID twin still reachable: %v", err)
	}

	// The LID chat row is gone; the phone chat carries the newest state.
	if _, err := st.GetChat(ctx, lid); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("LID chat row survives: %v", err)
	}
	c, err := st.GetChat(ctx, pn)
	if err != nil {
		t.Fatal(err)
	}
	if c.LastMessageID != "m2" || c.LastMessageTS != 1700000008 {
		t.Fatalf("last-message projection stale: %+v", c)
	}
	if c.UnreadCount != 1 {
		t.Fatalf("unread = %d, want 1 (reply after read pos)", c.UnreadCount)
	}

	// FTS still finds the moved reply under the phone chat.
	hits, err := st.SearchMessages(ctx, "pasar", 10)
	if err != nil {
		t.Fatal(err)
	}
	var found bool
	for _, h := range hits {
		if h.MessageID == "m2" && h.ChatJID == pn {
			found = true
		}
	}
	if !found {
		t.Fatalf("moved reply not searchable: %+v", hits)
	}

	// Idempotent: a second pass is a no-op.
	if n, err := st.MergeLIDChats(ctx, map[string]string{lid: pn}); err != nil || len(n) != 0 {
		t.Fatalf("second merge: merged=%v err=%v", n, err)
	}
}

// A LID-only chat (peer never seen under their phone JID) must still fold:
// the phone chat row is created on demand so messages are never orphaned.
func TestMergeLIDChatsCreatesPhoneRow(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	pn := "254799000222@s.whatsapp.net"
	lid := "999000111222444@lid"

	if err := st.EnsureChat(ctx, chat(lid, core.KindDirect, "Peer")); err != nil {
		t.Fatal(err)
	}
	m := msg("m1", lid, pn, false, 1700000001, "hi")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}

	if merged, err := st.MergeLIDChats(ctx, map[string]string{lid: pn}); err != nil || len(merged) != 1 {
		t.Fatalf("merge: merged=%v err=%v", merged, err)
	}
	c, err := st.GetChat(ctx, pn)
	if err != nil {
		t.Fatalf("phone chat row missing: %v", err)
	}
	if c.Kind != core.KindDirect || c.DisplayName != "Peer" {
		t.Fatalf("phone chat wrong: %+v", c)
	}
	if _, err := st.LookupMessageRow(ctx, pn, "m1"); err != nil {
		t.Fatalf("message orphaned: %v", err)
	}
}
