// M1 adapter contract:
//   - ConvertHistory turns a whatsmeow HistorySync payload into ordered core
//     events: one EventHistoryBatch per conversation (chat metadata + read
//     position + normalized messages) and one EventContacts for pushnames
//   - GroupInfoToChat maps a group rename into a chat upsert
package whatsapp_test

import (
	"testing"
	"time"

	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	waHistory "go.mau.fi/whatsmeow/proto/waHistorySync"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/whatsapp"
)

func u64p(v uint64) *uint64 { return &v }

// fakeParse mimics whatsmeow.Client.ParseWebMessage for constructed protos.
func fakeParse(chat types.JID, web *waWeb.WebMessageInfo) (*events.Message, error) {
	fromMe := web.GetKey().GetFromMe()
	sender := chat
	if p := web.GetKey().GetParticipant(); p != "" {
		sender = mustJID(p)
	} else if fromMe {
		sender = mustJID(me)
	}
	return &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{Chat: chat, Sender: sender, IsFromMe: fromMe, IsGroup: chat.Server == types.GroupServer},
			ID:            web.GetKey().GetID(),
			Timestamp:     time.Unix(int64(web.GetMessageTimestamp()), 0),
			PushName:      web.GetPushName(),
		},
		Message:      web.GetMessage(),
		RawMessage:   web.GetMessage(),
		SourceWebMsg: web,
	}, nil
}

func webMsg(id string, fromMe bool, ts uint64, msg *waE2E.Message) *waWeb.WebMessageInfo {
	participant := ""
	if msg.GetProtocolMessage() != nil {
		participant = alice // protocol targets carry a participant
	}
	return &waWeb.WebMessageInfo{
		Key:              &waCommon.MessageKey{RemoteJID: strp(group), FromMe: &fromMe, ID: strp(id), Participant: &participant},
		Message:          msg,
		MessageTimestamp: &ts,
	}
}

func strp(s string) *string { return &s }

func TestConvertHistory(t *testing.T) {
	data := &waHistory.HistorySync{
		Progress: u32(50),
		Conversations: []*waHistory.Conversation{
			{
				ID:               strp(group),
				Name:             strp("Backend Team"),
				LastMsgTimestamp: u64p(1700000500),
				Messages: []*waHistory.HistorySyncMsg{
					{Message: webMsg("h1", false, 1700000100, &waE2E.Message{Conversation: strp("standup in 5")})},
					{Message: webMsg("h2", false, 1700000200, &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
						Text:        strp("deploy @me now"),
						ContextInfo: &waE2E.ContextInfo{MentionedJID: []string{me}},
					}})},
				},
			},
		},
		Pushnames: []*waHistory.Pushname{
			{ID: strp(alice), Pushname: strp("alice-wa")},
			{ID: strp(me), Pushname: strp("")}, // empty pushname skipped
		},
	}

	evs := whatsapp.ConvertHistory([]string{me}, data, fakeParse, nil)
	if len(evs) != 2 {
		t.Fatalf("events = %d, want 2 (batch + contacts): %+v", len(evs), evs)
	}

	batch, ok := evs[0].(core.EventHistoryBatch)
	if !ok {
		t.Fatalf("first event = %T, want EventHistoryBatch", evs[0])
	}
	if batch.Chat.JID != group || batch.Chat.Kind != core.KindGroup {
		t.Fatalf("batch chat = %+v", batch.Chat)
	}
	if batch.Chat.DisplayName != "Backend Team" {
		t.Fatalf("group name = %q", batch.Chat.DisplayName)
	}
	if batch.Chat.LastReadTS != 1700000500 {
		t.Fatalf("history read position = %d, want last msg ts", batch.Chat.LastReadTS)
	}
	if len(batch.Items) != 2 {
		t.Fatalf("items = %d, want 2", len(batch.Items))
	}
	if batch.Items[0].Message.Text != "standup in 5" {
		t.Fatalf("item0 text = %q", batch.Items[0].Message.Text)
	}
	if !batch.Items[1].Message.HasMention {
		t.Fatal("mention lost in history conversion")
	}
	for _, it := range batch.Items {
		if it.Message.Source != "history" {
			t.Fatalf("item source = %q", it.Message.Source)
		}
	}

	contacts, ok := evs[1].(core.EventContacts)
	if !ok || len(contacts.Contacts) != 1 || contacts.Contacts[0].PushName != "alice-wa" {
		t.Fatalf("contacts event = %+v", evs[1])
	}
}

// Per-message pushnames title group senders the top-level pushnames list
// never covers (big communities). Same sender twice → one contact; the
// top-level list wins on conflict; own messages never title anyone.
func TestConvertHistoryMessagePushnames(t *testing.T) {
	bob := "254700000003@s.whatsapp.net"
	msg := func(id, sender, push string) *waHistory.HistorySyncMsg {
		web := webMsg(id, false, 1700000100, &waE2E.Message{Conversation: strp("hi")})
		web.Key.Participant = strp(sender)
		if push != "" {
			web.PushName = strp(push)
		}
		return &waHistory.HistorySyncMsg{Message: web}
	}
	data := &waHistory.HistorySync{
		Conversations: []*waHistory.Conversation{
			{
				ID: strp(group),
				Messages: []*waHistory.HistorySyncMsg{
					msg("h1", alice, "alice-history"),
					msg("h2", alice, "alice-history"), // dedup: same sender+name
					msg("h3", bob, "bob-history"),
					msg("h4", me, "me-should-not-count"),
					msg("h5", alice, ""), // no pushname on the envelope
				},
			},
		},
		Pushnames: []*waHistory.Pushname{
			{ID: strp(alice), Pushname: strp("alice-top")}, // overrides per-message
		},
	}

	evs := whatsapp.ConvertHistory([]string{me}, data, fakeParse, nil)
	if len(evs) != 2 {
		t.Fatalf("events = %d, want 2 (batch + contacts): %+v", len(evs), evs)
	}
	contacts, ok := evs[1].(core.EventContacts)
	if !ok {
		t.Fatalf("second event = %T, want EventContacts", evs[1])
	}
	got := map[string]string{}
	for _, c := range contacts.Contacts {
		got[c.JID] = c.PushName
	}
	want := map[string]string{alice: "alice-top", bob: "bob-history"}
	if len(got) != len(want) {
		t.Fatalf("contacts = %+v, want %+v", got, want)
	}
	for jid, name := range want {
		if got[jid] != name {
			t.Fatalf("contact %s = %q, want %q", jid, got[jid], name)
		}
	}
}

func TestConvertHistorySkipsUnparsable(t *testing.T) {	data := &waHistory.HistorySync{
		Conversations: []*waHistory.Conversation{
			{
				ID: strp("not a jid!"),
				Messages: []*waHistory.HistorySyncMsg{
					{Message: webMsg("h1", false, 1, &waE2E.Message{Conversation: strp("x")})},
				},
			},
		},
	}
	if evs := whatsapp.ConvertHistory(nil, data, fakeParse, nil); len(evs) != 0 {
		t.Fatalf("bad conversation produced events: %+v", evs)
	}
}

func TestGroupInfoToChat(t *testing.T) {
	evt := &events.GroupInfo{
		JID:  mustJID(group),
		Name: &types.GroupName{Name: "Renamed Team"},
	}
	c := whatsapp.GroupInfoToChat(evt)
	if c.JID != group || c.Kind != core.KindGroup || c.DisplayName != "Renamed Team" {
		t.Fatalf("chat = %+v", c)
	}
	if whatsapp.GroupInfoToChat(&events.GroupInfo{JID: mustJID(group)}) != nil {
		t.Fatal("group info without a name must not produce a chat update")
	}
}
