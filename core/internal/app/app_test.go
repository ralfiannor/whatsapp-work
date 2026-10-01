// App layer contract:
//   - ingest persists before emitting; deduped messages don't re-emit message.received
//   - revoke / edit / receipt / reaction paths update storage and emit message.updated / reaction.received
//   - SendText calls the WA port, persists the outgoing row as sent, emits message.received
//   - MarkChatRead sends read receipts via the port and clears counters
//   - Logout wipes local data and resets state
package app_test

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/app"
	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/events"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

const (
	me    = "254700000001@s.whatsapp.net"
	alice = "254700000002@s.whatsapp.net"
	group = "1203630000000000@g.us"
)

// fakeWA is an in-memory core.WAClient.
type mediaSent struct {
	chat, mime, filename, caption string
	data                          []byte
	reply                         *core.ReplyRef
}

type fakeWA struct {
	mu        sync.Mutex
	evCh      chan core.RawEvent
	sendErr   error
	sent      []sentCall
	marked    []markCall
	media     []mediaSent
	reacts    []reactCall
	revokes   []revokeCall
	revokeErr error
	logouts   int
	links     int
	loggedIn  bool
	// usync directory answers (jid -> verified business name).
	userNames map[string]string
}

type sentCall struct {
	chat, text string
	reply      *core.ReplyRef
}
type markCall struct {
	chat, sender string
	ids          []string
}
type reactCall struct {
	chat, target, emoji string
}
type revokeCall struct {
	chat, id string
}

func newFakeWA() *fakeWA { return &fakeWA{evCh: make(chan core.RawEvent, 64)} }

func (f *fakeWA) Connect(ctx context.Context) error { return nil }
func (f *fakeWA) Disconnect()                       {}
func (f *fakeWA) Logout(ctx context.Context) error {
	f.mu.Lock()
	f.logouts++
	f.mu.Unlock()
	return nil
}
func (f *fakeWA) LoggedIn() bool { return f.loggedIn }
func (f *fakeWA) OwnJID() string { return me }
func (f *fakeWA) StartQRLogin(ctx context.Context) error {
	f.mu.Lock()
	f.links++
	f.mu.Unlock()
	return nil
}
func (f *fakeWA) Events() <-chan core.RawEvent { return f.evCh }
func (f *fakeWA) ProfilePicture(ctx context.Context, jid string) (string, error) {
	return "", nil // no picture in tests
}

func (f *fakeWA) GroupMembers(ctx context.Context, g string) ([]core.GroupMember, error) {
	return []core.GroupMember{{JID: alice, Role: "admin"}}, nil
}
func (f *fakeWA) GroupInfoName(ctx context.Context, g string) (string, error) {
	return "Backend Team", nil
}
func (f *fakeWA) ResolveLIDs(ctx context.Context) map[string]string {
	return map[string]string{"999000111222333@lid": alice}
}

func (f *fakeWA) UserNames(ctx context.Context, jids []string) (map[string]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := map[string]string{}
	for _, j := range jids {
		if n, ok := f.userNames[j]; ok {
			out[j] = n
		}
	}
	return out, nil
}

func (f *fakeWA) SendText(ctx context.Context, chat, text string, reply *core.ReplyRef, mentioned []string) (core.SendAck, error) {
	f.mu.Lock()
	f.sent = append(f.sent, sentCall{chat, text, reply})
	f.mu.Unlock()
	if f.sendErr != nil {
		return core.SendAck{}, f.sendErr
	}
	return core.SendAck{MessageID: "SRV" + text, Timestamp: 1700000999}, nil
}

func (f *fakeWA) SendMedia(ctx context.Context, chatJID string, data []byte, mime, filename, caption string, reply *core.ReplyRef) (core.SendAck, *core.MediaMeta, error) {
	f.mu.Lock()
	f.media = append(f.media, mediaSent{chatJID, mime, filename, caption, data, reply})
	f.mu.Unlock()
	md := &core.MediaMeta{Kind: "image", MIME: mime, Size: int64(len(data)), URL: "u", DirectPath: "/p"}
	switch {
	case strings.HasPrefix(mime, "video/"):
		md.Kind = "video"
	case strings.HasPrefix(mime, "audio/"):
		md.Kind = "audio"
	case !strings.HasPrefix(mime, "image/"):
		md.Kind = "document"
	}
	return core.SendAck{MessageID: "media1", Timestamp: 1700000100}, md, nil
}

func (f *fakeWA) React(ctx context.Context, chat string, target core.MessageRef, emoji string) error {
	f.mu.Lock()
	f.reacts = append(f.reacts, reactCall{chat, target.ID, emoji})
	f.mu.Unlock()
	return nil
}

func (f *fakeWA) MarkRead(ctx context.Context, chat, sender string, ids []string) error {
	f.mu.Lock()
	f.marked = append(f.marked, markCall{chat, sender, ids})
	f.mu.Unlock()
	return nil
}

func (f *fakeWA) RevokeMessage(ctx context.Context, chat, id string) error {
	f.mu.Lock()
	f.revokes = append(f.revokes, revokeCall{chat, id})
	f.mu.Unlock()
	return f.revokeErr
}

func (f *fakeWA) push(ev core.RawEvent) { f.evCh <- ev }

func newTestApp(t *testing.T) (*app.App, *fakeWA, *events.Dispatcher, *storage.Store) {
	t.Helper()
	st, err := storage.Open(context.Background(), t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	fw := newFakeWA()
	d := events.NewDispatcher()
	a := app.New(nil, st, fw, d)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if err := a.Run(ctx); err != nil {
		t.Fatal(err)
	}
	return a, fw, d, st
}

// subscribe wires a test subscription with an cancel func.
func subscribe(t *testing.T, d *events.Dispatcher, n int) <-chan events.Event {
	t.Helper()
	id, ch := d.Subscribe(n)
	t.Cleanup(func() { d.Unsubscribe(id) })
	return ch
}

func waitFor(t *testing.T, ch <-chan events.Event, typ string) events.Event {
	t.Helper()
	for {
		select {
		case ev := <-ch:
			if ev.Type == typ {
				return ev
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("timed out waiting for %q", typ)
		}
	}
}

func incomingMsg(id, chat, sender, text string) core.RawEvent {
	return core.EventMessage{Source: "live", Incoming: core.Incoming{
		Kind: core.IncomingNew,
		Message: core.Message{
			MessageID: id, ChatJID: chat, SenderJID: sender,
			Timestamp: 1700000100, Kind: core.KindText, Text: text, Source: "live",
		},
	}}
}

func TestIngestPersistsThenEmits(t *testing.T) {
	_, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	fw.push(incomingMsg("m1", alice, alice, "hello"))

	ev := waitFor(t, sub, "message.received")
	m := ev.Data.(core.Message)
	if m.Text != "hello" || m.ChatJID != alice {
		t.Fatalf("event message wrong: %+v", m)
	}

	c, err := st.GetChat(context.Background(), alice)
	if err != nil || c == nil {
		t.Fatalf("chat not ensured: %v", err)
	}
	if c.Kind != core.KindDirect {
		t.Fatalf("chat kind = %v, want direct", c.Kind)
	}
	if c.UnreadCount != 1 {
		t.Fatalf("unread = %d, want 1", c.UnreadCount)
	}
	msgs, _ := st.ListMessages(context.Background(), alice, 0, 0, 10)
	if len(msgs) != 1 || msgs[0].MessageID != "m1" {
		t.Fatalf("persisted wrong: %+v", msgs)
	}
	waitFor(t, sub, "chat.updated")

	// Duplicate delivery (history + live overlap) must not re-emit received.
	fw.push(incomingMsg("m1", alice, alice, "hello"))
	deadline := time.After(300 * time.Millisecond)
	for {
		select {
		case ev := <-sub:
			if ev.Type == "message.received" {
				t.Fatal("duplicate ingest re-emitted message.received")
			}
		case <-deadline:
			msgs, _ := st.ListMessages(context.Background(), alice, 0, 0, 10)
			if len(msgs) != 1 {
				t.Fatalf("duplicate row inserted: %d", len(msgs))
			}
			return
		}
	}
}

func TestIngestRevokeEditReceiptReaction(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 64)

	fw.push(incomingMsg("m1", alice, alice, "hello"))
	waitFor(t, sub, "message.received")

	fw.push(core.EventMessage{Source: "live", Incoming: core.Incoming{
		Kind:   core.IncomingEdit,
		Revoke: core.RevokeRef{ChatJID: alice, MessageID: "m1", SenderJID: alice},
		Message: core.Message{
			MessageID: "m1", ChatJID: alice, SenderJID: alice,
			Timestamp: 1700000100, Kind: core.KindText, Text: "hello (edited)",
			Source: "live", EditedTS: 1700000500,
		},
	}})
	waitFor(t, sub, "message.updated")
	msgs, _ := st.ListMessages(context.Background(), alice, 0, 0, 10)
	if msgs[0].Text != "hello (edited)" || msgs[0].EditedTS != 1700000500 {
		t.Fatalf("edit not applied: %+v", msgs[0])
	}

	fw.push(core.EventMessage{Source: "live", Incoming: core.Incoming{
		Kind:   core.IncomingRevoke,
		Revoke: core.RevokeRef{ChatJID: alice, MessageID: "m1", SenderJID: alice, Timestamp: 1700000600},
	}})
	waitFor(t, sub, "message.updated")
	msgs, _ = st.ListMessages(context.Background(), alice, 0, 0, 10)
	if !msgs[0].Revoked {
		t.Fatal("revoke not applied")
	}

	// Outgoing message then a read receipt for it.
	_, err := a.SendText(context.Background(), alice, "out", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, sub, "message.received")
	fw.push(core.EventReceipt{ChatJID: alice, MessageSenderJID: me, MessageIDs: []string{"SRVout"}, Status: "read"})
	waitFor(t, sub, "message.updated")
	msgs, _ = st.ListMessages(context.Background(), alice, 0, 0, 10)
	found := false
	for _, m := range msgs {
		if m.MessageID == "SRVout" && m.ReceiptStatus == "read" {
			found = true
		}
	}
	if !found {
		t.Fatalf("read receipt not applied: %+v", msgs)
	}

	fw.push(core.EventReaction{ChatJID: alice, TargetMessageID: "SRVout", ReactorJID: alice, Emoji: "👍", Timestamp: 1700000700})
	waitFor(t, sub, "reaction.received")
}

func TestSendTextPersistsAndEmits(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	sent, err := a.SendText(context.Background(), alice, "review please", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if sent.MessageID != "SRVreview please" || !sent.FromMe || sent.ReceiptStatus != "sent" {
		t.Fatalf("send result wrong: %+v", sent)
	}
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if len(fw.sent) != 1 || fw.sent[0].chat != alice || fw.sent[0].text != "review please" {
		t.Fatalf("port call wrong: %+v", fw.sent)
	}
	waitFor(t, sub, "message.received")
	msgs, _ := st.ListMessages(context.Background(), alice, 0, 0, 10)
	if len(msgs) != 1 || !msgs[0].FromMe {
		t.Fatalf("outgoing row wrong: %+v", msgs)
	}
	c, _ := st.GetChat(context.Background(), alice)
	if c.UnreadCount != 0 {
		t.Fatalf("own message inflated unread: %d", c.UnreadCount)
	}
}

func TestMarkChatReadSendsReceipts(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	fw.push(incomingMsg("m1", alice, alice, "one"))
	fw.push(incomingMsg("m2", alice, alice, "two"))
	waitFor(t, sub, "message.received")
	waitFor(t, sub, "message.received") // both must be durable before reading

	if err := a.MarkChatRead(context.Background(), alice, true); err != nil {
		t.Fatal(err)
	}
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if len(fw.marked) != 1 {
		t.Fatalf("MarkRead calls = %+v", fw.marked)
	}
	mc := fw.marked[0]
	if mc.chat != alice || mc.sender != alice || len(mc.ids) != 2 {
		t.Fatalf("MarkRead args wrong: %+v", mc)
	}
	c, _ := st.GetChat(context.Background(), alice)
	if c.UnreadCount != 0 {
		t.Fatalf("unread after read = %d", c.UnreadCount)
	}
}

func TestLogoutWipesAndResets(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	fw.loggedIn = true
	fw.push(core.EventConnState{State: core.StateConnected})
	fw.push(incomingMsg("m1", alice, alice, "secret"))
	waitFor(t, sub, "message.received")

	if err := a.Logout(context.Background()); err != nil {
		t.Fatal(err)
	}
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if fw.logouts != 1 {
		t.Fatalf("port logout calls = %d", fw.logouts)
	}
	if a.State() != core.StateLoggedOut {
		t.Fatalf("state after logout = %v", a.State())
	}
	if c, err := st.GetChat(context.Background(), alice); err == nil && c != nil {
		t.Fatal("data survived logout wipe")
	}
}

func TestSendMediaPersistsAndEmits(t *testing.T) {
	app, wa, _, st := newTestApp(t)
	ctx := context.Background()
	if err := st.EnsureChat(ctx, core.Chat{JID: alice, Kind: core.KindDirect, DisplayName: "Alice"}); err != nil {
		t.Fatal(err)
	}
	img := []byte("fakejpegbytes")
	m, err := app.SendMedia(ctx, alice, img, "image/jpeg", "", "look at this", nil)
	if err != nil {
		t.Fatal(err)
	}
	if m.Kind != core.KindImage || m.Text != "look at this" || !m.FromMe {
		t.Fatalf("bad outgoing row: %+v", m)
	}
	if m.Media == nil || m.Media.URL != "u" {
		t.Fatalf("media meta missing: %+v", m.Media)
	}
	wa.mu.Lock()
	sent := len(wa.media)
	wa.mu.Unlock()
	if sent != 1 {
		t.Fatalf("SendMedia calls = %d", sent)
	}
	// Row durable + media row attached (re-download material).
	row, err := st.GetMessage(ctx, m.ID)
	if err != nil {
		t.Fatal(err)
	}
	if row.Media == nil || row.Media.Size != int64(len(img)) {
		t.Fatalf("persisted media lost: %+v", row.Media)
	}
}

func TestDeleteMessageRevokesOwnRow(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	sent, err := a.SendText(context.Background(), alice, "oops", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	waitFor(t, sub, "message.received")

	if err := a.DeleteMessage(context.Background(), sent.ID); err != nil {
		t.Fatal(err)
	}
	fw.mu.Lock()
	if len(fw.revokes) != 1 || fw.revokes[0].chat != alice || fw.revokes[0].id != "SRVoops" {
		fw.mu.Unlock()
		t.Fatalf("revoke calls = %+v", fw.revokes)
	}
	fw.mu.Unlock()
	waitFor(t, sub, "message.updated")
	// Sidebar refresh: SetRevoked cleared last_preview, the chat row event
	// must reach the client too (message-then-chat, as in SendText).
	waitFor(t, sub, "chat.updated")

	m, err := st.GetMessage(context.Background(), sent.ID)
	if err != nil {
		t.Fatal(err)
	}
	if !m.Revoked || m.Text != "" {
		t.Fatalf("row not revoked: %+v", m)
	}

	// Idempotent: an already-revoked row is a no-op, no second wire call.
	if err := a.DeleteMessage(context.Background(), sent.ID); err != nil {
		t.Fatal(err)
	}
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if len(fw.revokes) != 1 {
		t.Fatalf("second delete hit the wire: %+v", fw.revokes)
	}
}

func TestDeleteMessageRejectsIncoming(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	fw.push(incomingMsg("m9", alice, alice, "hello"))
	waitFor(t, sub, "message.received")
	msgs, _ := st.ListMessages(context.Background(), alice, 0, 0, 10)
	if len(msgs) != 1 {
		t.Fatalf("ingest: %+v", msgs)
	}

	if err := a.DeleteMessage(context.Background(), msgs[0].ID); !errors.Is(err, app.ErrNotOwnMessage) {
		t.Fatalf("want ErrNotOwnMessage, got %v", err)
	}
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if len(fw.revokes) != 0 {
		t.Fatalf("incoming row hit the wire: %+v", fw.revokes)
	}
}

func TestDeleteMessageWAFailureLeavesRowIntact(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	sent, _ := a.SendText(context.Background(), alice, "boom", nil, nil)
	waitFor(t, sub, "message.received")

	fw.mu.Lock()
	fw.revokeErr = errors.New("net down")
	fw.mu.Unlock()
	if err := a.DeleteMessage(context.Background(), sent.ID); err == nil {
		t.Fatal("want error")
	}
	m, _ := st.GetMessage(context.Background(), sent.ID)
	if m.Revoked || m.Text != "boom" {
		t.Fatalf("row must stay intact on wire failure: %+v", m)
	}

	// Recovery: same row deletes fine once the wire works again.
	fw.mu.Lock()
	fw.revokeErr = nil
	fw.mu.Unlock()
	if err := a.DeleteMessage(context.Background(), sent.ID); err != nil {
		t.Fatal(err)
	}
}

func TestDeleteMessageNotFound(t *testing.T) {
	a, _, _, _ := newTestApp(t)
	if err := a.DeleteMessage(context.Background(), 999999); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("want storage.ErrNotFound, got %v", err)
	}
}

func TestMarkChatReadLocalOnlyClearsWithoutReceipt(t *testing.T) {
	a, fw, d, st := newTestApp(t)
	sub := subscribe(t, d, 16)

	fw.push(incomingMsg("m1", alice, alice, "one"))
	waitFor(t, sub, "message.received")
	if c, _ := st.GetChat(context.Background(), alice); c.UnreadCount != 1 {
		t.Fatalf("unread before = %d", c.UnreadCount)
	}

	if err := a.MarkChatRead(context.Background(), alice, false); err != nil {
		t.Fatal(err)
	}
	fw.mu.Lock()
	if len(fw.marked) != 0 {
		fw.mu.Unlock()
		t.Fatalf("local-only read sent receipts: %+v", fw.marked)
	}
	fw.mu.Unlock()
	if c, _ := st.GetChat(context.Background(), alice); c.UnreadCount != 0 {
		t.Fatalf("unread after = %d", c.UnreadCount)
	}
	waitFor(t, sub, "chat.updated")

	// Traffic after the local read still bumps the badge. The fixture must
	// arrive past the advanced read position (unread = timestamp > last_read_ts).
	fw.push(incomingMsgAt("m2", alice, "two", 1700000200))
	waitFor(t, sub, "message.received")
	if c, _ := st.GetChat(context.Background(), alice); c.UnreadCount != 1 {
		t.Fatalf("unread after new incoming = %d", c.UnreadCount)
	}
}

func TestMarkChatReadLocalOnlyNoUnreadIsNoop(t *testing.T) {
	a, fw, _, _ := newTestApp(t)
	if err := a.MarkChatRead(context.Background(), alice, false); err != nil {
		t.Fatal(err)
	}
	fw.mu.Lock()
	defer fw.mu.Unlock()
	if len(fw.marked) != 0 {
		t.Fatalf("noop read sent receipts: %+v", fw.marked)
	}
}
