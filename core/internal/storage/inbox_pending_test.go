// Pending-set contract: only inbox-eligible live messages (a mention, a
// direct chat, or a work-marked group) hold a pending local-state row, so
// the inbox query's cost tracks actual work, not every group's chatter.
package storage_test

import (
	"context"
	"database/sql"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func pendingRows(t *testing.T, st *storage.Store) int {
	t.Helper()
	db, err := sql.Open("sqlite", st.DSN())
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM local_message_state WHERE done = 0`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// Chatter in an unmarked group is never pending; Mark as Work pulls in the
// recent unread backlog; unmarking drops it again but keeps mentions.
func TestWorkFlagMovesGroupTraffic(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	const team = "team@g.us"
	_ = st.EnsureChat(ctx, chat(team, core.KindGroup, "Team"))

	seed := func(id string, ts int64, mention bool) {
		m := msg(id, team, "254700000001@s.whatsapp.net", false, ts, "body "+id)
		m.HasMention = mention
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
	}
	seed("old", now-9*24*3600, false) // unread but outside the 7-day backfill
	seed("u1", now-100, false)        // unread chatter
	seed("x1", now-50, true)          // mention: an inbox item regardless
	if n := pendingRows(t, st); n != 1 {
		t.Fatalf("pending rows = %d, want 1 (only the mention)", n)
	}

	conv := func() core.InboxConversation {
		t.Helper()
		inbox, err := st.Inbox(ctx, now, 50)
		if err != nil {
			t.Fatal(err)
		}
		all := append(append(inbox.Mentions, inbox.Direct...), inbox.WorkGroups...)
		if len(all) != 1 {
			t.Fatalf("conversations = %+v, want exactly the team", all)
		}
		return all[0]
	}
	if c := conv(); c.Count != 1 || c.LastMessageID != "x1" {
		t.Fatalf("unmarked group digest = %+v, want the mention only", c)
	}

	if err := st.SetChatWork(ctx, team, true); err != nil {
		t.Fatal(err)
	}
	if c := conv(); c.Count != 2 || !c.IsWork {
		t.Fatalf("marked group digest = %+v, want mention + recent unread", c)
	}

	if err := st.SetChatWork(ctx, team, false); err != nil {
		t.Fatal(err)
	}
	if c := conv(); c.Count != 1 || c.LastMessageID != "x1" {
		t.Fatalf("unmarked again = %+v, want the mention to survive", c)
	}

	// Read chatter is not backlog: re-marking after reading pulls nothing.
	if err := st.MarkChatRead(ctx, team, now-100); err != nil {
		t.Fatal(err)
	}
	if err := st.SetChatWork(ctx, team, true); err != nil {
		t.Fatal(err)
	}
	if c := conv(); c.Count != 1 {
		t.Fatalf("re-marked after read = %+v, want only the mention", c)
	}

	// Live traffic after marking is pending from birth.
	seed("u2", now-10, false)
	if c := conv(); c.Count != 2 || c.LastMessageID != "u2" {
		t.Fatalf("new work traffic = %+v, want u2 pending", c)
	}
}

// A non-pending row can still hold state (a starred message in an unmarked
// group). Such rows must not take LIMIT slots from real inbox items.
func TestInboxLimitSkipsIneligibleRows(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	const dm = "254700000001@s.whatsapp.net"
	_ = st.EnsureChat(ctx, chat(dm, core.KindDirect, "Boss"))
	m := msg("d1", dm, dm, false, now-1000, "ping")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	for i, g := range []string{"g1@g.us", "g2@g.us", "g3@g.us"} {
		_ = st.EnsureChat(ctx, chat(g, core.KindGroup, g))
		gm := msg("s"+g, g, dm, false, now-int64(10*i), "chatter")
		if _, err := st.InsertMessage(ctx, &gm); err != nil {
			t.Fatal(err)
		}
		if err := st.SetMessageStarred(ctx, gm.ID, true); err != nil {
			t.Fatal(err)
		}
	}
	inbox, err := st.Inbox(ctx, now, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox.Direct) != 1 || inbox.Counts.Total != 1 {
		t.Fatalf("inbox = %+v, want the DM despite newer starred group rows", inbox)
	}
}

// v16 drops the chatter rows older builds opened for every live message,
// keeping mentions, direct chats, work groups and starred rows.
func TestMigrationV16DropsIneligiblePending(t *testing.T) {
	dir := t.TempDir()
	ctx := context.Background()
	quiet := slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError}))
	st, err := storage.Open(ctx, dir, quiet)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().Unix()
	const dm, work, noise = "254700000001@s.whatsapp.net", "work@g.us", "noise@g.us"
	_ = st.EnsureChat(ctx, chat(dm, core.KindDirect, "Boss"))
	_ = st.EnsureChat(ctx, chat(work, core.KindGroup, "Work"))
	_ = st.EnsureChat(ctx, chat(noise, core.KindGroup, "Noise"))
	if err := st.SetChatWork(ctx, work, true); err != nil {
		t.Fatal(err)
	}
	var starredID int64
	for _, s := range []struct {
		id, chat string
		mention  bool
	}{
		{"d1", dm, false}, {"w1", work, false}, {"n1", noise, false},
		{"n2", noise, false}, {"n3", noise, true}, {"n4", noise, false},
	} {
		m := msg(s.id, s.chat, dm, false, now, "body")
		m.HasMention = s.mention
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
		if s.id == "n4" {
			starredID = m.ID
		}
	}
	if err := st.SetMessageStarred(ctx, starredID, true); err != nil {
		t.Fatal(err)
	}

	// Recreate the pre-v16 state: every live incoming row pending.
	db, err := sql.Open("sqlite", st.DSN())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
		INSERT INTO local_message_state (message_id, done, snoozed_until, starred, priority)
		SELECT id, 0, NULL, 0, 0 FROM messages WHERE true ON CONFLICT (message_id) DO NOTHING;
		DELETE FROM schema_migrations WHERE version = 16;`); err != nil {
		t.Fatal(err)
	}
	_ = db.Close()
	if n := pendingRows(t, st); n != 6 {
		t.Fatalf("pre-migration pending = %d, want 6", n)
	}
	_ = st.Close()

	st, err = storage.Open(ctx, dir, quiet)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	// d1, w1, n3 (mention) and n4 (starred) stay; n1, n2 go.
	if n := pendingRows(t, st); n != 4 {
		t.Fatalf("post-migration pending = %d, want 4", n)
	}
}

// A message in an unmarked group that only LATER turns out to mention me —
// a decrypt placeholder's re-delivery, or an edit — becomes an inbox item.
func TestLateMentionOpensInboxItem(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	const team, sender = "team@g.us", "254700000001@s.whatsapp.net"
	_ = st.EnsureChat(ctx, chat(team, core.KindGroup, "Team"))

	bare := msg("p1", team, sender, false, now-20, "")
	bare.Kind = core.KindUnsupported
	plain := msg("e1", team, sender, false, now-10, "no mention yet")
	for _, m := range []*core.Message{&bare, &plain} {
		if _, err := st.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	if n := pendingRows(t, st); n != 0 {
		t.Fatalf("pending rows = %d, want 0 for unmarked-group chatter", n)
	}

	full := msg("p1", team, sender, false, now-20, "@you see this")
	full.HasMention = true
	if _, err := st.InsertMessage(ctx, &full); err != nil {
		t.Fatal(err)
	}
	if err := st.SetEdited(ctx, team, sender, "e1", "now @you", now, true, []string{"me@s.whatsapp.net"}); err != nil {
		t.Fatal(err)
	}
	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox.Mentions) != 1 || inbox.Mentions[0].Count != 2 {
		t.Fatalf("mentions = %+v, want the team with both late mentions", inbox.Mentions)
	}
}
