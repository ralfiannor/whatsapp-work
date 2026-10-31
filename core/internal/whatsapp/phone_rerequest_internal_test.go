package whatsapp

import (
	"context"
	"testing"
	"time"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// A group message that fails to decrypt is only recoverable from the
// account's own phone when the sender's device ignores the retry receipt.
// The phone's copy comes back shaped like a history record but must ingest
// as live (unread + inbox), while a real history record stays history.
func TestPhoneRerequestRecoversAsLive(t *testing.T) {
	c, err := New(context.Background(), t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer c.sessDB.Close()

	if !c.cli.AutomaticMessageRerequestFromPhone {
		t.Fatal("undecryptable messages are never re-requested from the phone")
	}

	group := types.NewJID("1203630000000000", types.GroupServer)
	sender := types.NewJID("6285000000001", types.DefaultUserServer)
	msg := func(id string, reqID types.MessageID) *events.Message {
		return &events.Message{
			Info: types.MessageInfo{
				MessageSource: types.MessageSource{Chat: group, Sender: sender, IsGroup: true},
				ID:            id,
				Timestamp:     time.Unix(1_750_000_000, 0),
			},
			Message:              &waE2E.Message{Conversation: proto.String("hello")},
			SourceWebMsg:         &waWeb.WebMessageInfo{},
			UnavailableRequestID: reqID,
		}
	}

	for _, tc := range []struct {
		name string
		evt  *events.Message
		want string
	}{
		{"phone resend", msg("3EB0000000000000000001", "3EB0000000000000000099"), "live"},
		{"history record", msg("3EB0000000000000000002", ""), "history"},
	} {
		c.onEvent(tc.evt)
		select {
		case ev := <-c.Events():
			em, ok := ev.(core.EventMessage)
			if !ok {
				t.Fatalf("%s: got %T, want core.EventMessage", tc.name, ev)
			}
			if em.Source != tc.want || em.Incoming.Message.Source != tc.want {
				t.Errorf("%s: source = %q/%q, want %q",
					tc.name, em.Source, em.Incoming.Message.Source, tc.want)
			}
		case <-time.After(time.Second):
			t.Fatalf("%s: no event emitted", tc.name)
		}
	}

	// The failure itself reaches ingest as a live placeholder row.
	c.onEvent(&events.UndecryptableMessage{Info: msg("3EB0000000000000000003", "").Info})
	select {
	case ev := <-c.Events():
		em, ok := ev.(core.EventMessage)
		if !ok || em.Source != "live" || em.Incoming.Message.RawKind != core.RawKindPending {
			t.Fatalf("undecryptable emitted %+v", ev)
		}
	case <-time.After(time.Second):
		t.Fatal("undecryptable message emitted no placeholder")
	}
}
