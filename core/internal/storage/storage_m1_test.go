// M1 storage contract:
//   - InsertMessages ingests a history batch in shared transactions: idempotent,
//     no unread bumps (history is always "already read"), preview advances,
//     FTS populated, media rows persisted
//   - RefreshDirectChatNames backfills display names from the contacts table
//   - MaxTimestampOf resolves receipt message ids to a read position
package storage_test

import (
	"context"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

func TestInsertMessagesBatch(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}

	h1 := msg("h1", jid, jid, false, 1700000100, "first history")
	h1.Source = "history"
	h3 := msg("h3", jid, jid, false, 1700000300, "last history")
	h3.Source = "history"
	batch := []core.Message{
		h1,
		{MessageID: "h2", ChatJID: jid, SenderJID: jid, Timestamp: 1700000200,
			Kind: core.KindImage, Text: "caption text", Source: "history",
			Media: &core.MediaMeta{Kind: "image", MIME: "image/jpeg", Size: 10, URL: "u", DirectPath: "/p"}},
		h3,
	}

	inserted, err := st.InsertMessages(ctx, batch)
	if err != nil {
		t.Fatal(err)
	}
	if inserted != 3 {
		t.Fatalf("inserted = %d, want 3", inserted)
	}

	// Re-running the same batch must be a no-op.
	inserted, err = st.InsertMessages(ctx, batch)
	if err != nil || inserted != 0 {
		t.Fatalf("replay: inserted=%d err=%v, want 0/nil", inserted, err)
	}

	msgs, err := st.ListMessages(ctx, jid, 0, 0, 50)
	if err != nil || len(msgs) != 3 {
		t.Fatalf("rows = %d err=%v, want 3", len(msgs), err)
	}
	c, _ := st.GetChat(ctx, jid)
	if c.UnreadCount != 0 {
		t.Fatalf("history inflated unread: %d", c.UnreadCount)
	}
	if c.LastMessageID != "h3" || c.LastPreview != "last history" {
		t.Fatalf("preview after batch = %s/%s", c.LastMessageID, c.LastPreview)
	}
	if msgs[1].Media == nil || msgs[1].Media.MIME != "image/jpeg" {
		t.Fatalf("media row missing in batch: %+v", msgs[1].Media)
	}
	if hits, _ := st.SearchMessages(ctx, "caption", 10); len(hits) != 1 {
		t.Fatalf("FTS not populated by batch: %v", hits)
	}
}

func TestRefreshDirectChatNames(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	if err := st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "+254700000002")); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureChat(ctx, chat("g@g.us", core.KindGroup, "Team")); err != nil {
		t.Fatal(err)
	}
	if _, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "a@s.whatsapp.net", FullName: "Alice Smith"},
	}); err != nil {
		t.Fatal(err)
	}

	changed, err := st.RefreshDirectChatNames(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) != 1 || changed[0] != "a@s.whatsapp.net" {
		t.Fatalf("changed jids = %v, want [a@s.whatsapp.net]", changed)
	}
	c, _ := st.GetChat(ctx, "a@s.whatsapp.net")
	if c.DisplayName != "Alice Smith" {
		t.Fatalf("direct chat name = %q, want Alice Smith", c.DisplayName)
	}
	g, _ := st.GetChat(ctx, "g@g.us")
	if g.DisplayName != "Team" {
		t.Fatalf("group name must not be touched: %q", g.DisplayName)
	}

	// Idempotent: a second pass with no drift reports no changes.
	changed, err = st.RefreshDirectChatNames(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) != 0 {
		t.Fatalf("second pass changed = %v, want none", changed)
	}

	// Push-name titles are replaced once the full name lands (the regression:
	// chats named by push name were never revisited by the names pass).
	if _, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "b@s.whatsapp.net", FullName: "Bob Jones", PushName: "bobby"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureChat(ctx, chat("b@s.whatsapp.net", core.KindDirect, "bobby")); err != nil {
		t.Fatal(err)
	}
	changed, err = st.RefreshDirectChatNames(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(changed) != 1 || changed[0] != "b@s.whatsapp.net" {
		t.Fatalf("push-name chat changed = %v, want [b@s.whatsapp.net]", changed)
	}
	if c, _ := st.GetChat(ctx, "b@s.whatsapp.net"); c.DisplayName != "Bob Jones" {
		t.Fatalf("push-name title not upgraded: %q", c.DisplayName)
	}
}

func TestMaxTimestampOf(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	for i, id := range []string{"m1", "m2"} {
		m := msg(id, jid, jid, false, int64(1700000100+i), "x")
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
	}
	ts, err := st.MaxTimestampOf(ctx, jid, []string{"m1", "m2", "unknown"})
	if err != nil {
		t.Fatal(err)
	}
	if ts != 1700000101 {
		t.Fatalf("max ts = %d, want 1700000101", ts)
	}
	if ts, _ := st.MaxTimestampOf(ctx, jid, nil); ts != 0 {
		t.Fatalf("empty ids = %d, want 0", ts)
	}
}

func TestSharedMediaAcrossMessages(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	for i, id := range []string{"m1", "m2"} {
		m := core.Message{
			MessageID: id, ChatJID: jid, SenderJID: jid, Timestamp: int64(1700000100 + i),
			Kind: core.KindImage, Source: "history", MentionedJIDs: []string{},
			Media: &core.MediaMeta{ // same file forwarded twice → same hash
				Kind: "image", MIME: "image/jpeg", Size: 5,
				FileEncSHA256: []byte{9, 9, 9}, URL: "u", DirectPath: "/p",
			},
		}
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatalf("forwarded media broke insert %s: %v", id, err)
		}
	}
}

func TestRedeliveryEscalatesUnsupported(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	// First delivery: encryption envelope only, no readable content.
	m1 := core.Message{MessageID: "r1", ChatJID: jid, SenderJID: jid,
		Timestamp: 1700000100, Kind: core.KindUnsupported, RawKind: "skdm",
		Source: "history", MentionedJIDs: []string{}}
	if _, err := st.InsertMessage(ctx, &m1); err != nil {
		t.Fatal(err)
	}
	// Retry: full content arrives under the same stanza id.
	m2 := core.Message{MessageID: "r1", ChatJID: jid, SenderJID: jid,
		Timestamp: 1700000100, Kind: core.KindText, Text: "real content",
		Source: "history", MentionedJIDs: []string{}}
	if _, err := st.InsertMessage(ctx, &m2); err != nil {
		t.Fatal(err)
	}
	got, _ := st.ListMessages(ctx, jid, 0, 0, 10)
	if len(got) != 1 || got[0].Kind != core.KindText || got[0].Text != "real content" {
		t.Fatalf("re-delivery did not escalate: %+v", got)
	}
}

func TestEnsureChatNameStability(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "g@g.us"

	must := func(name string) core.Chat { return core.Chat{JID: jid, Kind: core.KindGroup, DisplayName: name} }

	// Empty → real name adopted.
	if err := st.EnsureChat(ctx, must("Team Backend")); err != nil {
		t.Fatal(err)
	}
	c, _ := st.GetChat(ctx, jid)
	if c.DisplayName != "Team Backend" {
		t.Fatalf("adopt failed: %q", c.DisplayName)
	}

	// Identifier forms must NEVER overwrite a real name.
	for _, bad := range []string{"g@g.us", "+628123", "Group g"} {
		if err := st.EnsureChat(ctx, must(bad)); err != nil {
			t.Fatal(err)
		}
		c, _ = st.GetChat(ctx, jid)
		if c.DisplayName != "Team Backend" {
			t.Fatalf("identifier %q overwrote name: %q", bad, c.DisplayName)
		}
	}

	// Empty never overwrites.
	if err := st.EnsureChat(ctx, must("")); err != nil {
		t.Fatal(err)
	}
	c, _ = st.GetChat(ctx, jid)
	if c.DisplayName != "Team Backend" {
		t.Fatalf("empty overwrote name: %q", c.DisplayName)
	}

	// A genuinely different real name updates (real subject change).
	if err := st.EnsureChat(ctx, must("Team Frontend")); err != nil {
		t.Fatal(err)
	}
	c, _ = st.GetChat(ctx, jid)
	if c.DisplayName != "Team Frontend" {
		t.Fatalf("legit rename lost: %q", c.DisplayName)
	}
}
