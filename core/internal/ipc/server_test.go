// IPC contract (REST + WS) over the app layer:
//   - every route requires the bearer token; wrong token → 401
//   - /healthz reports status, version, connection state
//   - /chats and /chats/{jid}/messages paginate correctly
//   - POST /messages sends via the app and returns the persisted row
//   - POST /messages/{rowid}/react and POST /chats/{jid}/read hit the ports
//   - GET /session reflects login state; POST /session/link starts QR login
//   - WS echoes events emitted by the app as {type, seq, data} frames
package ipc_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/ralfiannor/whatsapp-work/internal/app"
	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/events"
	"github.com/ralfiannor/whatsapp-work/internal/ipc"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

const (
	token = "test-token-0123456789abcdef0123456789abcdef"
	alice = "254700000002@s.whatsapp.net"
	me    = "254700000001@s.whatsapp.net"
)

// fakeWA is a minimal in-memory core.WAClient for transport tests.
type fakeWA struct{ evCh chan core.RawEvent }

func (f *fakeWA) Connect(ctx context.Context) error { return nil }
func (f *fakeWA) Disconnect()                       {}
func (f *fakeWA) Logout(ctx context.Context) error  { return nil }
func (f *fakeWA) LoggedIn() bool                    { return false }
func (f *fakeWA) OwnJID() string                    { return me }
func (f *fakeWA) Events() <-chan core.RawEvent      { return f.evCh }
func (f *fakeWA) MarkRead(ctx context.Context, chat, sender string, ids []string) error {
	return nil
}
func (f *fakeWA) React(ctx context.Context, chat string, target core.MessageRef, emoji string) error {
	return nil
}
func (f *fakeWA) RevokeMessage(ctx context.Context, chat, id string) error {
	return nil
}
func (f *fakeWA) ProfilePicture(ctx context.Context, jid string) (string, error) {
	return "", nil // no picture in tests
}

func (f *fakeWA) GroupMembers(ctx context.Context, g string) ([]core.GroupMember, error) {
	return nil, nil
}
func (f *fakeWA) GroupInfoName(ctx context.Context, g string) (string, error) {
	return "", nil
}
func (f *fakeWA) ResolveLIDs(ctx context.Context) map[string]string { return nil }
func (f *fakeWA) UserNames(ctx context.Context, jids []string) (map[string]string, error) {
	return map[string]string{}, nil
}
func (f *fakeWA) SendText(ctx context.Context, chat, text string, reply *core.ReplyRef, mentioned []string) (core.SendAck, error) {
	return core.SendAck{MessageID: "SRV" + text, Timestamp: 1700000999}, nil
}

func (f *fakeWA) SendMedia(ctx context.Context, chatJID string, data []byte, mime, filename, caption string, reply *core.ReplyRef) (core.SendAck, *core.MediaMeta, error) {
	return core.SendAck{MessageID: "m1", Timestamp: 1700000000},
		&core.MediaMeta{Kind: "image", MIME: mime, Size: int64(len(data))}, nil
}
func (f *fakeWA) StartQRLogin(ctx context.Context) error {
	f.evCh <- core.EventQR{Code: "2@QR", ExpiresTS: 999}
	return nil
}

type env struct {
	t    *testing.T
	srv  *httptest.Server
	api  *app.App
	disp *events.Dispatcher
}

func newEnv(t *testing.T) *env {
	t.Helper()
	st, err := storage.Open(context.Background(), t.TempDir(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	fw := &fakeWA{evCh: make(chan core.RawEvent, 64)}
	d := events.NewDispatcher()
	a := app.New(nil, st, fw, d)
	a.SetMediaService(fakeMedia{})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	if err := a.Run(ctx); err != nil {
		t.Fatal(err)
	}
	s := ipc.New(a, d, token, "0.1.0-test", nil)
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	return &env{t: t, srv: ts, api: a, disp: d}
}

func (e *env) do(method, path, body string, authed bool) (int, map[string]any) {
	e.t.Helper()
	var rd *strings.Reader
	if body == "" {
		rd = strings.NewReader("")
	} else {
		rd = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, e.srv.URL+path, rd)
	if err != nil {
		e.t.Fatal(err)
	}
	if authed {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	if res.StatusCode != http.StatusNoContent {
		if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
			e.t.Fatalf("%s %s: non-JSON response (%d): %v", method, path, res.StatusCode, err)
		}
	}
	return res.StatusCode, out
}

func (e *env) get(path string) (int, map[string]any) { return e.do("GET", path, "", true) }
func (e *env) post(path, body string) (int, map[string]any) {
	return e.do("POST", path, body, true)
}

func TestAuthRequired(t *testing.T) {
	e := newEnv(t)
	code, _ := e.do("GET", "/healthz", "", false)
	if code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated /healthz = %d, want 401", code)
	}
	req, _ := http.NewRequest("GET", e.srv.URL+"/healthz", nil)
	req.Header.Set("Authorization", "Bearer wrong-token")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUnauthorized {
		t.Fatalf("wrong token = %d, want 401", res.StatusCode)
	}
}

func TestHealthz(t *testing.T) {
	e := newEnv(t)
	code, body := e.get("/healthz")
	if code != 200 || body["status"] != "ok" {
		t.Fatalf("healthz = %d %v", code, body)
	}
	conn := body["connection"].(map[string]any)
	if conn["state"] == "" {
		t.Fatal("connection state missing")
	}
}

func TestChatsAndMessagesPagination(t *testing.T) {
	e := newEnv(t)
	// Seed one chat with three messages via the app's send path (fake WA).
	for _, txt := range []string{"one", "two", "three"} {
		code, body := e.post("/messages", fmt.Sprintf(`{"chat_jid":%q,"text":%q}`, alice, txt))
		if code != http.StatusCreated {
			t.Fatalf("POST /messages = %d %v", code, body)
		}
	}
	code, body := e.get("/chats")
	if code != 200 {
		t.Fatalf("GET /chats = %d %v", code, body)
	}
	chats := body["chats"].([]any)
	if len(chats) != 1 {
		t.Fatalf("chats = %d, want 1", len(chats))
	}
	chat := chats[0].(map[string]any)
	if chat["jid"] != alice || chat["last_preview"] != "three" {
		t.Fatalf("chat row wrong: %v", chat)
	}

	code, body = e.get("/chats/" + alice + "/messages?limit=2")
	if code != 200 {
		t.Fatalf("messages page1 = %d %v", code, body)
	}
	msgs := body["messages"].([]any)
	if len(msgs) != 2 {
		t.Fatalf("page1 len = %d, want 2", len(msgs))
	}
	if msgs[0].(map[string]any)["text"] != "three" {
		t.Fatalf("newest first violated: %v", msgs[0])
	}
	if body["next_cursor"] == nil || body["next_cursor"] == "" {
		t.Fatalf("next_cursor missing: %v", body)
	}
	cursor := fmt.Sprint(body["next_cursor"])

	code, body = e.get("/chats/" + alice + "/messages?limit=2&before=" + cursor)
	if code != 200 {
		t.Fatalf("messages page2 = %d %v", code, body)
	}
	msgs = body["messages"].([]any)
	if len(msgs) != 1 || msgs[0].(map[string]any)["text"] != "one" {
		t.Fatalf("page2 wrong: %v", msgs)
	}
	if body["next_cursor"] != nil {
		t.Fatalf("exhausted page must have null cursor: %v", body)
	}
}

func TestReactAndRead(t *testing.T) {
	e := newEnv(t)
	_, fb := e.post("/messages", fmt.Sprintf(`{"chat_jid":%q,"text":"react to me"}`, alice))
	m := fb
	rowID := fmt.Sprint(m["id"])

	code, _ := e.post("/messages/"+rowID+"/react", `{"emoji":"✅"}`)
	if code != http.StatusNoContent {
		t.Fatalf("react = %d", code)
	}
	code, _ = e.post("/chats/"+alice+"/read", "")
	if code != http.StatusNoContent {
		t.Fatalf("read = %d", code)
	}
}

func TestSearchEndpoint(t *testing.T) {
	e := newEnv(t)
	e.post("/messages", fmt.Sprintf(`{"chat_jid":%q,"text":"deployment staging failed"}`, alice))
	code, body := e.get("/search?q=" + "deployment%20staging")
	if code != 200 {
		t.Fatalf("search = %d %v", code, body)
	}
	msgs := body["messages"].([]any)
	if len(msgs) != 1 {
		t.Fatalf("search hits = %v", msgs)
	}
	hit := msgs[0].(map[string]any)
	if hit["snippet"] == "" || hit["chat_jid"] != alice {
		t.Fatalf("hit wrong: %v", hit)
	}
}

func TestSessionFlow(t *testing.T) {
	e := newEnv(t)
	code, body := e.get("/session")
	if code != 200 || body["state"] != "logged_out" {
		t.Fatalf("initial session = %d %v", code, body)
	}

	code, _ = e.post("/session/link", `{"mode":"qr"}`)
	if code != http.StatusAccepted {
		t.Fatalf("link = %d", code)
	}

	// QR pushed by the core (via StartQRLogin in the fake) shows up in /session.
	deadline := time.Now().Add(2 * time.Second)
	for {
		_, body := e.get("/session")
		if qr, ok := body["qr"].(map[string]any); ok && qr["code"] == "2@QR" {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("QR never showed in /session: %v", body)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func TestWebSocketEvents(t *testing.T) {
	e := newEnv(t)
	h := &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": []string{"Bearer " + token}}}
	conn, _, err := websocket.Dial(context.Background(), e.srv.URL+"/ws", h)
	if err != nil {
		t.Fatalf("ws dial: %v", err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Trigger an event via the app.
	go func() {
		_, _ = e.api.SendText(context.Background(), alice, "ws test", nil, nil)
	}()

	readCtx, cancelRead := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancelRead()
	typ, data, err := conn.Read(readCtx)
	if err != nil {
		t.Fatal(err)
	}
	if typ != websocket.MessageText {
		t.Fatalf("frame type = %v", typ)
	}
	var env struct {
		Type string         `json:"type"`
		Seq  int64          `json:"seq"`
		Data map[string]any `json:"data"`
	}
	if err := json.Unmarshal(data, &env); err != nil {
		t.Fatal(err)
	}
	if env.Seq < 1 {
		t.Fatalf("seq = %d, want >= 1", env.Seq)
	}
	switch env.Type {
	case "message.received", "chat.updated":
		msg := env.Data["message"].(map[string]any)
		if msg["chat_jid"] != alice {
			t.Fatalf("ws message wrong: %v", env.Data)
		}
	default:
		t.Fatalf("unexpected event type %q", env.Type)
	}

	// Unauthenticated WS dial must fail.
	if _, _, err := websocket.Dial(context.Background(), e.srv.URL+"/ws", nil); err == nil {
		t.Fatal("unauthenticated ws dial accepted")
	}
}
