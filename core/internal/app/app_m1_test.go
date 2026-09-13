// M1 app contract:
//   - history batches persist durably without per-message event storms
//     (no message.received; exactly one chat.updated)
//   - read_self receipts (incoming messages read on the phone) advance the
//     chat's read position locally without sending anything back
package app_test

import (
	"context"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

func TestHistoryBatchIngest(t *testing.T) {
	_, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 64)

	fw.push(core.EventHistoryBatch{
		Chat: core.Chat{JID: alice, Kind: core.KindDirect, DisplayName: "Alice", LastReadTS: 1700000300},
		Items: []core.Incoming{
			{Kind: core.IncomingNew, Message: core.Message{
				MessageID: "h1", ChatJID: alice, SenderJID: alice, Timestamp: 1700000100,
				Kind: core.KindText, Text: "one", Source: "history",
			}},
			{Kind: core.IncomingNew, Message: core.Message{
				MessageID: "h2", ChatJID: alice, SenderJID: alice, Timestamp: 1700000300,
				Kind: core.KindText, Text: "two", Source: "history",
			}},
		},
	})
	waitFor(t, sub, "chat.updated")

	msgs, _ := st.ListMessages(context.Background(), alice, 0, 0, 10)
	if len(msgs) != 2 {
		t.Fatalf("history rows = %d, want 2", len(msgs))
	}
	c, _ := st.GetChat(context.Background(), alice)
	if c.DisplayName != "Alice" || c.UnreadCount != 0 || c.LastReadTS != 1700000300 {
		t.Fatalf("chat after batch = %+v", c)
	}
	if c.LastMessageID != "h2" {
		t.Fatalf("preview not advanced: %s", c.LastMessageID)
	}

	// History must not emit message.received at all.
	deadline := time.After(300 * time.Millisecond)
	for {
		select {
		case ev := <-sub:
			if ev.Type == "message.received" {
				t.Fatal("history batch emitted message.received")
			}
		case <-deadline:
			return
		}
	}
}

func TestReadSelfAdvancesReadPosition(t *testing.T) {
	_, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	fw.push(incomingMsgAt("m1", alice, "ping", 1700000100))
	fw.push(incomingMsgAt("m2", alice, "pong", 1700000200))
	waitFor(t, sub, "message.received")
	waitFor(t, sub, "message.received")

	c, _ := st.GetChat(context.Background(), alice)
	if c.UnreadCount != 2 {
		t.Fatalf("unread before read_self = %d, want 2", c.UnreadCount)
	}

	// The phone read both incoming messages — local read position must catch up.
	// (Poll storage directly: chat.updated events from the message ingests are
	// still in flight, so waiting on events here would race.)
	fw.push(core.EventReceipt{
		ChatJID: alice, MessageSenderJID: alice,
		MessageIDs: []string{"m1", "m2"}, Status: "read_self", Timestamp: 1700000600,
	})
	deadline := time.Now().Add(2 * time.Second)
	for {
		c, _ := st.GetChat(context.Background(), alice)
		if c.UnreadCount == 0 && c.LastReadTS == 1700000200 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("read_self never advanced read position: unread=%d last_read=%d", c.UnreadCount, c.LastReadTS)
		}
		time.Sleep(20 * time.Millisecond)
	}

	// read_self must not send receipts back to WhatsApp.
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if len(fw.marked) != 0 {
		t.Fatalf("read_self sent MarkRead calls: %+v", fw.marked)
	}
}

// incomingMsgAt is incomingMsg with an explicit timestamp.
func incomingMsgAt(id, chatJID, text string, ts int64) core.RawEvent {
	return core.EventMessage{Source: "live", Incoming: core.Incoming{
		Kind: core.IncomingNew,
		Message: core.Message{
			MessageID: id, ChatJID: chatJID, SenderJID: chatJID,
			Timestamp: ts, Kind: core.KindText, Text: text, Source: "live",
		},
	}}
}
