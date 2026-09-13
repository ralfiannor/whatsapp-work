// Storage behavior contract:
//   - open + migrate creates schema v1 (FTS5 included)
//   - message insert is idempotent on (chat, sender, message_id)
//   - live incoming messages bump chat unread/mention counters; history never does
//   - chat preview advances with newest message
//   - keyset pagination returns pages in ts DESC order without OFFSET
//   - read marking clears counters and advances last_read_ts
//   - receipt updates only touch outgoing messages
//   - revoke/edit paths mutate the row
//   - FTS search finds quoted terms and rejects FTS5 grammar injection
package storage_test

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"path/filepath"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func openTestStore(t testing.TB) *storage.Store {
	t.Helper()
	dir := t.TempDir()
	// Quiet logger: the migration INFO line otherwise pollutes bench output
	// (go test merges the binary's stderr into stdout).
	quiet := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	st, err := storage.Open(context.Background(), dir, quiet)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = st.Close() })
	if fp := st.DSN(); filepath.Base(filepath.Dir(fp)) == "" {
		t.Fatal("DSN sanity check failed")
	}
	return st
}

func chat(jid string, kind core.ChatKind, name string) core.Chat {
	return core.Chat{JID: jid, Kind: kind, DisplayName: name, UpdatedAt: 1700000100}
}

func msg(id, chatJID, sender string, fromMe bool, ts int64, text string) core.Message {
	return core.Message{
		MessageID: id, ChatJID: chatJID, SenderJID: sender, FromMe: fromMe,
		Timestamp: ts, Kind: core.KindText, Text: text, Source: "live",
	}
}

func TestOpenMigratesAndPings(t *testing.T) {
	st := openTestStore(t)
	if err := st.Ping(context.Background()); err != nil {
		t.Fatalf("Ping: %v", err)
	}
	// Reopen on the same dir must be idempotent.
	if err := st.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	st2, err := storage.Open(context.Background(), filepath.Dir(st.DSN()), nil)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	t.Cleanup(func() { _ = st2.Close() })
}

func TestInsertMessageIdempotent(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	if err := st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	m := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, 1700000001, "hello")

	isNew, err := st.InsertMessage(ctx, &m)
	if err != nil || !isNew {
		t.Fatalf("first insert: isNew=%v err=%v", isNew, err)
	}
	rowID := m.ID

	dup := m
	isNew, err = st.InsertMessage(ctx, &dup)
	if err != nil {
		t.Fatalf("dup insert err: %v", err)
	}
	if isNew {
		t.Fatal("duplicate insert reported as new")
	}
	if dup.ID != rowID {
		t.Fatalf("duplicate got different row id %d, want %d", dup.ID, rowID)
	}

	msgs, err := st.ListMessages(ctx, "a@s.whatsapp.net", 0, 0, 50)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("ListMessages: len=%d err=%v", len(msgs), err)
	}
	c, err := st.GetChat(ctx, "a@s.whatsapp.net")
	if err != nil {
		t.Fatal(err)
	}
	if c.UnreadCount != 1 {
		t.Fatalf("unread = %d, want 1 (single insert must not double-count)", c.UnreadCount)
	}
}

func TestUnreadCountersLiveVsHistory(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}

	live := msg("l1", jid, jid, false, 1700000100, "live msg")
	if _, err := st.InsertMessage(ctx, &live); err != nil {
		t.Fatal(err)
	}
	liveMention := msg("l2", jid, jid, false, 1700000101, "ping @me")
	liveMention.HasMention = true
	if _, err := st.InsertMessage(ctx, &liveMention); err != nil {
		t.Fatal(err)
	}
	outgoing := msg("o1", jid, "me@s.whatsapp.net", true, 1700000102, "mine")
	if _, err := st.InsertMessage(ctx, &outgoing); err != nil {
		t.Fatal(err)
	}
	hist := msg("h1", jid, jid, false, 1700000103, "history msg")
	hist.Source = "history"
	if _, err := st.InsertMessage(ctx, &hist); err != nil {
		t.Fatal(err)
	}

	c, err := st.GetChat(ctx, jid)
	if err != nil {
		t.Fatal(err)
	}
	if c.UnreadCount != 2 {
		t.Fatalf("unread = %d, want 2 (live incoming only; history and outgoing excluded)", c.UnreadCount)
	}
	if c.MentionedUnread != 1 {
		t.Fatalf("mentioned unread = %d, want 1", c.MentionedUnread)
	}
}

func TestChatPreviewAdvances(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}

	m1 := msg("m1", jid, jid, false, 1700000100, "first")
	if _, err := st.InsertMessage(ctx, &m1); err != nil {
		t.Fatal(err)
	}
	m2 := msg("m2", jid, jid, false, 1700000200, "second")
	if _, err := st.InsertMessage(ctx, &m2); err != nil {
		t.Fatal(err)
	}
	older := msg("m0", jid, jid, false, 1700000050, "late old")
	if _, err := st.InsertMessage(ctx, &older); err != nil {
		t.Fatal(err)
	}

	c, _ := st.GetChat(ctx, jid)
	if c.LastMessageID != "m2" || c.LastPreview != "second" || c.LastMessageTS != 1700000200 {
		t.Fatalf("preview = %+v, want m2/second/1700000200", c)
	}
}

func TestListMessagesKeysetPagination(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	var last core.Message
	for i := 0; i < 12; i++ {
		m := msg(fmt.Sprintf("m%d", i), jid, jid, false, int64(1700000000+i), "m")
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
		last = m
	}

	page1, err := st.ListMessages(ctx, jid, 0, 0, 5)
	if err != nil || len(page1) != 5 {
		t.Fatalf("page1: len=%d err=%v", len(page1), err)
	}
	if page1[0].MessageID != last.MessageID {
		t.Fatalf("page1[0] = %s, want newest first (%s)", page1[0].MessageID, last.MessageID)
	}
	cursor := page1[len(page1)-1]

	page2, err := st.ListMessages(ctx, jid, cursor.Timestamp, cursor.ID, 5)
	if err != nil || len(page2) != 5 {
		t.Fatalf("page2: len=%d err=%v", len(page2), err)
	}
	if page2[0].Timestamp > cursor.Timestamp {
		t.Fatal("page2 leaked rows at or after the cursor")
	}
	seen := map[string]bool{}
	for _, m := range append(append([]core.Message{}, page1...), page2...) {
		seen[m.MessageID] = true
	}
	if len(seen) != 10 {
		t.Fatalf("overlapping pages: %d unique ids", len(seen))
	}
}

func TestMarkChatRead(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	m := msg("m1", jid, jid, false, 1700000100, "x")
	m.HasMention = true
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}

	ids, err := st.UnreadIncoming(ctx, jid, 100)
	if err != nil || len(ids) != 1 || ids[0].MessageID != "m1" {
		t.Fatalf("UnreadIncoming = %+v err=%v", ids, err)
	}

	if err := st.MarkChatRead(ctx, jid, 1700000100); err != nil {
		t.Fatal(err)
	}
	c, _ := st.GetChat(ctx, jid)
	if c.UnreadCount != 0 || c.MentionedUnread != 0 {
		t.Fatalf("counters after read = %d/%d, want 0/0", c.UnreadCount, c.MentionedUnread)
	}
	if ids, _ := st.UnreadIncoming(ctx, jid, 100); len(ids) != 0 {
		t.Fatalf("still unread after MarkChatRead: %+v", ids)
	}

	// An older arriving message must not resurrect unread state.
	old := msg("m0", jid, jid, false, 1700000001, "old")
	if _, err := st.InsertMessage(ctx, &old); err != nil {
		t.Fatal(err)
	}
	c, _ = st.GetChat(ctx, jid)
	if c.UnreadCount != 0 {
		t.Fatalf("unread = %d after pre-read-timestamp message, want 0", c.UnreadCount)
	}
}

func TestReceiptStatusUpdatesOutgoingOnly(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	out := msg("out1", jid, "me@s.whatsapp.net", true, 1700000100, "out")
	out.ReceiptStatus = "sent"
	if _, err := st.InsertMessage(ctx, &out); err != nil {
		t.Fatal(err)
	}
	in := msg("in1", jid, jid, false, 1700000101, "in")
	if _, err := st.InsertMessage(ctx, &in); err != nil {
		t.Fatal(err)
	}

	updates, err := st.UpdateReceiptStatus(ctx, jid, "me@s.whatsapp.net", []string{"out1", "in1"}, "read")
	if err != nil {
		t.Fatal(err)
	}
	if len(updates) != 1 || updates[0].MessageID != "out1" || updates[0].Status != "read" {
		t.Fatalf("updates = %+v, want only out1 read", updates)
	}
	got, _ := st.ListMessages(ctx, jid, 0, 0, 10)
	for _, m := range got {
		if m.MessageID == "out1" && m.ReceiptStatus != "read" {
			t.Fatalf("out1 receipt = %q, want read", m.ReceiptStatus)
		}
		if m.MessageID == "in1" && m.ReceiptStatus != "" {
			t.Fatalf("in1 receipt = %q, want empty", m.ReceiptStatus)
		}
	}
}

func TestRevokeAndEdit(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	m := msg("m1", jid, jid, false, 1700000100, "original")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}

	if err := st.SetEdited(ctx, jid, jid, "m1", "edited text", 1700000900, false, nil); err != nil {
		t.Fatal(err)
	}
	got, _ := st.ListMessages(ctx, jid, 0, 0, 10)
	if len(got) != 1 || got[0].Text != "edited text" || got[0].EditedTS != 1700000900 {
		t.Fatalf("edit not applied: %+v", got[0])
	}

	if err := st.SetRevoked(ctx, jid, "m1", jid, 1700000999); err != nil {
		t.Fatal(err)
	}
	got, _ = st.ListMessages(ctx, jid, 0, 0, 10)
	if !got[0].Revoked || got[0].Text != "" {
		t.Fatalf("revoke must clear content: %+v", got[0])
	}
	if hits, _ := st.SearchMessages(ctx, "edited", 10); len(hits) != 0 {
		t.Fatal("revoked text still searchable")
	}
}

func TestSearchFTS(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	jid2 := "b@g.us"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	if err := st.EnsureChat(ctx, chat(jid2, core.KindGroup, "Team")); err != nil {
		t.Fatal(err)
	}
	texts := []struct {
		id, chat, txt string
	}{
		{"m1", jid, "the deployment on staging failed"},
		{"m2", jid, "lunch?"},
		{"m3", jid2, "deployment window is at 6"},
		{"m4", jid, "no text here is media caption"},
	}
	for i, x := range texts {
		m := msg(x.id, x.chat, x.chat, false, int64(1700000000+i), x.txt)
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
	}

	hits, err := st.SearchMessages(ctx, "deployment staging", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(hits) != 1 || hits[0].MessageID != "m1" {
		t.Fatalf("AND search hits = %+v, want m1 only", hits)
	}
	if hits[0].Snippet == "" {
		t.Fatal("expected a snippet")
	}

	hits, err = st.SearchMessages(ctx, "deployment", 10)
	if err != nil || len(hits) != 2 {
		t.Fatalf("single-term hits = %d err=%v, want 2", len(hits), err)
	}

	// FTS5 grammar must not leak from user input.
	if _, err := st.SearchMessages(ctx, `deployment" OR 1=1 --`, 10); err != nil {
		t.Fatalf("malformed query must be sanitized, got err: %v", err)
	}
	if _, err := st.SearchMessages(ctx, "", 10); err != nil {
		t.Fatalf("empty query: %v", err)
	}
}

func TestMessageEditUpdatesFTS(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	m := msg("m1", jid, jid, false, 1700000100, "kubernetes is down")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.SetEdited(ctx, jid, jid, "m1", "kubernetes is up", 1700000900, false, nil); err != nil {
		t.Fatal(err)
	}
	if hits, _ := st.SearchMessages(ctx, "down", 10); len(hits) != 0 {
		t.Fatalf("old text still searchable after edit: %+v", hits)
	}
	if hits, _ := st.SearchMessages(ctx, "up", 10); len(hits) != 1 {
		t.Fatalf("new text not searchable after edit: %+v", hits)
	}
}

func TestContactsUpsertAndSearch(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	_, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "a@s.whatsapp.net", FullName: "Alice Smith", PushName: "alice"},
		{JID: "b@s.whatsapp.net", FullName: "Bob"},
	})
	if err != nil {
		t.Fatal(err)
	}
	_, err = st.UpsertContacts(ctx, []core.Contact{
		{JID: "a@s.whatsapp.net", PushName: "alice-work"},
	})
	if err != nil {
		t.Fatal(err)
	}

	cs, err := st.ListContacts(ctx, "alice", 10)
	if err != nil || len(cs) != 1 {
		t.Fatalf("search: %+v err=%v", cs, err)
	}
	if cs[0].PushName != "alice-work" || cs[0].FullName != "Alice Smith" {
		t.Fatalf("upsert lost fields: %+v", cs[0])
	}
}

func TestWipeClearsEverything(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	jid := "a@s.whatsapp.net"
	if err := st.EnsureChat(ctx, chat(jid, core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	m := msg("m1", jid, jid, false, 1700000100, "secret")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.Wipe(ctx); err != nil {
		t.Fatal(err)
	}
	if c, err := st.GetChat(ctx, jid); err == nil && c != nil {
		t.Fatal("chat survived wipe")
	}
	if hits, _ := st.SearchMessages(ctx, "secret", 10); len(hits) != 0 {
		t.Fatal("FTS survived wipe")
	}
}

// UpsertContacts reports how many rows really changed: identical re-upserts
// count zero (the app turns nonzero counts into contacts.updated pushes).
func TestUpsertContactsChangedCount(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	first := []core.Contact{{JID: "a@s.whatsapp.net", FullName: "Ann", UpdatedAt: 1}}
	if n, err := st.UpsertContacts(ctx, first); err != nil || n != 1 {
		t.Fatalf("insert: n=%d err=%v, want 1", n, err)
	}
	if n, err := st.UpsertContacts(ctx, first); err != nil || n != 0 {
		t.Fatalf("identical re-upsert: n=%d err=%v, want 0", n, err)
	}
	if n, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "a@s.whatsapp.net", FullName: "Ann Lee", UpdatedAt: 2},
	}); err != nil || n != 1 {
		t.Fatalf("rename: n=%d err=%v, want 1", n, err)
	}
	// Empty fields must not count as a change (they never overwrite).
	if n, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "a@s.whatsapp.net", PushName: "", UpdatedAt: 3},
	}); err != nil || n != 0 {
		t.Fatalf("empty-field upsert: n=%d err=%v, want 0", n, err)
	}
}

// Full-directory fetch must ignore the limit: the client's jid→name map is
// built from it, and truncation rendered later contacts as raw numbers.
func TestListContactsFullFetchIgnoresLimit(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	var batch []core.Contact
	for i := 0; i < 60; i++ {
		batch = append(batch, core.Contact{
			JID:      fmt.Sprintf("u%03d@s.whatsapp.net", i),
			FullName: fmt.Sprintf("User %03d", i),
		})
	}
	if _, err := st.UpsertContacts(ctx, batch); err != nil {
		t.Fatal(err)
	}
	all, err := st.ListContacts(ctx, "", 50) // limit below row count
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 60 {
		t.Fatalf("full fetch truncated: got %d, want 60", len(all))
	}
	// Search still honors the limit.
	hits, _ := st.ListContacts(ctx, "User", 10)
	if len(hits) != 10 {
		t.Fatalf("search limit not honored: got %d, want 10", len(hits))
	}
}

// Twin mirroring: a name stored under one identity form must become
// resolvable from the other; existing twin data is never overwritten.
func TestMirrorLIDContactNames(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	if _, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "111@lid", PushName: "Hansip"},
		{JID: "222@s.whatsapp.net", FullName: "Ann Lee"},
	}); err != nil {
		t.Fatal(err)
	}
	lidToPN := map[string]string{
		"111@lid":              "6285000000001@s.whatsapp.net",
		"333@lid":              "222@s.whatsapp.net",
		"555@lid":              "6285000000005@s.whatsapp.net", // no rows at all
	}
	n, err := st.MirrorLIDContactNames(ctx, lidToPN)
	if err != nil {
		t.Fatal(err)
	}
	if n == 0 {
		t.Fatal("mirrored nothing")
	}
	// LID-keyed push name now resolvable from the PN twin.
	pn, err := st.GetContact(ctx, "6285000000001@s.whatsapp.net")
	if err != nil || pn.PushName != "Hansip" {
		t.Fatalf("pn twin = %+v err=%v, want push_name Hansip", pn, err)
	}
	// PN-keyed full name now on the LID twin.
	lid, err := st.GetContact(ctx, "333@lid")
	if err != nil || lid.FullName != "Ann Lee" {
		t.Fatalf("lid twin = %+v err=%v, want full_name Ann Lee", lid, err)
	}
	// Idempotent + no phantom rows for pairs without data.
	if n2, _ := st.MirrorLIDContactNames(ctx, lidToPN); n2 != 0 {
		t.Fatalf("second pass mirrored %d, want 0", n2)
	}
	if _, err := st.GetContact(ctx, "555@lid"); err == nil {
		t.Fatal("phantom row created for empty pair")
	}
	// Existing twin data wins: set a push name on the PN twin, re-mirror
	// with a DIFFERENT name on the lid side — twin keeps its own.
	if _, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "6285000000001@s.whatsapp.net", PushName: "Twin Own"},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.UpsertContacts(ctx, []core.Contact{
		{JID: "111@lid", PushName: "Lid New"},
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := st.MirrorLIDContactNames(ctx, lidToPN); err != nil {
		t.Fatal(err)
	}
	got, _ := st.GetContact(ctx, "6285000000001@s.whatsapp.net")
	if got.PushName != "Twin Own" {
		t.Fatalf("twin overwritten: %+v", got)
	}
}

// The quote snippet for an outgoing reply: text when present, honest kind
// labels for media, empty when the original isn't stored.
func TestQuotedTextOf(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	_ = st.EnsureChat(ctx, chat("q@s.whatsapp.net", core.KindDirect, "Q"))
	seed := func(id, text string, kind core.MessageKind) {
		m := msg(id, "q@s.whatsapp.net", "q@s.whatsapp.net", false, 1700000100, text)
		m.Kind = kind
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
	}
	seed("t1", "original words", core.KindText)
	seed("t2", "", core.KindImage)
	got, err := st.QuotedTextOf(ctx, "q@s.whatsapp.net", "t1")
	if err != nil || got != "original words" {
		t.Fatalf("text quote = %q err=%v", got, err)
	}
	got, _ = st.QuotedTextOf(ctx, "q@s.whatsapp.net", "t2")
	if got != "Photo" {
		t.Fatalf("image quote = %q, want Photo", got)
	}
	got, err = st.QuotedTextOf(ctx, "q@s.whatsapp.net", "missing")
	if err != nil || got != "" {
		t.Fatalf("missing original = %q err=%v, want empty/nil", got, err)
	}
}
