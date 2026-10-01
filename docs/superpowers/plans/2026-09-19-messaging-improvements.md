# Messaging Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship four approved features: image-preview save button, colored mentions in the composer, unread-badge fix with a DM read-receipt suppression setting, and delete-own-message (revoke for everyone).

**Architecture:** Go sidecar gains two additive behaviors on the existing authenticated mux (`POST /messages/{id}/delete`, `POST /chats/{jid}/read?send_receipt=`); the Swift app gains a shared save helper, a Settings scene, a selection-change read commit, an optimistic delete flow, and an `NSTextView`-backed composer that colors mention tokens using the same matcher the send path filters with.

**Tech Stack:** Go 1.24 + whatsmeow (pinned `v0.0.0-20260909164725-b25a56d63729`) + SQLite; SwiftUI macOS 14.5 / Swift 5.10 (xcodegen project).

**Spec:** `docs/superpowers/specs/2026-09-19-messaging-improvements-design.md`

## Global Constraints

- English only in code, comments, commits, docs. Conventional Commits (`feat(core): …`, `feat(mac): …`).
- No personal data in committed files. Fictional fixtures only: `254700000001@s.whatsapp.net` (me), `254700000002@s.whatsapp.net` (alice), `1203630000000000@g.us` (group).
- Group JIDs end `@g.us`; direct JIDs end `@s.whatsapp.net`.
- Errors: wrap with context (`fmt.Errorf("app: …: %w", err)`); match sentinels with `errors.Is`, never strings.
- Dependency direction: `storage` → `core`; `whatsapp` is the only whatsmeow importer; `app` → core/events/storage; `ipc` → app (already imports `storage` for sentinels — allowed, `server.go` imports it today).
- When `core.WAClient` changes, update BOTH fakes: `core/internal/app/app_test.go` and `core/internal/ipc/server_test.go`.
- Never log message content, tokens, or QR material.
- Migrations: none needed in this batch (`messages.revoked` already exists).
- A change is not done until `go test ./...` + `go vet` green and the app builds.
- Commands run from repo root unless stated; Go commands run from `core/`.

## File Structure

- Modify `core/internal/core/ports.go` — add `RevokeMessage` to `WAClient`.
- Modify `core/internal/whatsapp/client.go` — `RevokeMessage` adapter via `BuildRevoke`.
- Modify `core/internal/app/app.go` — `DeleteMessage`, `MarkChatRead` gains `sendReceipt`, `ErrNotOwnMessage`.
- Modify `core/internal/storage/chats.go` — `MaxUnreadIncomingTS`.
- Modify `core/internal/ipc/server.go` — delete route, `send_receipt` param.
- Modify `core/internal/app/app_test.go`, `core/internal/ipc/server_test.go` — fakes + tests.
- Modify `docs/protocol.md` — both endpoint contracts.
- Create `apps/macos/WhatsAppWork/Views/SettingsView.swift` — Settings scene body.
- Create `apps/macos/WhatsAppWork/Views/MentionTextView.swift` — `MentionTokenMatcher` + `MentionTextView` (NSViewRepresentable).
- Modify `apps/macos/WhatsAppWork/WhatsAppWorkApp.swift` — `Settings` scene.
- Modify `apps/macos/WhatsAppWork/Core/APIClient.swift` — `markRead(sendReceipt:)`, `deleteMessage`.
- Modify `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift` — `AppRuntimeClient.markRead` gains `Bool`.
- Modify `apps/macos/WhatsAppWork/Core/InteractionPolicies.swift` — `ChatOpenSource.selectionChange`, `ReadReceiptPolicy`.
- Modify `apps/macos/WhatsAppWork/Core/AppState.swift` — save helper, `commitRead` receipt flag, `selectionBrowsing`, delete flow, matcher reuse.
- Modify `apps/macos/WhatsAppWork/Views/ChatListView.swift` — selection-change commit + j/k guard.
- Modify `apps/macos/WhatsAppWork/Views/TranscriptView.swift` — preview Save button, `openExternally` refactor, delete menu item + alert, composer field swap.
- Create `apps/macos/WhatsAppWorkTests/MentionTextTests.swift`, `apps/macos/WhatsAppWorkTests/ReadReceiptPolicyTests.swift`; modify `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift`, `InteractionPoliciesTests.swift`.
- New Swift files under `WhatsAppWork/` are picked up by `project.yml` (`sources: - path: WhatsAppWork`); run `xcodegen generate` before building.

---

### Task 1: `RevokeMessage` port + adapter + fakes

**Files:**
- Modify: `core/internal/core/ports.go`
- Modify: `core/internal/whatsapp/client.go` (after `MarkRead`, ~line 546)
- Modify: `core/internal/app/app_test.go` (fakeWA)
- Modify: `core/internal/ipc/server_test.go` (fakeWA)

**Interfaces:**
- Produces: `core.WAClient.RevokeMessage(ctx context.Context, chatJID, messageID string) error` — Task 2/3 call this. Adapter method `(c *Client) RevokeMessage` on `internal/whatsapp.Client`.

- [ ] **Step 1: Add the port method**

In `core/internal/core/ports.go`, after the `MarkRead` line:

```go
	// RevokeMessage deletes the caller's own message for everyone
	// ("delete for everyone"); messageID is the WhatsApp stanza id.
	RevokeMessage(ctx context.Context, chatJID, messageID string) error
```

- [ ] **Step 2: Implement the adapter**

In `core/internal/whatsapp/client.go`, after `MarkRead`:

```go
// RevokeMessage sends a protocol-level revoke for one of our own messages
// (delete-for-everyone). Own messages revoke with an empty sender JID —
// BuildRevoke/BuildMessageKey fills FromMe and the group participant.
func (c *Client) RevokeMessage(ctx context.Context, chatJID, messageID string) error {
	chat, err := types.ParseJID(chatJID)
	if err != nil || chat.IsEmpty() {
		return fmt.Errorf("whatsapp: bad chat jid %q", chatJID)
	}
	msg := c.cli.BuildRevoke(chat, types.EmptyJID, messageID)
	if _, err := c.cli.SendMessage(ctx, chat, msg); err != nil {
		return fmt.Errorf("whatsapp: revoke: %w", err)
	}
	return nil
}
```

Before relying on it, verify against the pinned module cache (`~/go/pkg/mod/go.mau.fi/whatsmeow@v0.0.0-20260909164725-b25a56d63729/send.go` ~line 523) that `BuildRevoke(chat, sender types.JID, id types.MessageID) *waE2E.Message` exists with that signature (AGENTS.md rule: verify whatsmeow internals against the pinned version).

- [ ] **Step 3: Extend both fakes**

`core/internal/app/app_test.go` — add fields and method:

```go
// in fakeWA struct: revokes []revokeCall ; revokeErr error
type revokeCall struct {
	chat, id string
}

func (f *fakeWA) RevokeMessage(ctx context.Context, chat, id string) error {
	f.mu.Lock()
	f.revokes = append(f.revokes, revokeCall{chat, id})
	f.mu.Unlock()
	return f.revokeErr
}
```

`core/internal/ipc/server_test.go` — no-op method on its minimal fake:

```go
func (f *fakeWA) RevokeMessage(ctx context.Context, chat, id string) error { return nil }
```

- [ ] **Step 4: Verify build and existing tests**

Run (from `core/`): `go build ./... && go vet ./... && go test ./...`
Expected: PASS (fakes satisfy the interface; no behavior changed yet).

- [ ] **Step 5: Commit**

```bash
git add core/internal/core/ports.go core/internal/whatsapp/client.go core/internal/app/app_test.go core/internal/ipc/server_test.go
git commit -m "feat(core): add RevokeMessage port for delete-for-everyone"
```

---

### Task 2: `App.DeleteMessage` (TDD)

**Files:**
- Modify: `core/internal/app/app.go` (after `React`, ~line 1170)
- Test: `core/internal/app/app_test.go`

**Interfaces:**
- Consumes: `wa.RevokeMessage(ctx, chatJID, messageID)`, `store.GetMessage(ctx, rowID) (*core.Message, error)`, `store.SetRevoked(ctx, chatJID, messageID, senderJID, ts)`, `a.emitMessageUpdated(ctx, chatJID, messageID)`.
- Produces: `App.DeleteMessage(ctx context.Context, rowID int64) error`; sentinel `app.ErrNotOwnMessage`; returns `storage.ErrNotFound` (wrapped) for unknown rows — Task 3 maps these to HTTP codes.

- [ ] **Step 1: Write the failing tests**

Append to `core/internal/app/app_test.go` (reuses `newTestApp`, `subscribe`, `waitFor`, `incomingMsg` helpers; JIDs `alice`/`me` consts exist):

```go
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
```

Add `"errors"` to the test file imports if absent. Note `sent.ID` is the rowid — confirm `core.Message` exposes the rowid as `ID int64` (it does; REST shape `"id"`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/app -run 'TestDeleteMessage' -v`
Expected: FAIL — `a.DeleteMessage undefined` / `app.ErrNotOwnMessage undefined`.

- [ ] **Step 3: Implement**

In `core/internal/app/app.go` (top-of-file var block or near other sentinels — place next to existing package vars):

```go
// ErrNotOwnMessage rejects delete-for-everyone attempts on rows the
// account did not send (admin deletes are out of scope).
var ErrNotOwnMessage = errors.New("app: not an own message")
```

(Check whether `app.go` already imports `errors`; add if missing.)

After the `React` method:

```go
// DeleteMessage revokes the caller's own message ("delete for everyone"):
// send the protocol revoke, then tombstone the local row. Non-own rows are
// rejected, already-revoked rows are a no-op, and a wire failure leaves the
// row untouched so the user can retry.
func (a *App) DeleteMessage(ctx context.Context, rowID int64) error {
	m, err := a.store.GetMessage(ctx, rowID)
	if err != nil {
		return fmt.Errorf("app: delete: %w", err)
	}
	if !m.FromMe {
		return ErrNotOwnMessage
	}
	if m.Revoked {
		return nil
	}
	if err := a.wa.RevokeMessage(ctx, m.ChatJID, m.MessageID); err != nil {
		return fmt.Errorf("app: delete: %w", err)
	}
	if err := a.store.SetRevoked(ctx, m.ChatJID, m.MessageID, m.SenderJID, m.Timestamp); err != nil {
		return fmt.Errorf("app: delete: %w", err)
	}
	a.emitMessageUpdated(ctx, m.ChatJID, m.MessageID)
	return nil
}
```

The server's protocol echo for the revoke later lands in the existing `IncomingRevoke` ingest path; `SetRevoked` is guarded by `revoked = 0` in its WHERE, so counters are never decremented twice.

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/app -run 'TestDeleteMessage' -v && go test ./...`
Expected: PASS (whole package still green — no existing test touches DeleteMessage).

- [ ] **Step 5: Commit**

```bash
git add core/internal/app/app.go core/internal/app/app_test.go
git commit -m "feat(core): App.DeleteMessage revokes own messages for everyone"
```

---

### Task 3: IPC delete route + protocol docs

**Files:**
- Modify: `core/internal/ipc/server.go` (route table ~line 63, handler after `handleReact`)
- Modify: `docs/protocol.md`
- Test: `core/internal/ipc/server_test.go`

**Interfaces:**
- Consumes: `App.DeleteMessage(ctx, rowID)`, sentinels `app.ErrNotOwnMessage` / `storage.ErrNotFound` (both already importable — `server.go` imports `app` and `storage`).
- Produces: `POST /messages/{id}/delete` → `204 | 400 | 404 | 500` — Task 9's Swift client calls it.

- [ ] **Step 1: Write the failing test**

Append to `core/internal/ipc/server_test.go` (uses `newEnv` + `e.do(method, path, body, authed)`):

```go
func TestDeleteMessageRoute(t *testing.T) {
	e := newEnv(t)

	code, body := e.do("POST", "/messages", `{"chat_jid":"`+alice+`","text":"oops"}`, true)
	if code != http.StatusCreated {
		t.Fatalf("send status = %d body = %v", code, body)
	}
	id := int64(body["id"].(float64))

	if code, _ := e.do("POST", fmt.Sprintf("/messages/%d/delete", id), "", true); code != http.StatusNoContent {
		t.Fatalf("delete status = %d", code)
	}
	// Row is revoked through the public read path.
	code, body = e.do("GET", "/chats/"+alice+"/messages?limit=10", "", true)
	if code != http.StatusOK {
		t.Fatalf("list status = %d", code)
	}
	msgs := body["messages"].([]any)
	first := msgs[0].(map[string]any)
	if first["revoked"] != true {
		t.Fatalf("row not revoked: %v", first)
	}
	// Idempotent second delete still 204.
	if code, _ := e.do("POST", fmt.Sprintf("/messages/%d/delete", id), "", true); code != http.StatusNoContent {
		t.Fatalf("second delete status = %d", code)
	}
	// Unknown row → 404, garbage id → 400.
	if code, _ := e.do("POST", "/messages/999999/delete", "", true); code != http.StatusNotFound {
		t.Fatalf("missing row status = %d", code)
	}
	if code, _ := e.do("POST", "/messages/abc/delete", "", true); code != http.StatusBadRequest {
		t.Fatalf("bad id status = %d", code)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ipc -run TestDeleteMessageRoute -v`
Expected: FAIL — route returns 404 from the mux (`delete status = 404`).

- [ ] **Step 3: Implement route + handler**

Route table, after the `react` line:

```go
	mux.HandleFunc("POST /messages/{id}/delete", s.handleMsgDelete)
```

Handler, after `handleReact`:

```go
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/ipc -v && go test ./...`
Expected: PASS.

- [ ] **Step 5: Document in `docs/protocol.md`**

After the `POST /messages/{id}/react` entry (search for `react`), add:

```
POST /messages/{id}/delete
→ 204        # revokes the caller's own message for everyone (delete-for-everyone)
             # 404 unknown row · 400 not an own message
```

- [ ] **Step 6: Commit**

```bash
git add core/internal/ipc/server.go core/internal/ipc/server_test.go docs/protocol.md
git commit -m "feat(ipc): POST /messages/{id}/delete revoke endpoint"
```

---

### Task 4: `MarkChatRead` local-only branch (TDD)

**Files:**
- Modify: `core/internal/storage/chats.go` (after `UnreadIncoming`, ~line 354)
- Modify: `core/internal/app/app.go` (`MarkChatRead`, lines 1172-1205)
- Test: `core/internal/app/app_test.go`

**Interfaces:**
- Consumes: `store.UnreadIncoming`, `store.MarkChatRead` (existing).
- Produces: `App.MarkChatRead(ctx, chatJID string, sendReceipt bool) error` — Task 5 passes the query param through; `store.MaxUnreadIncomingTS(ctx, jid) (int64, error)`.

- [ ] **Step 1: Write the failing tests**

Append to `core/internal/app/app_test.go`:

```go
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

	// Traffic after the local read still bumps the badge.
	fw.push(incomingMsg("m2", alice, alice, "two"))
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
```

Update the existing receipt-path test — `TestMarkChatReadSendsReceipts` (line ~328) changes its call to `a.MarkChatRead(context.Background(), alice, true)`. Any other `a.MarkChatRead(` call sites in tests get `, true`.

- [ ] **Step 2: Run tests to verify they fail**

Run: `go test ./internal/app -run 'TestMarkChatRead' -v`
Expected: compile FAIL — `too many arguments in call to a.MarkChatRead`.

- [ ] **Step 3: Implement storage helper**

In `core/internal/storage/chats.go` after `UnreadIncoming`:

```go
// MaxUnreadIncomingTS is the newest unread incoming timestamp (0 = none).
func (s *Store) MaxUnreadIncomingTS(ctx context.Context, jid string) (int64, error) {
	var ts sql.NullInt64
	if err := s.r.QueryRowContext(ctx, `
		SELECT MAX(timestamp) FROM messages
		WHERE chat_jid = ? AND from_me = 0 AND revoked = 0
		  AND timestamp > (SELECT COALESCE(last_read_ts, 0) FROM chats WHERE jid = ?)`,
		jid, jid).Scan(&ts); err != nil {
		return 0, fmt.Errorf("storage: max unread ts: %w", err)
	}
	return ts.Int64, nil
}
```

Add `"database/sql"` to imports if absent. Verify the plan: run
`sqlite3 <tmpdb> "EXPLAIN QUERY PLAN SELECT MAX(timestamp) FROM messages WHERE chat_jid='x' AND from_me=0 AND revoked=0 AND timestamp > 0"`-style check via a throwaway Go test or the audit harness — must use the `chat_jid` index (a `SCAN messages` here is a bug per AGENTS.md; the existing `UnreadIncoming` query has the same shape and runs in the request path today, so the index exists).

- [ ] **Step 4: Implement the app branch**

Replace `MarkChatRead` (app.go lines 1172-1205) with:

```go
// MarkChatRead clears a chat's unread state. With sendReceipt it first
// delivers WhatsApp read receipts grouped by sender (on failure the local
// position is kept so the next attempt retries the same ids); without, it
// advances the local position only — privacy mode for direct chats.
func (a *App) MarkChatRead(ctx context.Context, chatJID string, sendReceipt bool) error {
	if !sendReceipt {
		maxTS, err := a.store.MaxUnreadIncomingTS(ctx, chatJID)
		if err != nil {
			return err
		}
		if maxTS == 0 {
			return nil // nothing unread; counters already consistent
		}
		if err := a.store.MarkChatRead(ctx, chatJID, maxTS); err != nil {
			return err
		}
		a.emitChatUpdated(ctx, chatJID)
		return nil
	}
	unread, err := a.store.UnreadIncoming(ctx, chatJID, 200)
	if err != nil {
		return err
	}
	var maxTS int64
	bySender := map[string][]string{}
	for _, u := range unread {
		bySender[u.SenderJID] = append(bySender[u.SenderJID], u.MessageID)
		if u.TS > maxTS {
			maxTS = u.TS
		}
	}
	markFailed := false
	for sender, ids := range bySender {
		if err := a.wa.MarkRead(ctx, chatJID, sender, ids); err != nil {
			// Keep the local unread position: advancing would drop these IDs
			// from UnreadIncoming forever and the receipt send is never
			// retried. The next mark-read attempt covers them again.
			markFailed = true
			a.log.Warn("app: mark read failed; keeping local unread", "chat", chatJID, "err", err)
		}
	}
	if markFailed {
		return nil
	}
	if err := a.store.MarkChatRead(ctx, chatJID, maxTS); err != nil {
		return err
	}
	a.emitChatUpdated(ctx, chatJID)
	return nil
}
```

Fix the one non-test caller: `core/internal/ipc/server.go:274` becomes
`s.api.MarkChatRead(r.Context(), r.PathValue("jid"), true)` temporarily (Task 5 wires the real param).

- [ ] **Step 5: Run tests to verify they pass**

Run: `go test ./... && go vet ./...`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/internal/storage/chats.go core/internal/app/app.go core/internal/app/app_test.go core/internal/ipc/server.go
git commit -m "feat(core): local-only mark-read mode without WhatsApp receipts"
```

---

### Task 5: `send_receipt` query param + docs

**Files:**
- Modify: `core/internal/ipc/server.go` (`handleChatRead`, lines 273-279)
- Modify: `docs/protocol.md` (read endpoint, line ~66)
- Test: `core/internal/ipc/server_test.go`

**Interfaces:**
- Consumes: `App.MarkChatRead(ctx, jid, sendReceipt)` from Task 4.
- Produces: `POST /chats/{jid}/read?send_receipt=true|false` (default true) — Task 7's Swift client passes the setting.

- [ ] **Step 1: Write the failing test**

Append to `core/internal/ipc/server_test.go`:

```go
func TestChatReadSendReceiptParam(t *testing.T) {
	e := newEnv(t)

	if code, _ := e.do("POST", "/chats/"+alice+"/read?send_receipt=false", "", true); code != http.StatusNoContent {
		t.Fatalf("send_receipt=false status = %d", code)
	}
	if code, _ := e.do("POST", "/chats/"+alice+"/read", "", true); code != http.StatusNoContent {
		t.Fatalf("default status = %d", code)
	}
	if code, _ := e.do("POST", "/chats/"+alice+"/read?send_receipt=nope", "", true); code != http.StatusBadRequest {
		t.Fatalf("bad value status = %d", code)
	}
}
```

(The `send_receipt=false` case asserting "no receipt on the wire" is covered at the app layer in Task 4; here we assert transport acceptance only.)

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/ipc -run TestChatReadSendReceiptParam -v`
Expected: FAIL — `?send_receipt=nope` currently ignored, returns 204 (`bad value status = 204`).

- [ ] **Step 3: Implement**

Replace `handleChatRead`:

```go
func (s *Server) handleChatRead(w http.ResponseWriter, r *http.Request) {
	sendReceipt := true
	if v := r.URL.Query().Get("send_receipt"); v != "" {
		b, err := strconv.ParseBool(v)
		if err != nil {
			writeErr(w, http.StatusBadRequest, "bad_request", "send_receipt must be a boolean")
			return
		}
		sendReceipt = b
	}
	if err := s.api.MarkChatRead(r.Context(), r.PathValue("jid"), sendReceipt); err != nil {
		writeErr(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/ipc -v && go test ./...`
Expected: PASS.

- [ ] **Step 5: Update `docs/protocol.md`** (replace the read entry at line ~66):

```
POST /chats/{jid}/read?send_receipt=true|false
→ 204        # marks chat read locally + sends the WhatsApp read receipt
             # for unread incoming ids; send_receipt=false skips the receipt
             # (privacy mode for direct chats). Default: true.
```

- [ ] **Step 6: Commit**

```bash
git add core/internal/ipc/server.go core/internal/ipc/server_test.go docs/protocol.md
git commit -m "feat(ipc): send_receipt param on /chats/{jid}/read"
```

---

### Task 6: Swift save helper + preview Save button

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift` (near `openPreview`, ~line 2302)
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift` (`ImagePreviewSheet` ~1664, `MediaBubble.openExternally` ~1299)
- Test: `apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift` (or a new `AppStateSaveNameTests.swift` in the same target)

**Interfaces:**
- Consumes: `apiClient?.mediaData(rowID:)`, existing `toast`.
- Produces: `AppState.saveMediaToDisk(_ message: Message) async`, `AppState.suggestedSaveName(filename:kind:mime:rowID:) -> String` (static, `nonisolated`), `AppState.chooseSaveDestination(...) async -> URL?` (static).

- [ ] **Step 1: Write the failing tests**

New file `apps/macos/WhatsAppWorkTests/AppStateSaveNameTests.swift`:

```swift
import XCTest
@testable import WhatsAppWork

final class AppStateSaveNameTests: XCTestCase {
    func testStoredFilenameWins() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: "report.pdf", kind: "document", mime: "application/pdf", rowID: 7),
            "report.pdf")
    }

    func testMissingFilenameDerivesKindRowIDAndMIMEExtension() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: nil, kind: "image", mime: "image/jpeg", rowID: 42),
            "Image-42.jpg")
    }

    func testPathSeparatorsAreSanitized() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: "a/b.png", kind: "image", mime: "image/png", rowID: 1),
            "a_b.png")
    }

    func testUnknownMIMEFallsBackToBin() {
        XCTAssertEqual(
            AppState.suggestedSaveName(filename: nil, kind: "document", mime: "x-widget/nothing", rowID: 3),
            "Document-3.bin")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: FAIL — `suggestedSaveName` does not exist (build error).

- [ ] **Step 3: Implement the helper in `AppState.swift`**

After `openPreview` (~line 2302). The filename policy moves verbatim from `MediaBubble.openExternally`; the panel/reveal body becomes the shared path:

```swift
    /// Save media bytes to disk: fetch from the core, save panel (defaults
    /// to ~/Downloads), write, reveal in Finder. Shared by the non-image
    /// bubble action and the image-preview Save button.
    func saveMediaToDisk(_ message: Message) async {
        guard let client = apiClient,
              let media = message.media,
              let (data, _) = try? await client.mediaData(rowID: message.id) else {
            toast = "Media fetch failed"
            return
        }
        guard let dest = await Self.chooseSaveDestination(
            filename: media.filename, kind: media.kind, mime: media.mime, rowID: message.id
        ) else { return }
        do {
            try data.write(to: dest)
            toast = "Saved \(dest.lastPathComponent)"
            NSWorkspace.shared.selectFile(dest.path, inFileViewerRootedAtPath: dest.deletingLastPathComponent().path)
        } catch {
            toast = "Save failed: \(error.localizedDescription)"
        }
    }

    /// Pure filename policy (unit-tested): the stored filename wins; the
    /// fallback is "<Kind>-<rowid>" with an extension derived from the
    /// stored MIME via UTType — never from the HTTP Content-Type, whose
    /// pathExtension is always "".
    nonisolated static func suggestedSaveName(filename: String?, kind: String, mime: String, rowID: Int64) -> String {
        let provided = filename.flatMap { $0.isEmpty ? nil : $0 }?
            .replacingOccurrences(of: "/", with: "_")
        let fallback = "\(kind.capitalized)-\(rowID)"
        let nameExt = provided.map { ($0 as NSString).pathExtension } ?? ""
        let ext = !nameExt.isEmpty
            ? nameExt
            : UTType(mimeType: mime)?.preferredFilenameExtension ?? "bin"
        let base = ((provided ?? fallback) as NSString).deletingPathExtension
        return nameExt.isEmpty ? "\(base).\(ext)" : (provided ?? fallback)
    }

    @MainActor
    static func chooseSaveDestination(filename: String?, kind: String, mime: String, rowID: Int64) async -> URL? {
        let panel: NSSavePanel = {
            let p = NSSavePanel()
            p.title = "Save Media"
            p.nameFieldStringValue = suggestedSaveName(filename: filename, kind: kind, mime: mime, rowID: rowID)
            p.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            return p
        }()
        guard let window = NSApp.keyWindow ?? NSApp.windows.first,
              await panel.beginSheetModal(for: window) == .OK else { return nil }
        return panel.url
    }
```

(`UTType` needs `import UniformTypeIdentifiers` — check AppState.swift imports.)

Then rewrite `MediaBubble.openExternally` (TranscriptView.swift ~1299) to delegate:

```swift
    private func openExternally() {
        // Non-image media: ask where to save (WhatsApp-Desktop-style save
        // dialog), write, then reveal the file in Finder.
        Task {
            if isVisualMedia {
                await state.ensureMedia(message)
                return
            }
            await state.saveMediaToDisk(message)
        }
    }
```

And add the Save button in `ImagePreviewSheet`'s footer (TranscriptView.swift ~1675-1682):

```swift
                HStack {
                    Text(preview.message.media?.filename ?? "image")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await state.saveMediaToDisk(preview.message) }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                    }
                    .help("Save image to disk")
                    Button("Close") { state.previewImage = nil }
                        .keyboardShortcut(.cancelAction)
                }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/macos && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: PASS (new tests + whole suite).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift apps/macos/WhatsAppWorkTests/AppStateSaveNameTests.swift
git commit -m "feat(mac): save button in image preview via shared save-media helper"
```

---

### Task 7: Read-receipt setting + client plumbing

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/InteractionPolicies.swift` (`ReadReceiptPolicy`)
- Modify: `apps/macos/WhatsAppWork/Core/APIClient.swift` (`markRead`, ~line 642)
- Modify: `apps/macos/WhatsAppWork/Core/RuntimePolicies.swift` (`AppRuntimeClient.markRead` ~394/452/486)
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift` (`@AppStorage` + `commitRead` ~1643)
- Create: `apps/macos/WhatsAppWork/Views/SettingsView.swift`
- Modify: `apps/macos/WhatsAppWork/WhatsAppWorkApp.swift` (Settings scene)
- Modify: `apps/macos/WhatsAppWorkTests/RuntimePoliciesTests.swift` (fake `markRead` signature, lines ~4514/4675)
- Test: `apps/macos/WhatsAppWorkTests/ReadReceiptPolicyTests.swift` (new)

**Interfaces:**
- Consumes: Task 5 endpoint `?send_receipt=`.
- Produces: `ReadReceiptPolicy.shouldSendReceipt(chatJID:suppressDMReceipts:) -> Bool`; `APIClient.markRead(chat:sendReceipt:)`; `AppRuntimeClient.markRead(chat:sendReceipt:)`; UserDefaults key `suppressDMReadReceipts` (Bool, default true).

- [ ] **Step 1: Write the failing test**

New file `apps/macos/WhatsAppWorkTests/ReadReceiptPolicyTests.swift`:

```swift
import XCTest
@testable import WhatsAppWork

final class ReadReceiptPolicyTests: XCTestCase {
    let group = "1203630000000000@g.us"
    let dm = "254700000002@s.whatsapp.net"

    func testGroupsAlwaysSendReceipts() {
        XCTAssertTrue(ReadReceiptPolicy.shouldSendReceipt(chatJID: group, suppressDMReceipts: true))
        XCTAssertTrue(ReadReceiptPolicy.shouldSendReceipt(chatJID: group, suppressDMReceipts: false))
    }

    func testDMsSuppressedOnlyWhenSettingOn() {
        XCTAssertFalse(ReadReceiptPolicy.shouldSendReceipt(chatJID: dm, suppressDMReceipts: true))
        XCTAssertTrue(ReadReceiptPolicy.shouldSendReceipt(chatJID: dm, suppressDMReceipts: false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: FAIL — `ReadReceiptPolicy` does not exist.

- [ ] **Step 3: Implement**

`InteractionPolicies.swift` (after `ChatOpenSource`):

```swift
/// DM read-receipt suppression is a privacy setting; group chats always
/// send (their receipts are invisible to senders anyway).
enum ReadReceiptPolicy {
    static func shouldSendReceipt(chatJID: String, suppressDMReceipts: Bool) -> Bool {
        chatJID.hasSuffix("@g.us") || !suppressDMReceipts
    }
}
```

`APIClient.swift`:

```swift
    func markRead(chat: String, sendReceipt: Bool = true) async throws {
        var q = [URLQueryItem]()
        if !sendReceipt { q.append(URLQueryItem(name: "send_receipt", value: "false")) }
        _ = try await request("POST", url("chats/\(chat)/read", q).absoluteString)
    }
```

`RuntimePolicies.swift` — change the operation type, init default, convenience wiring, and method:

```swift
    private let markReadOperation: @MainActor (String, Bool) async throws -> Void
    // init parameter:
        markRead: @escaping @MainActor (String, Bool) async throws -> Void = { _, _ in
            throw URLError(.unsupportedURL)
        },
    // convenience init wiring:
            markRead: { chat, sendReceipt in try await api.markRead(chat: chat, sendReceipt: sendReceipt) },
    // method:
    func markRead(chat: String, sendReceipt: Bool) async throws { try await markReadOperation(chat, sendReceipt) }
```

Update `RuntimePoliciesTests.swift` fake (lines ~4514, 4675):

```swift
    func markRead(chat: String, sendReceipt: Bool) async throws {
        calls.append("markRead:\(chat)")
        markReadChats.append(chat)
    }
    // init site:
        markRead: { chat, sendReceipt in try await endpoints.markRead(chat: chat, sendReceipt: sendReceipt) },
```

`AppState.swift` — property (near other persisted state) and `commitRead` (~line 1643):

```swift
    /// Privacy: DM read receipts are suppressed unless the user opts back
    /// in (Settings ▸ "Don't send read receipts in direct messages").
    @AppStorage("suppressDMReadReceipts") var suppressDMReadReceipts = true
```

Inside `commitRead`, before `readCommitAction.commit`:

```swift
        let sendReceipt = ReadReceiptPolicy.shouldSendReceipt(
            chatJID: chat, suppressDMReceipts: suppressDMReadReceipts)
```

and change the request closure (~line 1659):

```swift
            request: { try await client.markRead(chat: chat, sendReceipt: sendReceipt) },
```

New file `apps/macos/WhatsAppWork/Views/SettingsView.swift`:

```swift
import SwiftUI

/// Minimal Preferences (⌘,) surface. One toggle today; the receipt policy
/// is applied per request, so changes take effect without a restart.
struct SettingsView: View {
    @AppStorage("suppressDMReadReceipts") private var suppressDMReadReceipts = true

    var body: some View {
        Form {
            Toggle("Don't send read receipts in direct messages", isOn: $suppressDMReadReceipts)
        }
        .padding(16)
        .frame(width: 380)
    }
}
```

`WhatsAppWorkApp.swift` — add the scene inside `body` after `WindowGroup { … }`:

```swift
        Settings {
            SettingsView()
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: PASS (grep the log for other `markRead(` call sites — compiler flags any stragglers).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/WhatsAppWork/Core/InteractionPolicies.swift apps/macos/WhatsAppWork/Core/APIClient.swift apps/macos/WhatsAppWork/Core/RuntimePolicies.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/SettingsView.swift apps/macos/WhatsAppWork/WhatsAppWorkApp.swift apps/macos/WhatsAppWorkTests/
git commit -m "feat(mac): DM read-receipt suppression setting"
```

---

### Task 8: Unread badge clears on selection change

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/InteractionPolicies.swift` (`ChatOpenSource` ~line 16)
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift` (`selectionBrowsing` flag; `previewChat` ~line 1545)
- Modify: `apps/macos/WhatsAppWork/Views/ChatListView.swift` (onChange ~106, `moveSelection` ~159)
- Modify: `apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift` (~line 474)

**Interfaces:**
- Consumes: `commitRead(_:source:)`, `ReadCommitGate` dedup (already in-flight per chat).
- Produces: `ChatOpenSource.selectionChange` (acknowledges read); `AppState.markSelectionBrowsing()` / `consumeSelectionBrowsing() -> Bool`.

- [ ] **Step 1: Update the source enum test**

`InteractionPoliciesTests.swift` ~line 474 — extend the acknowledging list with the new case:

```swift
        XCTAssertFalse(ChatOpenSource.keyboardSelection.acknowledgesRead)
        for source in [ChatOpenSource.enter, .mouse, .transcriptFocus, .composerFocus,
                       .selectionChange, .search, .inbox, .notification, .deepLink] {
            XCTAssertTrue(source.acknowledgesRead)
        }
```

(Match the existing assertion style at that site; keep `.keyboardSelection` the only non-acknowledging case.)

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: FAIL — `.selectionChange` does not exist.

- [ ] **Step 3: Implement**

`InteractionPolicies.swift`:

```swift
enum ChatOpenSource: CaseIterable {
    case keyboardSelection, enter, mouse, transcriptFocus, composerFocus
    case selectionChange
    case search, inbox, notification, deepLink

    var acknowledgesRead: Bool { self != .keyboardSelection }
}
```

`AppState.swift` — flag (near `selectedChat` state):

```swift
    /// Marks exactly one upcoming selection-change observation as j/k-style
    /// preview browsing so the List observer skips the read commit.
    private var selectionBrowsing = false
    func markSelectionBrowsing() { selectionBrowsing = true }
    func consumeSelectionBrowsing() -> Bool {
        let browsing = selectionBrowsing
        selectionBrowsing = false
        return browsing
    }
```

In `previewChat` (~line 1545, where `selectedChat = chat` is written) call `markSelectionBrowsing()` first — this preserves preview semantics for ⌘J and every `open()`-style path (their read commit comes from `open()` itself):

```swift
        markSelectionBrowsing()
        selectedChat = chat
```

`ChatListView.swift` — selection observer (~line 106):

```swift
        .onChange(of: state.selectedChat) { _, jid in
            guard let jid else { return }
            let browsing = state.consumeSelectionBrowsing()
            Task {
                await state.loadSelectedChat(jid)
                if !browsing {
                    await state.commitRead(jid, source: .selectionChange)
                }
            }
        }
```

`moveSelection` (~line 169) sets the flag before writing selection:

```swift
        state.markSelectionBrowsing()
        state.selectedChat = state.chats[next].jid
```

Row clicks are unchanged: `openChatRow` writes `selectedChat` WITHOUT the flag (its observer commits via `.selectionChange`) and also calls `commitRead(.mouse)` directly — the in-flight dedup collapses the two into one POST.

- [ ] **Step 4: Run tests + manual verification**

Run: `cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: PASS.

Manual checklist (run the built app against a test account):
1. Click an unread chat → badge clears immediately (no composer focus needed).
2. j/k over unread chats → badge survives.
3. ⌘J → lands on next unread, badge survives.
4. Enter on selected chat → badge clears.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/WhatsAppWork/Core/InteractionPolicies.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/ChatListView.swift apps/macos/WhatsAppWorkTests/InteractionPoliciesTests.swift
git commit -m "fix(mac): clear unread badge when a chat opens via selection change"
```

---

### Task 9: Delete-message UI

**Files:**
- Modify: `apps/macos/WhatsAppWork/Core/APIClient.swift` (after `react`, ~line 649)
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift` (delete flow, near `retrySend` ~line 2011)
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift` (menu ~1176, alert near the Snooze/Reaction overlays ~299-307)

**Interfaces:**
- Consumes: Task 3 endpoint `POST /messages/{id}/delete`; existing `message.updated` WS handling (`bufferRowUpdate`).
- Produces: `APIClient.deleteMessage(rowID:)`; `AppState.deleteTarget: Message?`, `AppState.requestDeleteMessage(_:)`, `AppState.deleteMessage(_:) async`.

- [ ] **Step 1: API client**

`APIClient.swift` after `react`:

```swift
    /// Delete-for-everyone on one of our own messages (204; 400 non-own, 404 unknown).
    func deleteMessage(rowID: Int64) async throws {
        _ = try await request("POST", "messages/\(rowID)/delete")
    }
```

- [ ] **Step 2: AppState flow**

Near `retrySend`:

```swift
    /// Delete-for-everyone: confirmation target, then revoke + optimistic
    /// tombstone; the message.updated WS echo re-asserts server truth.
    @Published var deleteTarget: Message?

    func requestDeleteMessage(_ m: Message) { deleteTarget = m }

    func deleteMessage(_ m: Message) async {
        guard let client = apiClient else { return }
        do {
            try await client.deleteMessage(rowID: m.id)
            applyRevokedLocally(m)
        } catch {
            toast = "Delete failed: \(error.localizedDescription)"
        }
    }

    /// Optimistic tombstone (same pattern as optimistic sends): the bubble
    /// becomes «deleted» immediately; WS reconciliation follows.
    private func applyRevokedLocally(_ m: Message) {
        guard var list = messagesByChat[m.chat_jid],
              let idx = list.firstIndex(where: { $0.id == m.id }) else { return }
        list[idx].revoked = true
        list[idx].text = ""
        messagesByChat[m.chat_jid] = list
    }
```

(Check `Message` field mutability — the struct's stored properties are `var`; if any are `let`, change those two to `var`.)

- [ ] **Step 3: Context-menu item + confirmation**

`TranscriptView.swift` — in `MessageBubble.menu` (~line 1194, after the "Copy Message" block):

```swift
            if message.from_me && !message.revoked {
                Button("Delete…") { state.requestDeleteMessage(message) }
            }
```

On the transcript container (the same view that hosts the `SnoozePanel`/`ReactionPanel` overlays, ~line 299-307), add:

```swift
        .alert("Delete for everyone?", isPresented: Binding(
            get: { state.deleteTarget != nil },
            set: { if !$0 { state.deleteTarget = nil } })) {
            Button("Delete", role: .destructive) {
                if let m = state.deleteTarget { Task { await state.deleteMessage(m) } }
                state.deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { state.deleteTarget = nil }
        } message: {
            Text("The message will be removed for everyone in this chat.")
        }
```

- [ ] **Step 4: Build + manual verification**

Run: `cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

Manual checklist (test account, own message in a DM and a group):
1. Right-click own message → "Delete…" → confirm → bubble becomes «deleted» within a frame; official client shows it deleted.
2. Right-click someone else's message → no Delete item.
3. Sidecar stopped → Delete shows the failure toast, row intact; retry after recovery works.
4. Revoke echo does not double-apply (row stays a single tombstone; unread counters sane).

- [ ] **Step 5: Commit**

```bash
git add apps/macos/WhatsAppWork/Core/APIClient.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift
git commit -m "feat(mac): delete-own-message with confirmation and optimistic tombstone"
```

---

### Task 10: Mention-colored composer

**Files:**
- Create: `apps/macos/WhatsAppWork/Views/MentionTextView.swift`
- Modify: `apps/macos/WhatsAppWork/Views/TranscriptView.swift` (`inputField` ~819)
- Modify: `apps/macos/WhatsAppWork/Core/AppState.swift` (`containsMentionToken` ~1911 delegates to the matcher)
- Test: `apps/macos/WhatsAppWorkTests/MentionTextTests.swift` (new)

**Interfaces:**
- Consumes: `state.mentionTargets` (labels = dictionary values), `ComposerBar` submit/mention machinery.
- Produces: `MentionTokenMatcher.matchedRanges(text:labels:) -> [Range<String.Index>]` (shared by the composer colors AND `containsMentionToken`); `MentionTextView` NSViewRepresentable with `text: Binding<String>`, `resolvedLabels: [String]`, `font: NSFont`, `enterInterceptor: () -> Bool`, `onEnter: () -> Void`, `onFocusChange: (Bool) -> Void`, `focusRequest: Int`.

- [ ] **Step 1: Write the failing matcher tests**

New file `apps/macos/WhatsAppWorkTests/MentionTextTests.swift`:

```swift
import XCTest
@testable import WhatsAppWork

final class MentionTextTests: XCTestCase {
    private func tokens(_ text: String, labels: [String]) -> [String] {
        MentionTokenMatcher.matchedRanges(text: text, labels: labels).map { String(text[$0]) }
    }

    func testWholeWordBoundariesOnly() {
        // "@Ann" standalone matches; the "@Ann" inside "@Anna" and after
        // "x" do not.
        XCTAssertEqual(tokens("hi @Ann and @Anna and x@Ann", labels: ["Ann"]), ["@Ann"])
    }

    func testStartAndEndBoundaries() {
        XCTAssertEqual(tokens("@Ann", labels: ["Ann"]), ["@Ann"])
        XCTAssertEqual(tokens("see @Ann", labels: ["Ann"]), ["@Ann"])
    }

    func testMultipleLabelsAndMultipleOccurrences() {
        XCTAssertEqual(tokens("@Ann tell @Bob", labels: ["Ann", "Bob"]), ["@Ann", "@Bob"])
        XCTAssertEqual(tokens("@Ann … @Ann", labels: ["Ann"]), ["@Ann", "@Ann"])
    }

    func testUnresolvedTokensNeverMatch() {
        XCTAssertEqual(tokens("@ghost hello", labels: ["Ann"]), [])
        XCTAssertEqual(tokens("@Ann hello", labels: []), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: FAIL — `MentionTokenMatcher` does not exist.

- [ ] **Step 3: Create `Views/MentionTextView.swift`**

```swift
import AppKit
import SwiftUI

/// Pure mention-range finder: the SAME token-boundary rules the send path
/// (`AppState.containsMentionToken` → `deliver`) uses, so what the composer
/// colors is exactly what goes onto the wire as a mention.
enum MentionTokenMatcher {
    static func matchedRanges(text: String, labels: [String]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for label in labels where !label.isEmpty {
            var searchStart = text.startIndex
            while let r = text.range(of: "@\(label)", range: searchStart..<text.endIndex) {
                let afterOK = r.upperBound == text.endIndex || !isWordChar(text[r.upperBound])
                // `index(before:)` is only valid when the match is NOT at the
                // string's start — evaluating it eagerly crashed in Release.
                let beforeOK = r.lowerBound == text.startIndex
                    || !isWordChar(text[text.index(before: r.lowerBound)])
                if afterOK && beforeOK {
                    out.append(r)
                }
                searchStart = r.upperBound
            }
        }
        return out
    }

    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}

/// Composer input with colored mentions. ONE NSTextView for the composer —
/// the AGENTS.md rule bans AppKit text views per transcript ROW, and this
/// is not one. Resolved "@Label" tokens render in the accent color; any
/// other "@" text stays default-colored (unresolved, will not be sent as a
/// mention).
struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    var resolvedLabels: [String]
    var font: NSFont
    /// Runs before Enter is handled (mention popup accepts the first row);
    /// return true to consume.
    var enterInterceptor: () -> Bool
    var onEnter: () -> Void
    var onFocusChange: (Bool) -> Void
    /// Bump to focus the field (replaces @FocusState bridging).
    var focusRequest: Int

    func makeNSView(context: Context) -> ComposerTextView {
        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.drawsBackground = false
        tv.isRichText = true
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        // Auto-height 1…5 lines: grow with content, cap at 5 lines, scroll
        // beyond. SwiftUI drives the height from the fitting size.
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: .greatestFiniteMagnitude)
        tv.string = text
        tv.onFocus = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        Self.recolor(tv, labels: resolvedLabels, font: font)
        context.coordinator.textView = tv
        context.coordinator.parent = self
        return tv
    }

    func updateNSView(_ tv: NSTextView, context: Context) {
        context.coordinator.parent = self
        if !context.coordinator.isEditing, tv.string != text {
            tv.string = text
        }
        tv.font = font
        Self.recolor(tv, labels: resolvedLabels, font: font)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            if let window = tv.window {
                window.makeFirstResponder(tv)
            } else {
                tv.needsDisplay = true // not yet in a window; retry on next update
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionTextView
        var isEditing = false
        var lastFocusRequest = 0
        weak var textView: NSTextView?

        init(_ parent: MentionTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = tv.string
            isEditing = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if parent.enterInterceptor() { return true }
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.command) {
                    parent.onEnter()
                    return true
                }
                return false // plain Return inserts a newline (current behavior)
            }
            return false
        }
    }

    /// Full-sweep recolor: reset every attribute to the plain default,
    /// then accent-color resolved mention ranges. Cheap at composer size
    /// (≤5 lines); preserves selection because only attributes change.
    static func recolor(_ tv: NSTextView, labels: [String], font: NSFont) {
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let text = tv.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        tv.textStorage?.setAttributes(plain, range: full)
        for range in MentionTokenMatcher.matchedRanges(text: text, labels: labels) {
            tv.textStorage?.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                         range: NSRange(range, in: text))
        }
        tv.typingAttributes = plain
    }
}

/// NSTextView subclass that reports first-responder changes (focus in/out)
/// even when focus moves without ending the editing session.
final class ComposerTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
}
```

Focus flows only through `ComposerTextView.onFocus` (wired in `makeNSView` above) — do not also implement `textDidBeginEditing`/`textDidEndEditing` in the coordinator, or focus events fire twice.

- [ ] **Step 4: Route AppState through the matcher**

`AppState.swift` ~line 1911 — `containsMentionToken` becomes a thin wrapper (delete its hand-rolled body, keep `isWordChar` only if still referenced elsewhere; grep first):

```swift
    private func containsMentionToken(_ text: String, label: String) -> Bool {
        !MentionTokenMatcher.matchedRanges(text: text, labels: [label]).isEmpty
    }
```

- [ ] **Step 5: Swap the composer field**

`TranscriptView.swift` `inputField` (~line 819) — replace the `TextField` block with:

```swift
    private var inputField: some View {
        VStack(spacing: 4) {
            if !mentionSuggestions.isEmpty {
                mentionPopup
            }
            MentionTextView(
                text: $draft,
                resolvedLabels: Array(state.mentionTargets.values),
                font: .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                enterInterceptor: {
                    // Enter with the popup open accepts the first match.
                    if let first = mentionSuggestions.first {
                        acceptMention(first)
                        return true
                    }
                    return false
                },
                onEnter: { submitFromKeyboard() },
                onFocusChange: { fieldFocused = $0 },
                focusRequest: state.composerFocusRequest
            )
            .frame(minHeight: 29, maxHeight: 96)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 2).fill(.quaternary.opacity(0.35)))
        }
    }
```

`fieldFocused` stays `@State` (drop the `@FocusState` attribute); the existing `.onChange(of: fieldFocused)` block (~line 677) then still drives `composerFieldFocused` and the `.composerFocus` read commit, and `.onChange(of: state.composerFocusRequest)` (~line 674) can simply set `fieldFocused = true` — the representable focuses on the next update pass.

Heights: `minHeight` ≈ one line + vertical padding; `maxHeight` ≈ five lines at 12.5 pt monospaced (~15.6 pt line height) plus padding. Fine-tune visually; both constants live here.

- [ ] **Step 6: Run tests + build**

Run: `cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -20`
Expected: PASS (matcher tests; whole suite green).

- [ ] **Step 7: Manual verification checklist (built app, group chat with members)**

1. Type `@`, pick a member → token renders accent-blue immediately; a typed `@ghost` stays default-colored.
2. Edit a colored `@Ann` into `@Anna` → color drops (no longer a whole-word match) — and send then carries no mention for it.
3. Enter inserts a newline; ⌘Enter (or the paperplane) sends.
4. Popup: Enter accepts the first row, Tab accepts, Esc dismisses — while the NSTextView holds focus.
5. Field grows 1→5 lines then scrolls; draft persists across chat switches; reply banner/attachment flows unchanged.
6. ⌘V with an image on the clipboard still stages the attachment (app-level dispatcher); text paste lands in the field.
7. `d/s/e/r` transcript shortcuts and j/k list navigation are NOT captured while typing.
8. Send with a resolved mention → receiver sees the highlight (wire rewrite unchanged).

- [ ] **Step 8: Commit**

```bash
git add apps/macos/WhatsAppWork/Views/MentionTextView.swift apps/macos/WhatsAppWork/Views/TranscriptView.swift apps/macos/WhatsAppWork/Core/AppState.swift apps/macos/WhatsAppWorkTests/MentionTextTests.swift
git commit -m "feat(mac): color resolved mentions in the composer"
```

---

### Task 11: Full verification gate

**Files:** none (verification only; fixes if anything is red).

- [ ] **Step 1: Go suite**

Run:
```bash
cd core && go build ./... && go vet ./... && go test ./... && go test -race ./internal/app ./internal/whatsapp ./internal/storage ./internal/ipc
```
Expected: all PASS.

- [ ] **Step 2: Sidecar + app build**

Run:
```bash
./scripts/build-core.sh
cd apps/macos && xcodegen generate && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | tail -3
```
Expected: `BUILD SUCCEEDED` (sidecar bundled, adhoc-signed).

- [ ] **Step 3: Swift unit tests**

Run: `cd apps/macos && xcodebuild -scheme WhatsAppWork -configuration Debug -derivedDataPath build/DerivedData test 2>&1 | tail -5`
Expected: all suites PASS.

- [ ] **Step 4: Spec cross-check**

Re-read `docs/superpowers/specs/2026-09-19-messaging-improvements-design.md` against the diff: every Goal has a corresponding change; Non-goals untouched (no delete-for-me, no admin delete, no group receipt change, no zoom). Confirm `docs/protocol.md` matches the implemented routes exactly (`/messages/{id}/delete`, `?send_receipt=`).

- [ ] **Step 5: Smoke run**

Run: `./scripts/smoke.sh` (if it boots the sidecar end-to-end; otherwise launch the built app once and open the Settings window ⌘,).
Expected: no startup errors; READY line handshake unaffected.

---

## Self-Review Notes

- Spec coverage: save button (Task 6), mention colors (Task 10), unread fix + setting (Tasks 4, 5, 7, 8), delete (Tasks 1-3, 9), docs (3, 5), verification (11). All Goals covered; Non-goals respected.
- Type consistency: `RevokeMessage(ctx, chatJID, messageID string) error` used identically in port/adapter/fakes; `MarkChatRead(ctx, jid, sendReceipt bool)` in app/ipc/tests; Swift `markRead(chat:sendReceipt:)` matches across APIClient/RuntimePolicies/AppState/tests; `MentionTokenMatcher.matchedRanges(text:labels:)` shared by view + AppState. Focus wiring goes exclusively through `ComposerTextView.onFocus`.
