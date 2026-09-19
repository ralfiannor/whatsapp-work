// Package ipc exposes the app over localhost HTTP + WebSocket with bearer
// token auth (docs/protocol.md). It binds nothing itself — the caller owns
// the listener so it can pick a random port and print the READY line.
package ipc

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/ralfiannor/whatsapp-work/internal/app"
	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/events"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

// Server serves the IPC API.
type Server struct {
	api     *app.App
	disp    *events.Dispatcher
	token   string
	version string
	log     *slog.Logger
	start   time.Time
	httpSrv *http.Server
	hub     *hub
}

func New(a *app.App, d *events.Dispatcher, token, version string, lg *slog.Logger) *Server {
	if lg == nil {
		lg = slog.Default()
	}
	s := &Server{api: a, disp: d, token: token, version: version, log: lg, start: time.Now()}
	s.hub = newHub(d, lg)
	go s.hub.run()
	return s
}

// Handler builds the full middleware-wrapped route table (also used by tests).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.handleHealthz)
	mux.HandleFunc("GET /session", s.handleSession)
	mux.HandleFunc("POST /session/link", s.handleLink)
	mux.HandleFunc("POST /session/logout", s.handleLogout)
	mux.HandleFunc("GET /chats", s.handleChats)
	mux.HandleFunc("GET /chats/{jid}/messages", s.handleChatMessages)
	mux.HandleFunc("POST /chats/{jid}/read", s.handleChatRead)
	mux.HandleFunc("POST /messages", s.handleSendMessage)
	mux.HandleFunc("POST /chats/{jid}/media", s.handleSendMedia)
	mux.HandleFunc("POST /messages/{id}/react", s.handleReact)
	mux.HandleFunc("POST /messages/{id}/delete", s.handleMsgDelete)
	mux.HandleFunc("GET /contacts", s.handleContacts)
	mux.HandleFunc("GET /contacts/{jid}/profile", s.handleProfile)
	mux.HandleFunc("GET /contacts/{jid}/identity", s.handleIdentity)
	mux.HandleFunc("GET /groups/{jid}/members", s.handleGroupMembers)
	mux.HandleFunc("GET /search", s.handleSearch)
	mux.HandleFunc("GET /inbox", s.handleInbox)
	mux.HandleFunc("POST /messages/{id}/done", s.handleMsgDone)
	mux.HandleFunc("POST /messages/{id}/snooze", s.handleMsgSnooze)
	mux.HandleFunc("POST /messages/{id}/star", s.handleMsgStar)
	mux.HandleFunc("POST /chats/{jid}/star", s.handleChatStar)
	mux.HandleFunc("POST /chats/{jid}/work", s.handleChatWork)
	mux.HandleFunc("POST /chats/{jid}/done", s.handleChatDone)
	mux.HandleFunc("POST /chats/{jid}/snooze", s.handleChatSnooze)
	mux.HandleFunc("POST /media/{id}/download", s.handleMediaDownload)
	mux.HandleFunc("GET /media/{id}/file", s.handleMediaFile)
	mux.HandleFunc("GET /ws", s.handleWS)
	return s.auth(mux)
}

// Serve runs the API on ln until Shutdown. The http.Server is built before
// Serve starts so Shutdown (called from another goroutine) never races the
// field write.
func (s *Server) Serve(ln net.Listener) error {
	s.httpSrv = &http.Server{Handler: s.Handler(), ReadHeaderTimeout: 5 * time.Second}
	ready := s.httpSrv // local copy: Shutdown may run concurrently with Serve
	err := ready.Serve(ln)
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

// Shutdown stops the HTTP server and the WS hub.
func (s *Server) Shutdown(ctx context.Context) error {
	if s.hub != nil {
		s.hub.close()
	}
	if s.httpSrv != nil {
		return s.httpSrv.Shutdown(ctx)
	}
	return nil
}

// ---- middleware ----

func (s *Server) auth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !s.hostAllowed(r.Host) {
			writeErr(w, http.StatusBadRequest, "bad_request", "unexpected Host header")
			return
		}
		if !s.tokenOK(r) {
			writeErr(w, http.StatusUnauthorized, "unauthorized", "missing or invalid token")
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) hostAllowed(host string) bool {
	h := host
	if i := strings.LastIndexByte(h, ':'); i >= 0 {
		h = h[:i] // strip port (no IPv6 in our bind)
	}
	return isLoopbackHost(h)
}

func isLoopbackHost(h string) bool {
	return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
}

func (s *Server) tokenOK(r *http.Request) bool {
	tok := r.Header.Get("Authorization")
	tok = strings.TrimPrefix(tok, "Bearer ")
	if tok == "" && r.URL.Path == "/ws" {
		// query token only for WS upgrades (browsers can't set headers);
		// every other route is header-only so tokens stay out of URLs/logs
		tok = r.URL.Query().Get("token")
	}
	if tok == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(tok), []byte(s.token)) == 1
}

// ---- handlers ----

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	ing, errs, dropped := s.api.Stats()
	writeJSON(w, http.StatusOK, map[string]any{
		"status":   "ok",
		"version":  s.version,
		"uptime_s": s.api.Uptime(),
		"connection": map[string]any{
			"state": string(s.api.State()),
		},
		"stats": map[string]any{
			"messages_ingested": ing,
			"ingest_errors":     errs,
			"events_dropped":    dropped,
		},
	})
}

func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.api.Session(r.Context()))
}

func (s *Server) handleLink(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Mode string `json:"mode"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if body.Mode != "" && body.Mode != "qr" {
		writeErr(w, http.StatusBadRequest, "bad_request", "unsupported link mode")
		return
	}
	if err := s.api.StartLink(r.Context()); err != nil {
		writeErr(w, http.StatusConflict, "conflict", err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, map[string]any{"state": "linking"})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if err := s.api.Logout(r.Context()); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// clampLimit caps a page request below the store's 200-row maximum: the
// handler probes with limit+1, so a cap of 199 keeps the probe within the
// store's clamp. Anything larger used to come back as 50 rows with no
// next_cursor — the client would think the list was complete.
func clampLimit(n int) int {
	if n < 1 {
		return 50
	}
	if n > 199 {
		return 199
	}
	return n
}

// parseChatCursor accepts both "ts,jid" (current) and bare "ts" (legacy)
// keyset cursors for the chat list.
func parseChatCursor(c string) (int64, string) {
	if c == "" {
		return 0, ""
	}
	tsStr, jid, _ := strings.Cut(c, ",")
	ts, _ := strconv.ParseInt(tsStr, 10, 64)
	return ts, jid
}

func parseInt(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func (s *Server) handleChats(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit := clampLimit(parseInt(q.Get("limit")))
	cursor, cursorJID := parseChatCursor(q.Get("cursor"))
	chats, err := s.api.Chats(r.Context(), limit+1, cursor, cursorJID, q.Get("filter"))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	var next any
	if len(chats) > limit { // the +1 probe row means another page exists
		chats = chats[:limit]
		last := chats[len(chats)-1]
		next = strconv.FormatInt(last.LastMessageTS, 10) + "," + last.JID
	}
	writeJSON(w, http.StatusOK, map[string]any{"chats": chats, "next_cursor": next})
}

func (s *Server) handleChatMessages(w http.ResponseWriter, r *http.Request) {
	jid := r.PathValue("jid")
	q := r.URL.Query()
	limit := clampLimit(parseInt(q.Get("limit")))
	var beforeTS, beforeID int64
	if before := q.Get("before"); before != "" {
		parts := strings.SplitN(before, ",", 2)
		beforeTS, _ = strconv.ParseInt(parts[0], 10, 64)
		if len(parts) == 2 {
			beforeID, _ = strconv.ParseInt(parts[1], 10, 64)
		}
	}
	msgs, err := s.api.ChatMessages(r.Context(), jid, beforeTS, beforeID, limit+1)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	var next any
	if len(msgs) > limit { // the +1 probe row means another page exists
		msgs = msgs[:limit]
		last := msgs[len(msgs)-1]
		next = fmt.Sprintf("%d,%d", last.Timestamp, last.ID)
	}
	writeJSON(w, http.StatusOK, map[string]any{"messages": msgs, "next_cursor": next})
}

func (s *Server) handleChatRead(w http.ResponseWriter, r *http.Request) {
	if err := s.api.MarkChatRead(r.Context(), r.PathValue("jid")); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleSendMessage(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ChatJID      string         `json:"chat_jid"`
		Text         string         `json:"text"`
		ReplyTo      *core.ReplyRef `json:"reply_to"`
		MentionedIDs []string       `json:"mentioned_jids"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if body.ChatJID == "" || body.Text == "" {
		writeErr(w, http.StatusBadRequest, "bad_request", "chat_jid and text are required")
		return
	}
	m, err := s.api.SendText(r.Context(), body.ChatJID, body.Text, body.ReplyTo, body.MentionedIDs)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, m)
}

// handleSendMedia uploads raw body bytes as media: Content-Type is the media
// mime; caption/filename/reply_id/reply_sender ride as query params.
func (s *Server) handleSendMedia(w http.ResponseWriter, r *http.Request) {
	jid := r.PathValue("jid")
	mime := r.Header.Get("Content-Type")
	if mime == "" {
		mime = "application/octet-stream"
	}
	q := r.URL.Query()
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 21<<20))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "media body: "+err.Error())
		return
	}
	var reply *core.ReplyRef
	if id := q.Get("reply_id"); id != "" {
		reply = &core.ReplyRef{ID: id, Sender: q.Get("reply_sender")}
	}
	m, err := s.api.SendMedia(r.Context(), jid, body, mime,
		q.Get("filename"), q.Get("caption"), reply)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusCreated, m)
}

func (s *Server) handleReact(w http.ResponseWriter, r *http.Request) {
	rowID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "bad message id")
		return
	}
	var body struct {
		Emoji string `json:"emoji"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := s.api.React(r.Context(), rowID, body.Emoji); err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "no such message")
			return
		}
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleMsgDelete revokes the caller's own message for everyone.
func (s *Server) handleMsgDelete(w http.ResponseWriter, r *http.Request) {
	rowID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "bad message id")
		return
	}
	if err := s.api.DeleteMessage(r.Context(), rowID); err != nil {
		switch {
		case errors.Is(err, storage.ErrNotFound):
			writeErr(w, http.StatusNotFound, "not_found", "message not found")
		case errors.Is(err, app.ErrNotOwnMessage):
			writeErr(w, http.StatusBadRequest, "bad_request", "only own messages can be deleted")
		default:
			writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		}
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleContacts(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	cs, err := s.api.Contacts(r.Context(), q.Get("q"), limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"contacts": cs})
}

func (s *Server) handleGroupMembers(w http.ResponseWriter, r *http.Request) {
	members, err := s.api.GroupMembers(r.Context(), r.PathValue("jid"))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"members": members})
}

// handleIdentity serves GET /contacts/{jid}/identity — the PN↔LID pair
// for a person (local lid map, no network).
func (s *Server) handleIdentity(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.api.ContactIdentity(r.Context(), r.PathValue("jid")))
}

// handleProfile serves GET /contacts/{jid}/profile?group=<optional group jid>.
func (s *Server) handleProfile(w http.ResponseWriter, r *http.Request) {
	p, err := s.api.Profile(r.Context(), r.PathValue("jid"), r.URL.Query().Get("group"))
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, p)
}

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	limit, _ := strconv.Atoi(q.Get("limit"))
	res, err := s.api.Search(r.Context(), q.Get("q"), limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

func (s *Server) handleInbox(w http.ResponseWriter, r *http.Request) {
	limit := clampLimit(parseInt(r.URL.Query().Get("limit")))
	inbox, err := s.api.Inbox(r.Context(), limit)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, inbox)
}

func boolBody(field string) bool { return field == "true" || field == "1" }

func (s *Server) handleMsgDone(w http.ResponseWriter, r *http.Request) {
	rowID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "bad message id")
		return
	}
	var body struct {
		Done bool `json:"done"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := s.api.SetMessageDone(r.Context(), rowID, body.Done); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleMsgSnooze(w http.ResponseWriter, r *http.Request) {
	rowID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "bad message id")
		return
	}
	var body struct {
		// Until is the preferred absolute form (unix seconds; 0 = clear) —
		// "tomorrow 09:00" style targets are computed where the calendar
		// lives (the client), not translated through a relative offset.
		Until   int64 `json:"until"`
		Minutes int64 `json:"minutes"` // legacy relative form
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	until := int64(0)
	switch {
	case body.Until > 0:
		until = body.Until
	case body.Minutes > 0:
		until = time.Now().Add(time.Duration(body.Minutes) * time.Minute).Unix()
	}
	if err := s.api.SetMessageSnoozed(r.Context(), rowID, until); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"snoozed_until": until})
}

func (s *Server) handleMsgStar(w http.ResponseWriter, r *http.Request) {
	rowID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "bad message id")
		return
	}
	var body struct {
		Starred bool `json:"starred"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := s.api.SetMessageStarred(r.Context(), rowID, body.Starred); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleChatStar(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Starred bool `json:"starred"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := s.api.SetChatStarred(r.Context(), r.PathValue("jid"), body.Starred); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleChatWork(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Work bool `json:"work"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := s.api.SetChatWork(r.Context(), r.PathValue("jid"), body.Work); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleChatDone/handleChatSnooze are the conversation-level bulk actions:
// one Done clears every pending item of the chat; the snooze deadline lives
// on the chat so it also holds messages that arrive later.
func (s *Server) handleChatDone(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Done bool `json:"done"`
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := s.api.SetChatDone(r.Context(), r.PathValue("jid"), body.Done); err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "no such chat")
			return
		}
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleChatSnooze(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Until   int64 `json:"until"`   // absolute unix seconds (0 = clear)
		Minutes int64 `json:"minutes"` // legacy relative form
	}
	if err := decodeBody(r, &body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	until := int64(0)
	switch {
	case body.Until > 0:
		until = body.Until
	case body.Minutes > 0:
		until = time.Now().Add(time.Duration(body.Minutes) * time.Minute).Unix()
	}
	if err := s.api.SetChatSnooze(r.Context(), r.PathValue("jid"), until); err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			writeErr(w, http.StatusNotFound, "not_found", "no such chat")
			return
		}
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"snoozed_until": until})
}

func (s *Server) handleMediaDownload(w http.ResponseWriter, r *http.Request) {
	rowID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "bad message id")
		return
	}
	m, err := s.api.DownloadMedia(r.Context(), rowID)
	switch {
	case errors.Is(err, storage.ErrNotFound):
		writeErr(w, http.StatusNotFound, "not_found", "no media for that message")
	case err != nil:
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
	default:
		writeJSON(w, http.StatusOK, map[string]any{"message": m})
	}
}

func (s *Server) handleMediaFile(w http.ResponseWriter, r *http.Request) {
	rowID, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request", "bad message id")
		return
	}
	path, mimeType, err := s.api.MediaFileInfo(r.Context(), rowID)
	if errors.Is(err, storage.ErrNotFound) {
		writeErr(w, http.StatusNotFound, "not_found", "media not downloaded")
		return
	}
	if err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	// The stored MIME is authoritative. ServeFile would sniff Content-Type
	// from the on-disk extension, which is .bin for any MIME outside the
	// naming table; it keeps a header that is already set.
	if mimeType != "" {
		w.Header().Set("Content-Type", mimeType)
	}
	http.ServeFile(w, r, path)
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	writeJSON(w, status, map[string]any{"error": map[string]string{"code": code, "message": msg}})
}

func decodeBody(r *http.Request, v any) error {
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return err
	}
	if len(body) == 0 {
		return nil
	}
	if err := json.Unmarshal(body, v); err != nil {
		return fmt.Errorf("invalid JSON body: %w", err)
	}
	return nil
}

// ---- WebSocket hub ----

type wsConn struct {
	conn *websocket.Conn
	out  chan hubEvent
	seq  int64
}

type hubEvent struct {
	typ     string
	payload json.RawMessage
}

// hub bridges the dispatcher to all open WS connections. Slow connections are
// closed rather than allowed to wedge the process.
type hub struct {
	disp *events.Dispatcher
	log  *slog.Logger

	mu    sync.Mutex
	conns map[*wsConn]struct{}
	done  chan struct{}
}

func newHub(d *events.Dispatcher, lg *slog.Logger) *hub {
	return &hub{disp: d, log: lg, conns: make(map[*wsConn]struct{}), done: make(chan struct{})}
}

// marshalEventData shapes payloads per docs/protocol.md: message and chat
// events wrap their object under a key; others are flat.
func marshalEventData(ev events.Event) (json.RawMessage, error) {
	switch ev.Type {
	case "message.received", "message.updated":
		return json.Marshal(map[string]any{"message": ev.Data})
	case "chat.updated":
		return json.Marshal(map[string]any{"chat": ev.Data})
	default:
		return json.Marshal(ev.Data)
	}
}

func (h *hub) run() {
	id, ch := h.disp.Subscribe(256)
	defer h.disp.Unsubscribe(id)
	for {
		select {
		case <-h.done:
			return
		case ev, ok := <-ch:
			if !ok {
				return
			}
			payload, err := marshalEventData(ev)
			if err != nil {
				h.log.Error("ipc: marshal event", "type", ev.Type, "err", err)
				continue
			}
			h.broadcast(hubEvent{typ: ev.Type, payload: payload})
		}
	}
}

func (h *hub) broadcast(ev hubEvent) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.conns {
		select {
		case c.out <- ev:
		default:
			// Slow consumer: close it; the client refetches on reconnect.
			h.log.Warn("ipc: closing slow WS connection")
			go c.conn.Close(websocket.StatusPolicyViolation, "slow consumer")
			delete(h.conns, c)
		}
	}
}

func (h *hub) add(c *wsConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.conns[c] = struct{}{}
}

func (h *hub) remove(c *wsConn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.conns, c)
}

func (h *hub) close() {
	select {
	case <-h.done:
		return
	default:
		close(h.done)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.conns {
		go c.conn.Close(websocket.StatusGoingAway, "server shutting down")
	}
	h.conns = make(map[*wsConn]struct{})
}

// handleWS upgrades, then runs read/write pumps for one connection.
func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	if !s.tokenOK(r) {
		writeErr(w, http.StatusUnauthorized, "unauthorized", "missing or invalid token")
		return
	}
	// Default origin verification (coder/websocket) rejects browser
	// cross-origin upgrades; non-browser clients send no Origin and pass.
	conn, err := websocket.Accept(w, r, nil)
	if err != nil {
		return // Accept already wrote the error response
	}
	c := &wsConn{conn: conn, out: make(chan hubEvent, 128)}
	s.hub.add(c)

	go s.wsWritePump(c)
	go s.wsReadPump(c)
}

func (s *Server) wsWritePump(c *wsConn) {
	ticker := time.NewTicker(25 * time.Second)
	defer ticker.Stop()
	for {
		var data json.RawMessage
		select {
		case ev := <-c.out:
			c.seq++
			data = mustJSON(struct {
				Type string          `json:"type"`
				Seq  int64           `json:"seq"`
				Data json.RawMessage `json:"data"`
			}{Type: ev.typ, Seq: c.seq, Data: ev.payload})
		case <-ticker.C:
			data = mustJSON(map[string]string{"type": "ping"})
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		err := c.conn.Write(ctx, websocket.MessageText, data)
		cancel()
		if err != nil {
			s.dropWS(c)
			return
		}
	}
}

func (s *Server) wsReadPump(c *wsConn) {
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		_, _, err := c.conn.Read(ctx)
		cancel()
		if err != nil {
			s.dropWS(c)
			return
		}
		// Any inbound frame counts as a heartbeat reply.
	}
}

func (s *Server) dropWS(c *wsConn) {
	s.hub.remove(c)
	go c.conn.Close(websocket.StatusNormalClosure, "bye")
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		return []byte("{}")
	}
	return b
}
