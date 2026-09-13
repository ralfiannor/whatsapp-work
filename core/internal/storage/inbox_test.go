// v0.2 work-inbox storage contract:
//   - local message state upserts (done / snooze / star) are idempotent
//   - inbox sections exclude done and not-yet-due snoozed messages
//   - ListMessages attaches reactions to each row
//   - chat star/work toggles persist
package storage_test

import (
	"context"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func TestLocalStateUpsertAndInbox(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()

	seed := func(id, chat, sender string, ts int64, mention bool) core.Message {
		m := msg(id, chat, sender, false, ts, "task "+id)
		m.HasMention = mention
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	_ = st.EnsureChat(ctx, chat("w1@s.whatsapp.net", core.KindDirect, "Boss"))
	_ = st.EnsureChat(ctx, chat("w2@g.us", core.KindGroup, "Team"))
	m1 := seed("i1", "w1@s.whatsapp.net", "w1@s.whatsapp.net", now-100, true)
	seed("i2", "w1@s.whatsapp.net", "w1@s.whatsapp.net", now-50, false)
	m3 := seed("i3", "w2@g.us", "a@s.whatsapp.net", now-10, true)

	// Done removes m1 from the inbox; star keeps it visible in starred.
	if err := st.SetMessageDone(ctx, m1.ID, true); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMessageStarred(ctx, m1.ID, true); err != nil {
		t.Fatal(err)
	}
	// Snooze m3 for an hour: excluded now, reappears after expiry.
	if err := st.SetMessageSnoozed(ctx, m3.ID, now+3600); err != nil {
		t.Fatal(err)
	}

	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	// Only m2 remains actionable: one conversation row.
	if len(inbox.Mentions) != 0 || len(inbox.Direct) != 1 {
		t.Fatalf("inbox = %+v", inbox)
	}
	if inbox.Direct[0].LastMessageID != "i2" || inbox.Direct[0].Count != 1 {
		t.Fatalf("expected i2 digest, got %+v", inbox.Direct[0])
	}

	// After the snooze lapses, m3 is back (mention in a group).
	inbox, _ = st.Inbox(ctx, now+3601, 50)
	if len(inbox.Mentions) != 1 || inbox.Mentions[0].LastMessageID != "i3" {
		t.Fatalf("snooze did not lapse: %+v", inbox.Mentions)
	}

	// Un-done m1 returns the conversation to Mentions: one digest row for
	// w1, flagged has_mention, newest item i2, two pending items.
	if err := st.SetMessageDone(ctx, m1.ID, false); err != nil {
		t.Fatal(err)
	}
	inbox, _ = st.Inbox(ctx, now, 50)
	if len(inbox.Mentions) != 1 || inbox.Mentions[0].ChatJID != "w1@s.whatsapp.net" ||
		!inbox.Mentions[0].HasMention || inbox.Mentions[0].Count != 2 {
		t.Fatalf("un-done not restored: %+v", inbox.Mentions)
	}
}

func TestInboxCountsAndWorkGroups(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	_ = st.EnsureChat(ctx, chat("w1@s.whatsapp.net", core.KindDirect, "Boss"))
	m := msg("i1", "w1@s.whatsapp.net", "w1@s.whatsapp.net", false, now, "ping")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}

	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	if inbox.Counts.Total != 1 || inbox.Counts.Direct != 1 {
		t.Fatalf("counts = %+v", inbox.Counts)
	}
	if len(inbox.Direct) != 1 || inbox.Direct[0].Count != 1 {
		t.Fatalf("conversation digest = %+v", inbox.Direct)
	}

	// Star the chat → it lands in the starred section while unread.
	if err := st.SetChatStarred(ctx, "w1@s.whatsapp.net", true); err != nil {
		t.Fatal(err)
	}
	inbox, _ = st.Inbox(ctx, now, 50)
	if len(inbox.StarredChats) != 1 || inbox.StarredChats[0].JID != "w1@s.whatsapp.net" {
		t.Fatalf("starred = %+v", inbox.StarredChats)
	}
}

func TestReactionsAttachedToListMessages(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	if err := st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A")); err != nil {
		t.Fatal(err)
	}
	m := msg("r1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, 1700000100, "react to me")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertReaction(ctx, m.ID, "b@s.whatsapp.net", "👍", 1); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertReaction(ctx, m.ID, "c@s.whatsapp.net", "👍", 2); err != nil {
		t.Fatal(err)
	}
	if err := st.UpsertReaction(ctx, m.ID, "d@s.whatsapp.net", "❤️", 3); err != nil {
		t.Fatal(err)
	}

	got, err := st.ListMessages(ctx, "a@s.whatsapp.net", 0, 0, 10)
	if err != nil || len(got) != 1 {
		t.Fatalf("list: %+v err=%v", got, err)
	}
	if len(got[0].Reactions) != 3 {
		t.Fatalf("reactions = %+v", got[0].Reactions)
	}
}

// The audit truth table (docs/feature-audit-2026-08-30.md §4): one fixture
// conversation set, asserted against every view. The Inbox is work state
// (Done/Snooze exits); Unread/Mentions filters stay read-coupled.
func TestInboxTruthTable(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()

	const (
		dmA      = "a@s.whatsapp.net"  // A: unread direct message
		chatB    = "b@s.whatsapp.net"  // B: read explicit mention, not done
		groupC   = "c@g.us"            // C: unread group msg, no mention, NOT work
		chatD    = "d@s.whatsapp.net"  // D: starred contact, read message
		chatE    = "e@s.whatsapp.net"  // E: snoozed item
		chatF    = "f@s.whatsapp.net"  // F: done item
		chatG    = "g@s.whatsapp.net"  // G: normal read conversation
		groupH   = "h@g.us"            // H: unread group mention
		groupI   = "i@g.us"            // I: unread work-group msg, no mention
	)
	for jid, kind := range map[string]core.ChatKind{
		dmA: core.KindDirect, chatB: core.KindDirect, groupC: core.KindGroup,
		chatD: core.KindDirect, chatE: core.KindDirect, chatF: core.KindDirect,
		chatG: core.KindDirect, groupH: core.KindGroup, groupI: core.KindGroup,
	} {
		_ = st.EnsureChat(ctx, chat(jid, kind, jid))
	}
	if err := st.SetChatStarred(ctx, chatD, true); err != nil {
		t.Fatal(err)
	}
	if err := st.SetChatWork(ctx, groupI, true); err != nil {
		t.Fatal(err)
	}

	seed := func(id, chatJID string, ts int64, mention bool) core.Message {
		m := msg(id, chatJID, chatJID, false, ts, "body "+id)
		m.HasMention = mention
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	seed("a1", dmA, now-900, false)                    // A unread DM
	mB := seed("b1", chatB, now-800, true)             // B mention…
	if err := st.MarkChatRead(ctx, chatB, now-800); err != nil { // …then read
		t.Fatal(err)
	}
	seed("c1", groupC, now-700, false)                 // C unread non-work group
	seed("d1", chatD, now-600, false)                  // D starred contact, read
	if err := st.MarkChatRead(ctx, chatD, now-600); err != nil {
		t.Fatal(err)
	}
	mE := seed("e1", chatE, now-500, false)            // E snoozed until later
	if err := st.SetMessageSnoozed(ctx, mE.ID, now+3600); err != nil {
		t.Fatal(err)
	}
	mF := seed("f1", chatF, now-400, false)            // F done
	if err := st.SetMessageDone(ctx, mF.ID, true); err != nil {
		t.Fatal(err)
	}
	seed("g1", chatG, now-300, false)                  // G read conversation
	if err := st.MarkChatRead(ctx, chatG, now-300); err != nil {
		t.Fatal(err)
	}
	seed("h1", groupH, now-200, true)                  // H unread mention
	seed("i1", groupI, now-100, false)                 // I unread work-group msg

	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	convByChat := map[string]core.InboxConversation{}
	for _, c := range append(append(inbox.Mentions, inbox.Direct...), inbox.WorkGroups...) {
		convByChat[c.ChatJID] = c
	}
	for chatJID, want := range map[string]bool{
		dmA: true, chatB: true, groupC: false, chatD: true, chatE: false,
		chatF: false, chatG: true, groupH: true, groupI: true,
	} {
		if _, got := convByChat[chatJID]; got != want {
			t.Errorf("inbox conversation[%s] present = %v, want %v", chatJID, got, want)
		}
	}
	// Grouping: b (read mention) and h (unread mention) sit in Mentions;
	// a (DM) in Direct; i (work group) in Work Groups with its count.
	if c, ok := convByChat[groupI]; !ok || c.Count != 1 || !c.IsWork {
		t.Errorf("work group digest wrong: %+v", c)
	} else {
		found := false
		for _, w := range inbox.WorkGroups {
			if w.ChatJID == groupI {
				found = true
			}
		}
		if !found {
			t.Errorf("i must sit in WorkGroups: %+v", inbox.WorkGroups)
		}
	}
	if len(inbox.StarredChats) != 0 {
		t.Errorf("starred CHAT section should be empty (D has no unread): %+v", inbox.StarredChats)
	}

	// Read-coupled filters for the same fixture.
	filterChats := func(f storage.ChatFilter) map[string]bool {
		chats, err := st.ListChats(ctx, 50, 0, "", f)
		if err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, c := range chats {
			out[c.JID] = true
		}
		return out
	}
	unread := filterChats(storage.FilterUnread)
	for jid, want := range map[string]bool{
		dmA: true, chatB: false, groupC: true, chatD: false, chatE: true,
		chatF: true, chatG: false, groupH: true, groupI: true,
	} {
		if unread[jid] != want {
			t.Errorf("Unread[%s] = %v, want %v", jid, unread[jid], want)
		}
	}
	mentions := filterChats(storage.FilterMentions)
	for jid, want := range map[string]bool{
		chatB: false, // read mention: filter is read-coupled by design
		groupH: true,
	} {
		if mentions[jid] != want {
			t.Errorf("Mentions[%s] = %v, want %v", jid, mentions[jid], want)
		}
	}
	_ = mB
}

// Conversation-level bulk actions: one Done clears the whole chat's pending
// items; a new message reopens the conversation with a fresh count; the chat
// snooze deadline holds messages that arrive after it was set.
func TestConversationBulkActions(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	_ = st.EnsureChat(ctx, chat("team@g.us", core.KindGroup, "Team"))
	if err := st.SetChatWork(ctx, "team@g.us", true); err != nil {
		t.Fatal(err)
	}
	for i, id := range []string{"t1", "t2", "t3"} {
		m := msg(id, "team@g.us", "a@s.whatsapp.net", false, now-100+int64(i), "chatter "+id)
		if _, err := st.InsertMessage(ctx, &m); err != nil {
			t.Fatal(err)
		}
	}

	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox.WorkGroups) != 1 || inbox.WorkGroups[0].Count != 3 {
		t.Fatalf("digest = %+v, want one conversation of 3", inbox.WorkGroups)
	}

	// Bulk Done: whole conversation cleared in one action.
	if err := st.SetChatDone(ctx, "team@g.us", true); err != nil {
		t.Fatal(err)
	}
	inbox, _ = st.Inbox(ctx, now, 50)
	if inbox.Counts.Total != 0 {
		t.Fatalf("bulk done left items: %+v", inbox.Counts)
	}
	if len(inbox.DoneRecent) != 3 {
		t.Fatalf("bulk done should land in done_recent: %+v", inbox.DoneRecent)
	}

	// New message reopens the conversation with count 1.
	m := msg("t4", "team@g.us", "a@s.whatsapp.net", false, now+10, "new chatter")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	inbox, _ = st.Inbox(ctx, now, 50)
	if len(inbox.WorkGroups) != 1 || inbox.WorkGroups[0].Count != 1 || inbox.WorkGroups[0].LastMessageID != "t4" {
		t.Fatalf("reopened digest = %+v", inbox.WorkGroups)
	}

	// Chat snooze holds even messages arriving AFTER the deadline was set.
	if err := st.SetChatSnooze(ctx, "team@g.us", now+3600); err != nil {
		t.Fatal(err)
	}
	m5 := msg("t5", "team@g.us", "a@s.whatsapp.net", false, now+20, "during snooze")
	if _, err := st.InsertMessage(ctx, &m5); err != nil {
		t.Fatal(err)
	}
	inbox, _ = st.Inbox(ctx, now, 50)
	if inbox.Counts.Total != 0 {
		t.Fatalf("chat snooze must hold post-snooze messages: %+v", inbox.Counts)
	}
	// Due: everything (t4, t5) surfaces again as one conversation.
	inbox, _ = st.Inbox(ctx, now+3601, 50)
	if len(inbox.WorkGroups) != 1 || inbox.WorkGroups[0].Count != 2 {
		t.Fatalf("post-due digest = %+v", inbox.WorkGroups)
	}

	// Reopen (bulk un-done) returns items to the inbox.
	if err := st.SetChatDone(ctx, "team@g.us", true); err != nil {
		t.Fatal(err)
	}
	if err := st.SetChatDone(ctx, "team@g.us", false); err != nil {
		t.Fatal(err)
	}
	// Reopen returns every done row of the chat: t1..t5 = 5 pending.
	inbox, _ = st.Inbox(ctx, now+3601, 50)
	if len(inbox.WorkGroups) != 1 || inbox.WorkGroups[0].Count != 5 {
		t.Fatalf("bulk reopen digest = %+v", inbox.WorkGroups)
	}
}

// Reading a chat (here or on the phone) must NOT clear its inbox items —
// only Done/Snooze exit. This is the P0-1 regression test.
func TestInboxIgnoresReadState(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	_ = st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A"))
	m := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, now, "review please")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.MarkChatRead(ctx, "a@s.whatsapp.net", now); err != nil {
		t.Fatal(err)
	}
	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox.Direct) != 1 || inbox.Direct[0].LastMessageID != "m1" {
		t.Fatalf("read state must not remove inbox items: %+v", inbox.Direct)
	}
}

// History backfill must never flood the work inbox: only live messages enter.
func TestInboxLiveOnly(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	_ = st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A"))
	live := msg("l1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, now, "live ping")
	hist := msg("h1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, now-10, "history ping")
	hist.Source = "history"
	for i := range []*core.Message{&live, &hist} {
		if _, err := st.InsertMessage(ctx, []*core.Message{&live, &hist}[i]); err != nil {
			t.Fatal(err)
		}
	}
	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox.Direct) != 1 || inbox.Direct[0].LastMessageID != "l1" {
		t.Fatalf("inbox must contain only live items: %+v", inbox.Direct)
	}
}

// A row first stored as a bare/unsupported envelope and re-delivered with
// full content must gain the mention flag, the JID list and the reply refs —
// the old escalation path silently dropped them (audit P0-2).
func TestRedeliveryEscalatesMentionAndReply(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	_ = st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A"))

	bare := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, 1700000100, "")
	bare.Kind = core.KindUnsupported
	if _, err := st.InsertMessage(ctx, &bare); err != nil {
		t.Fatal(err)
	}

	full := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, 1700000100, "@you take a look")
	full.Kind = core.KindText
	full.HasMention = true
	full.MentionedJIDs = []string{"me@s.whatsapp.net"}
	full.ReplyToID = "m0"
	full.ReplyToSender = "a@s.whatsapp.net"
	full.QuotedText = "earlier"
	if _, err := st.InsertMessage(ctx, &full); err != nil {
		t.Fatal(err)
	}

	got, _ := st.ListMessages(ctx, "a@s.whatsapp.net", 0, 0, 10)
	if len(got) != 1 {
		t.Fatalf("rows = %d, want 1 (idempotent)", len(got))
	}
	m := got[0]
	if !m.HasMention || len(m.MentionedJIDs) != 1 {
		t.Fatalf("mention metadata lost on re-delivery: %+v", m)
	}
	if m.ReplyToID != "m0" || m.QuotedText != "earlier" {
		t.Fatalf("reply metadata lost on re-delivery: %+v", m)
	}

	// A later re-delivery without mention context must never clear the flag.
	again := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, 1700000100, "@you take a look")
	if _, err := st.InsertMessage(ctx, &again); err != nil {
		t.Fatal(err)
	}
	got, _ = st.ListMessages(ctx, "a@s.whatsapp.net", 0, 0, 10)
	if !got[0].HasMention {
		t.Fatal("re-delivery downgraded has_mention")
	}
}

// An edit that adds a mention must update the flag (audit P1-3).
func TestSetEditedUpdatesMention(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	_ = st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A"))
	m := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, 1700000100, "no mention yet")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.SetEdited(ctx, "a@s.whatsapp.net", "a@s.whatsapp.net", "m1",
		"now @you", 1700000900, true, []string{"me@s.whatsapp.net"}); err != nil {
		t.Fatal(err)
	}
	got, _ := st.ListMessages(ctx, "a@s.whatsapp.net", 0, 0, 10)
	if !got[0].HasMention || got[0].Text != "now @you" {
		t.Fatalf("edit did not update mention flag: %+v", got[0])
	}
	// And an edit that drops the mention clears it — the payload is truth.
	if err := st.SetEdited(ctx, "a@s.whatsapp.net", "a@s.whatsapp.net", "m1",
		"mention removed", 1700000999, false, nil); err != nil {
		t.Fatal(err)
	}
	got, _ = st.ListMessages(ctx, "a@s.whatsapp.net", 0, 0, 10)
	if got[0].HasMention {
		t.Fatalf("edit should have cleared mention flag: %+v", got[0])
	}
}

// Message reads carry the local work state so the transcript can render it.
func TestListMessagesCarriesWorkState(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	_ = st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A"))
	m := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, 1700000100, "task")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMessageStarred(ctx, m.ID, true); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMessageDone(ctx, m.ID, true); err != nil {
		t.Fatal(err)
	}
	got, _ := st.ListMessages(ctx, "a@s.whatsapp.net", 0, 0, 10)
	if !got[0].Starred || !got[0].Done {
		t.Fatalf("work state not surfaced on read: %+v", got[0])
	}
	one, err := st.GetMessage(ctx, m.ID)
	if err != nil || !one.Starred || !one.Done {
		t.Fatalf("GetMessage work state wrong: %+v err=%v", one, err)
	}
}

// Done items surface in done_recent (newest completion first) and vanish on
// reopen — Done must be visible and reversible, not a black hole.
func TestInboxDoneRecent(t *testing.T) {
	st := openTestStore(t)
	ctx := context.Background()
	now := time.Now().Unix()
	_ = st.EnsureChat(ctx, chat("a@s.whatsapp.net", core.KindDirect, "A"))
	m := msg("m1", "a@s.whatsapp.net", "a@s.whatsapp.net", false, now, "handled")
	if _, err := st.InsertMessage(ctx, &m); err != nil {
		t.Fatal(err)
	}
	if err := st.SetMessageDone(ctx, m.ID, true); err != nil {
		t.Fatal(err)
	}

	inbox, err := st.Inbox(ctx, now, 50)
	if err != nil {
		t.Fatal(err)
	}
	if len(inbox.DoneRecent) != 1 || inbox.DoneRecent[0].MessageID != "m1" {
		t.Fatalf("done_recent = %+v, want m1", inbox.DoneRecent)
	}
	if len(inbox.Direct) != 0 {
		t.Fatalf("done item must leave the actionable sections: %+v", inbox.Direct)
	}

	// Reopen: back to actionable, gone from done_recent.
	if err := st.SetMessageDone(ctx, m.ID, false); err != nil {
		t.Fatal(err)
	}
	inbox, _ = st.Inbox(ctx, now, 50)
	if len(inbox.DoneRecent) != 0 {
		t.Fatalf("reopened item still in done_recent: %+v", inbox.DoneRecent)
	}
	if len(inbox.Direct) != 1 {
		t.Fatalf("reopened item not back in Direct: %+v", inbox.Direct)
	}

	// Items done before the 7-day window drop out of the section: ask the
	// inbox "now" = a week and a day after the completion timestamp.
	if err := st.SetMessageDone(ctx, m.ID, true); err != nil {
		t.Fatal(err)
	}
	inbox, _ = st.Inbox(ctx, now+8*24*3600, 50)
	if len(inbox.DoneRecent) != 0 {
		t.Fatalf("stale done item still listed: %+v", inbox.DoneRecent)
	}
}
