package whatsapp

import (
	"io"
	"log/slog"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
)

func quietLog() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

// Receipts in LID-addressed chats name the message sender in @lid form;
// outgoing rows are stored under the phone form, so the receipt must be
// mapped or the delivery ticks never advance.
func TestOnReceiptCanonicalizesLIDSender(t *testing.T) {
	c := &Client{
		log:     quietLog(),
		evCh:    make(chan core.RawEvent, 4),
		ownJIDs: []string{"254700000001@s.whatsapp.net"},
		lidCache: map[string]string{
			"11111111111111@lid": "254799000111@s.whatsapp.net",
		},
	}
	c.onReceipt(&events.Receipt{
		MessageSource: types.MessageSource{
			Chat: types.NewJID("254700000001", types.DefaultUserServer),
		},
		Type:          types.ReceiptTypeDelivered,
		MessageSender: types.NewJID("11111111111111", types.HiddenUserServer),
		MessageIDs:    []string{"m1"},
	})
	ev := <-c.evCh
	er, ok := ev.(core.EventReceipt)
	if !ok {
		t.Fatalf("event type = %T, want EventReceipt", ev)
	}
	if er.MessageSenderJID != "254799000111@s.whatsapp.net" {
		t.Fatalf("sender = %q, want the phone form", er.MessageSenderJID)
	}
}

// Grouped group receipts can omit the sender; for outgoing messages the
// sender of record is us — fall back to the own phone JID.
func TestOnReceiptEmptySenderFallsBackToOwnPN(t *testing.T) {
	c := &Client{
		log:     quietLog(),
		evCh:    make(chan core.RawEvent, 4),
		ownJIDs: []string{"254700000001@s.whatsapp.net", "22222222222222@lid"},
	}
	c.onReceipt(&events.Receipt{
		MessageSource: types.MessageSource{
			Chat: types.NewJID("254700000001", types.DefaultUserServer),
		},
		Type:          types.ReceiptTypeReadSelf,
		MessageSender: types.JID{},
		MessageIDs:    []string{"m1"},
	})
	ev := <-c.evCh
	er, ok := ev.(core.EventReceipt)
	if !ok {
		t.Fatalf("event type = %T, want EventReceipt", ev)
	}
	if er.MessageSenderJID != "254700000001@s.whatsapp.net" {
		t.Fatalf("sender = %q, want the own phone JID", er.MessageSenderJID)
	}
}
