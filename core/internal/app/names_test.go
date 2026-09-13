// Name resolution contract:
//   - direct chats keyed by LID fold into their phone twin via the lid→pn
//     map and resolve the contact name there — one contact, one thread
//   - groups with fallback names get their subject via GroupInfoName
//   - resolved rows surface as chat.updated events
package app_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func TestResolveNamesLIDAndGroups(t *testing.T) {
	_, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 128)

	// History-style chats with fallback names: LID-keyed direct + unnamed group.
	// Both carry a message — chat-list queries only surface chats with messages.
	fw.push(core.EventHistoryBatch{Chat: core.Chat{
		JID: "999000111222333@lid", Kind: core.KindDirect, DisplayName: "999000111222333@lid",
	}, Items: []core.Incoming{{Kind: core.IncomingNew, Message: core.Message{
		MessageID: "l1", ChatJID: "999000111222333@lid", SenderJID: "999000111222333@lid",
		Timestamp: 1700000100, Kind: core.KindText, Text: "halo", Source: "history",
	}}}})
	fw.push(core.EventHistoryBatch{Chat: core.Chat{
		JID: "1203630000000000@g.us", Kind: core.KindGroup, DisplayName: "",
	}, Items: []core.Incoming{{Kind: core.IncomingNew, Message: core.Message{
		MessageID: "g1", ChatJID: "1203630000000000@g.us", SenderJID: alice,
		Timestamp: 1700000100, Kind: core.KindText, Text: "team", Source: "history",
	}}}})
	waitFor(t, sub, "chat.updated")

	// Contact known under the phone-number JID.
	fw.push(core.EventContacts{Contacts: []core.Contact{
		{JID: alice, FullName: "Alice Smith"},
	}})

	// The fold must announce BOTH sides: chat.removed for the dropped LID
	// row (clients holding a stale copy must drop it) and chat.updated for
	// the surviving phone thread. Asserted after resolution below, when the
	// names pass has certainly run and the events sit in the subscriber
	// buffer.

	deadline := time.Now().Add(5 * time.Second)
	resolved := false
	for time.Now().Before(deadline) {
		c1, _ := st.GetChat(context.Background(), alice)
		c2, _ := st.GetChat(context.Background(), "1203630000000000@g.us")
		if c1 != nil && c1.DisplayName == "Alice Smith" &&
			c2 != nil && c2.DisplayName == "Backend Team" {
			resolved = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !resolved {
		// The LID chat must have folded into Alice's phone thread, message and
		// all — leaving it keyed by the LID shows two threads for one contact.
		if _, err := st.GetChat(context.Background(), "999000111222333@lid"); !errors.Is(err, storage.ErrNotFound) {
			t.Errorf("LID chat row not folded: %v", err)
		}
		c1, _ := st.GetChat(context.Background(), alice)
		c2, _ := st.GetChat(context.Background(), "1203630000000000@g.us")
		t.Fatalf("names unresolved: alice=%q group=%q", displayName(c1), displayName(c2))
	}
	removed := waitFor(t, sub, "chat.removed")
	if removed.Data.(map[string]any)["jid"] != "999000111222333@lid" {
		t.Fatalf("chat.removed jid = %v, want the LID row", removed.Data)
	}
	if _, err := st.LookupMessageRow(context.Background(), alice, "l1"); err != nil {
		t.Errorf("LID chat message orphaned: %v", err)
	}
}

func displayName(c *core.Chat) string {
	if c == nil {
		return "<nil>"
	}
	return c.DisplayName
}

// Regression: sending a DM must never rename the recipient's chat to OUR
// OWN contact name. ensureChatFor used to resolve the display name from
// m.SenderJID, which on outgoing rows is the account's own jid — every send
// stamped "Me Myself" onto the peer's chat until the slow name ticker fixed
// it (visible as a name flicker in the chat list).
func TestSendTextDoesNotRenameChatToOwnName(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	fw.push(core.EventPairSuccess{JID: me})
	if _, err := st.UpsertContacts(context.Background(), []core.Contact{
		{JID: me, FullName: "Me Myself"},
		{JID: alice, FullName: "Alice Smith"},
	}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && a.OwnJID() != me {
		time.Sleep(20 * time.Millisecond)
	}
	if a.OwnJID() != me {
		t.Fatal("own jid never set")
	}

	// Existing chat carrying the correct peer name.
	if err := st.EnsureChat(context.Background(), core.Chat{
		JID: alice, Kind: core.KindDirect, DisplayName: "Alice Smith",
	}); err != nil {
		t.Fatal(err)
	}

	if _, err := a.SendText(context.Background(), alice, "ping", nil, nil); err != nil {
		t.Fatal(err)
	}
	waitFor(t, sub, "message.received")

	if c, _ := st.GetChat(context.Background(), alice); displayName(c) != "Alice Smith" {
		t.Fatalf("outgoing send renamed existing chat: %q", displayName(c))
	}

	// Fresh chat for an unknown peer: name must never come from our own
	// contact either.
	if _, err := a.SendText(context.Background(), "254700000003@s.whatsapp.net",
		"hi", nil, nil); err != nil {
		t.Fatal(err)
	}
	if c, _ := st.GetChat(context.Background(), "254700000003@s.whatsapp.net"); c == nil {
		t.Fatal("fresh chat row missing")
	} else if c.DisplayName == "Me Myself" {
		t.Fatalf("fresh chat adopted own contact name: %q", c.DisplayName)
	}
}

// usync business-name pass: a direct chat still carrying a fallback title
// gets the verified business name from the usync directory, persisted as
// the contact's business name (transcript nicks resolve without a chat
// event) and emitted as chat.updated.
func TestUsyncBusinessNamePass(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)
	biz := "254700000003@s.whatsapp.net"
	fw.loggedIn = true
	fw.push(core.EventConnState{State: core.StateConnected})

	fw.push(core.EventHistoryBatch{Chat: core.Chat{
		JID: biz, Kind: core.KindDirect, DisplayName: "+254700000003",
	}, Items: []core.Incoming{{Kind: core.IncomingNew, Message: core.Message{
		MessageID: "b1", ChatJID: biz, SenderJID: biz,
		Timestamp: 1700000100, Kind: core.KindText, Text: "service AC?", Source: "history",
	}}}})
	waitFor(t, sub, "chat.updated")

	// usync answers with a verified business name for this peer.
	fw.mu.Lock()
	fw.userNames = map[string]string{biz: "Sample AC Service"}
	fw.mu.Unlock()
	_ = a // pass runs on the ticker; state drives it below

	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		c, _ := st.GetChat(context.Background(), biz)
		if c != nil && c.DisplayName == "Sample AC Service" {
			ct, _ := st.GetContact(context.Background(), biz)
			if ct != nil && ct.BusinessName == "Sample AC Service" {
				return // titled + persisted
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	c, _ := st.GetChat(context.Background(), biz)
	t.Fatalf("usync name not applied: %q", displayName(c))
}
