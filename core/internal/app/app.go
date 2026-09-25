// Package app orchestrates the domain: it consumes normalized events from
// the WhatsApp adapter in a single ingest goroutine (persistence before
// fan-out), and exposes the service methods the IPC layer calls.
package app

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"maps"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/events"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

// MediaService is the on-demand media port (implemented by internal/media
// over the whatsmeow downloader). Optional: without it, media endpoints 503.
type MediaService interface {
	EnsureDownloaded(ctx context.Context, messageRowID int64) (*core.MediaMeta, error)
	FileInfo(ctx context.Context, messageRowID int64) (path, mimeType string, err error)
	ClearAll(ctx context.Context) error
}

// picCacheEntry is one cached profile-picture result (url "" = known none).
type picCacheEntry struct {
	at  time.Time
	url string
}

// App wires storage, the WhatsApp port, the outbound dispatcher, and the
// optional media service.
type App struct {
	log   *slog.Logger
	store *storage.Store
	wa    core.WAClient
	disp  *events.Dispatcher
	media MediaService

	state  atomic.Value // core.ConnState
	ownJID atomic.Value // string
	mu     sync.Mutex
	qr     *core.QRInfo
	sync   *core.SyncInfo
	start  time.Time
	// syncDoneTimer ends a stuck "syncing" state when the server's final
	// progress payload never arrives (quiet-period fallback).
	syncDoneTimer *time.Timer

	nameMu         sync.Mutex
	nameResolveDue *time.Timer
	groupPending   map[string]bool
	groupWorkerOn  bool

	memberMu      sync.Mutex
	memberFetchAt map[string]time.Time // group → last successful network fetch

	// Profile-picture throttle: jid → (fetch time, URL). "" URL is a cached
	// negative (no photo / hidden) — repeated UI opens must not turn into
	// automated WhatsApp profile queries.
	picMu    sync.Mutex
	picFetch map[string]picCacheEntry

	runCtx context.Context // canceled when Run's ctx dies; used by delayed workers

	messagesIngested atomic.Uint64
	ingestErrors     atomic.Uint64

	// namesPending is set whenever new name material arrives (contacts,
	// chats, sync completion) and cleared by each resolveNames pass. The
	// 60 s ticker skips the pass when false so a steady-state core stays at
	// zero background DB work instead of re-hydrating 2000 contacts forever.
	// nameGen guards the clear: a re-arm that lands while a pass is in
	// flight must not be overwritten by that pass's success-clear.
	namesPending atomic.Bool
	namesRunning atomic.Bool
	usyncNamesDone atomic.Bool
	nameGen      atomic.Uint64
}

func New(log *slog.Logger, st *storage.Store, wa core.WAClient, disp *events.Dispatcher) *App {
	if log == nil {
		log = slog.Default()
	}
	a := &App{log: log, store: st, wa: wa, disp: disp, start: time.Now(),
		groupPending: map[string]bool{}, memberFetchAt: map[string]time.Time{},
		picFetch: map[string]picCacheEntry{}}
	a.syncDoneTimer = time.AfterFunc(time.Hour, a.syncQuietDone)
	a.syncDoneTimer.Stop()
	a.state.Store(core.StateLoggedOut)
	a.ownJID.Store("")
	a.markNamesPending() // first pass after connect resolves whatever history sync left unnamed
	if jid := wa.OwnJID(); jid != "" {
		a.ownJID.Store(jid)
	}
	return a
}

// SetMediaService attaches the media manager (post-construction because the
// manager's update callback needs the app's dispatcher).
func (a *App) SetMediaService(m MediaService) { a.media = m }

// MediaUpdateSink is the manager's callback target: turns a media state
// transition into a media.updated event for the UI.
func (a *App) MediaUpdateSink(messageRowID int64, chatJID string, md core.MediaMeta) {
	a.emit("media.updated", map[string]any{
		"message_rowid": messageRowID,
		"chat_jid":      chatJID,
		"media":         md,
	})
}

// DownloadMedia fetches bytes for a message's media on demand and returns
// the updated message. "No media row" is surfaced by the media service as
// storage.ErrNotFound — same shape as a missing message.
func (a *App) DownloadMedia(ctx context.Context, rowID int64) (*core.Message, error) {
	if a.media == nil {
		return nil, errMediaUnavailable
	}
	m, err := a.store.GetMessage(ctx, rowID)
	if err != nil {
		return nil, err
	}
	md, err := a.media.EnsureDownloaded(ctx, rowID)
	if err != nil {
		return nil, err
	}
	m.Media = md
	return m, nil
}

// MediaFileInfo resolves a downloaded item's path and stored MIME for serving.
func (a *App) MediaFileInfo(ctx context.Context, rowID int64) (string, string, error) {
	if a.media == nil {
		return "", "", errMediaUnavailable
	}
	return a.media.FileInfo(ctx, rowID)
}

var errMediaUnavailable = fmt.Errorf("media service unavailable")

// ErrNotOwnMessage rejects delete-for-everyone attempts on rows the
// account did not send (admin deletes are out of scope).
var ErrNotOwnMessage = errors.New("app: not an own message")

// Run starts the ingest loop and a slow name-resolution ticker (the LID→PN
// table refills organically from live traffic; old rows get rewritten as the
// mapping grows). Returns immediately; loops exit when ctx is cancelled.
func (a *App) Run(ctx context.Context) error {
	a.runCtx = ctx
	// Self-heal unread counters (Unread/Mentions filters read them); live
	// ingest maintains them in between.
	if err := a.store.RecomputeUnreadCounters(ctx); err != nil {
		a.log.Warn("app: unread counter recompute", "err", err)
	}
	go a.loop(ctx)
	go func() {
		t := time.NewTicker(60 * time.Second)
		defer t.Stop()
		// One pass right after the first connect regardless of pending
		// state: the address-book app state may have delivered nothing NEW
		// (its data already lives here), yet repair passes — dedupe, name
		// refresh, phone-title fallbacks — must still run once per launch.
		// Failure re-arms namesPending, so retries keep the old contract.
		first := true
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if a.namesRunning.Load() {
					continue // previous pass still grinding: don't stack
				}
				a.log.Info("names tick", "state", string(a.State()),
					"pending", a.namesPending.Load(), "first", first)
				if a.State() != core.StateConnected {
					continue
				}
				if !a.namesPending.Load() && first {
					first = false
					// Give the socket a moment to finish app-state sync.
					time.Sleep(5 * time.Second)
					a.resolveNames(ctx)
					continue
				}
				if a.namesPending.Load() {
					a.resolveNames(ctx)
				}
			}
		}
	}()
	return nil
}

// syncQuietDone is the sync-state fallback: no progress payload for 3
// minutes means the sync is over even if the final "done" chunk was lost.
func (a *App) syncQuietDone() {
	// The timer can outlive shutdown by minutes; emitting into a dispatcher
	// whose subscriber channels are closed would panic the process.
	if a.runCtx == nil || a.runCtx.Err() != nil {
		return
	}
	a.mu.Lock()
	if a.sync == nil || a.sync.Stage == "done" {
		a.mu.Unlock()
		return
	}
	done := &core.SyncInfo{Stage: "done", Progress: 100}
	a.sync = done // store done under the lock: the ingest branch dedups on it
	a.mu.Unlock()
	a.log.Info("app: sync quiet period — marking history sync done")
	a.emit("sync.progress", done)
	a.scheduleNameResolve()
}

// markNamesPending arms name resolution (ticker or debounce path).
func (a *App) markNamesPending() {
	a.nameGen.Add(1)
	a.namesPending.Store(true)
}

func (a *App) loop(ctx context.Context) {
	src := a.wa.Events()
	for {
		select {
		case <-ctx.Done():
			return
		case ev, ok := <-src:
			if !ok {
				return
			}
			a.ingest(ctx, ev)
		}
	}
}

// ingest handles one normalized event: persist first, then emit.
func (a *App) ingest(ctx context.Context, ev core.RawEvent) {
	switch e := ev.(type) {
	case core.EventMessage:
		a.ingestMessage(ctx, e)
	case core.EventReceipt:
		a.ingestReceipt(ctx, e)
	case core.EventReaction:
		a.ingestReaction(ctx, e)
	case core.EventHistoryBatch:
		a.ingestHistoryBatch(ctx, e)
	case core.EventConnState:
		a.setState(e.State, e.Reason)
	case core.EventQR:
		a.mu.Lock()
		info := &core.QRInfo{Code: e.Code, ExpiresTS: e.ExpiresTS}
		a.qr = info
		a.mu.Unlock()
		a.emit("session.qr", info)
	case core.EventSyncProgress:
		a.mu.Lock()
		if e.Stage == "done" && a.sync != nil && a.sync.Stage == "done" {
			// The quiet-period fallback already concluded the sync; don't
			// emit a duplicate done.
			a.mu.Unlock()
			a.syncDoneTimer.Stop()
			return
		}
		info := &core.SyncInfo{Stage: e.Stage, Progress: e.Progress}
		a.sync = info
		a.mu.Unlock()
		a.emit("sync.progress", info)
		if e.Stage == "done" {
			a.syncDoneTimer.Stop()
			a.scheduleNameResolve()
		} else {
			// Fallback done: the server's final payload is what normally
			// carries stage=done (progress 100); if it never arrives
			// (dropped mid-sync), a quiet period ends the sync state so
			// /session and the UI don't wedge on "syncing" forever.
			a.syncDoneTimer.Stop()
			a.syncDoneTimer.Reset(3 * time.Minute)
		}
	case core.EventContacts:
		changed, err := a.store.UpsertContacts(ctx, a.twinContacts(ctx, e.Contacts))
		if err != nil {
			a.ingestError("contacts", err)
			return
		}
		if changed > 0 {
			// A name actually changed (phone contact saved/renamed, push
			// name): clients hold a local jid→name map for transcript nicks
			// and only refresh it on a slow timer — without this push, a
			// saved contact keeps rendering as the raw phone number until
			// the next poll.
			a.emit("contacts.updated", map[string]any{"changed": changed})
		}
		a.markNamesPending()
		a.scheduleNameResolve()
	case core.EventChatUpsert:
		if err := a.store.EnsureChat(ctx, e.Chat); err != nil {
			a.ingestError("chat upsert", err)
			return
		}
		a.markNamesPending() // new chat may still carry a fallback name
		if e.Chat.LastReadTS > 0 {
			if err := a.store.MarkChatRead(ctx, e.Chat.JID, e.Chat.LastReadTS); err != nil {
				a.ingestError("chat read pos", err)
			}
		}
	case core.EventPairSuccess:
		a.ownJID.Store(e.JID)
		if err := a.store.SetOwnJID(ctx, e.JID); err != nil {
			a.ingestError("own jid", err)
		}
	}
}

func (a *App) ingestMessage(ctx context.Context, e core.EventMessage) {
	inc := e.Incoming
	switch inc.Kind {
	case core.IncomingIgnore:
		return

	case core.IncomingNew:
		a.ensureChatFor(ctx, &inc.Message)
		isNew, err := a.store.InsertMessage(ctx, &inc.Message)
		if err != nil {
			a.ingestError("insert message "+inc.Message.MessageID, err)
			return
		}
		a.messagesIngested.Add(1)
		if !isNew {
			return // duplicate delivery (history/live overlap) — already durable
		}
		// @lid traffic means the LID→PN mapping is still growing; a later
		// name pass can canonicalize senders and name chats it couldn't.
		if strings.HasSuffix(inc.Message.SenderJID, "@lid") {
			a.markNamesPending()
		}
		a.emitMessageEvent("message.received", &inc.Message)
		a.emitChatUpdated(ctx, inc.Message.ChatJID)

	case core.IncomingEdit:
		if err := a.store.SetEdited(ctx, inc.Message.ChatJID, inc.Message.SenderJID,
			inc.Message.MessageID, inc.Message.Text, inc.Message.EditedTS,
			inc.Message.HasMention, inc.Message.MentionedJIDs); err != nil {
			a.ingestError("edit "+inc.Message.MessageID, err)
			return
		}
		a.emitMessageUpdated(ctx, inc.Message.ChatJID, inc.Message.MessageID)

	case core.IncomingRevoke:
		if err := a.store.SetRevoked(ctx, inc.Revoke.ChatJID, inc.Revoke.MessageID,
			inc.Revoke.SenderJID, inc.Revoke.Timestamp); err != nil {
			a.ingestError("revoke "+inc.Revoke.MessageID, err)
			return
		}
		a.emitMessageUpdated(ctx, inc.Revoke.ChatJID, inc.Revoke.MessageID)

	case core.IncomingReaction:
		a.ingestReaction(ctx, core.EventReaction{
			ChatJID:         inc.Reaction.ChatJID,
			TargetMessageID: inc.Reaction.TargetMessageID,
			ReactorJID:      inc.Reaction.ReactorJID,
			Emoji:           inc.Reaction.Emoji,
			Timestamp:       inc.Reaction.Timestamp,
		})
	}
}

func (a *App) ingestReceipt(ctx context.Context, e core.EventReceipt) {
	if e.Status == "read_self" {
		// Incoming messages read on another own device: catch the local read
		// position up. Nothing is sent back to WhatsApp.
		maxTS, err := a.store.MaxTimestampOf(ctx, e.ChatJID, e.MessageIDs)
		if err != nil {
			a.ingestError("read_self lookup", err)
			return
		}
		if maxTS == 0 {
			return
		}
		if err := a.store.MarkChatRead(ctx, e.ChatJID, maxTS); err != nil {
			a.ingestError("read_self advance", err)
			return
		}
		a.emitChatUpdated(ctx, e.ChatJID)
		return
	}
	updates, err := a.store.UpdateReceiptStatus(ctx, e.ChatJID, e.MessageSenderJID, e.MessageIDs, e.Status)
	if err != nil {
		a.ingestError("receipt", err)
		return
	}
	for _, u := range updates {
		a.emitMessageUpdated(ctx, e.ChatJID, u.MessageID)
	}
}

// ingestHistoryBatch persists one conversation's history sync: chat metadata
// and read position first, then the message batch in chunked transactions —
// no per-message events, exactly one chat.updated at the end (R3).
func (a *App) ingestHistoryBatch(ctx context.Context, e core.EventHistoryBatch) {
	chat := e.Chat
	if chat.UpdatedAt == 0 {
		chat.UpdatedAt = time.Now().Unix()
	}
	if err := a.store.EnsureChat(ctx, chat); err != nil {
		a.ingestError("history chat "+chat.JID, err)
		return
	}
	if chat.LastReadTS > 0 {
		if err := a.store.MarkChatRead(ctx, chat.JID, chat.LastReadTS); err != nil {
			a.ingestError("history read pos "+chat.JID, err)
		}
	}

	var batch []core.Message
	for _, inc := range e.Items {
		switch inc.Kind {
		case core.IncomingNew:
			batch = append(batch, inc.Message)
		case core.IncomingEdit:
			m := inc.Message
			if err := a.store.SetEdited(ctx, m.ChatJID, m.SenderJID, m.MessageID, m.Text, m.EditedTS,
				m.HasMention, m.MentionedJIDs); err != nil {
				a.ingestError("history edit "+m.MessageID, err)
			}
		case core.IncomingRevoke:
			r := inc.Revoke
			if err := a.store.SetRevoked(ctx, r.ChatJID, r.MessageID, r.SenderJID, r.Timestamp); err != nil {
				a.ingestError("history revoke "+r.MessageID, err)
			}
		case core.IncomingReaction:
			a.ingestReaction(ctx, core.EventReaction{
				ChatJID:         inc.Reaction.ChatJID,
				TargetMessageID: inc.Reaction.TargetMessageID,
				ReactorJID:      inc.Reaction.ReactorJID,
				Emoji:           inc.Reaction.Emoji,
				Timestamp:       inc.Reaction.Timestamp,
			})
		}
	}
	if len(batch) > 0 {
		if _, err := a.store.InsertMessages(ctx, batch); err != nil {
			a.ingestError("history batch "+chat.JID, err)
			return
		}
		a.messagesIngested.Add(uint64(len(batch)))
	}
	a.emitChatUpdated(ctx, chat.JID)
}

func (a *App) ingestReaction(ctx context.Context, e core.EventReaction) {
	rowID, err := a.store.LookupMessageRow(ctx, e.ChatJID, e.TargetMessageID)
	if err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			// Reaction racing ahead of its message is normal during sync.
			a.log.Debug("app: reaction for unknown message", "chat", e.ChatJID, "id", e.TargetMessageID)
		} else {
			a.ingestError("reaction lookup", err)
		}
		return
	}
	if err := a.store.UpsertReaction(ctx, rowID, e.ReactorJID, e.Emoji, e.Timestamp); err != nil {
		a.ingestError("reaction", err)
		return
	}
	// The transcript renders reactions from the message row: without the
	// full-row message.updated echo an incoming reaction only showed up after
	// a reload (the dedicated reaction.received event is ignored by the UI).
	a.emitMessageUpdated(ctx, e.ChatJID, e.TargetMessageID)
	a.emit("reaction.received", map[string]any{
		"message_rowid": rowID,
		"chat_jid":      e.ChatJID,
		"reactor_jid":   e.ReactorJID,
		"emoji":         e.Emoji,
	})
}

// ensureChatFor creates the chat row for a message's chat if needed, with the
// best name we currently know.
func (a *App) ensureChatFor(ctx context.Context, m *core.Message) {
	kind := core.KindDirect
	if strings.HasSuffix(m.ChatJID, "@g.us") {
		kind = core.KindGroup
	}
	name := ""
	if kind == core.KindDirect {
		// The chat's name describes the PEER. On outgoing messages SenderJID
		// is our OWN jid — naming the chat from it stamped our contact name
		// onto the recipient's chat until the slow name ticker corrected it.
		peer := m.SenderJID
		if m.FromMe {
			peer = m.ChatJID // direct chat: chat_jid IS the peer
		}
		name = a.contactName(ctx, peer)
	}
	if name == "" {
		name = fallbackName(m.ChatJID, kind)
	}
	// Loud-ish on failure like every other ingest persist: a transient
	// EnsureChat error surfaces here as an FK failure on InsertMessage
	// with the root cause erased, and on the send paths it causes
	// user-visible retries (duplicate wire sends).
	if err := a.store.EnsureChat(ctx, core.Chat{JID: m.ChatJID, Kind: kind, DisplayName: name}); err != nil {
		a.ingestError("ensure chat "+m.ChatJID, err)
	}
}

// twinContacts mirrors each contact row onto its PN↔LID twin: name data
// often arrives keyed by one identity form while rendering layers hold the
// other (transcript senders are phone-canonical, LID-space push data is
// LID-keyed). Without the mirror the lookup misses and a named contact
// renders as a raw number.
func (a *App) twinContacts(ctx context.Context, cs []core.Contact) []core.Contact {
	if len(cs) == 0 {
		return cs
	}
	lidToPN := a.wa.ResolveLIDs(ctx)
	if len(lidToPN) == 0 {
		return cs
	}
	pnToLID := make(map[string]string, len(lidToPN))
	for lid, pn := range lidToPN {
		pnToLID[pn] = lid
	}
	out := cs
	for _, c := range cs {
		twin, ok := pnToLID[c.JID]
		if !ok {
			twin, ok = lidToPN[c.JID]
		}
		if !ok || twin == "" || twin == c.JID {
			continue
		}
		t := c
		t.JID = twin
		out = append(out, t)
	}
	return out
}

func (a *App) contactName(ctx context.Context, jid string) string {
	// PK seek, not a contacts-wide LIKE: this runs on the ingest goroutine
	// for every live direct message and every send.
	if c, err := a.store.GetContact(ctx, jid); err == nil {
		return firstNonEmpty(c.FullName, c.PushName, c.BusinessName)
	}
	return ""
}

func fallbackName(jid string, kind core.ChatKind) string {
	return core.FallbackChatName(jid, kind)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func (a *App) setState(s core.ConnState, reason string) {
	prev, _ := a.state.Load().(core.ConnState)
	a.state.Store(s)
	if s == core.StateConnected {
		a.scheduleNameResolve()
	}
	if s == core.StateLoggedOut {
		// The stored QR is dead by definition here (socket closed, codes
		// exhausted, or the device was unlinked) — /session must not keep
		// serving it or the login screen renders a scannable-looking code
		// that can never pair.
		a.mu.Lock()
		a.qr = nil
		a.mu.Unlock()
	}
	if s == core.StateConnected {
		a.mu.Lock()
		a.qr = nil
		a.mu.Unlock()
		if jid := a.wa.OwnJID(); jid != "" {
			a.ownJID.Store(jid)
		}
	}
	if prev != s {
		a.emit("connection.changed", map[string]any{"state": string(s), "reason": reason})
	}
}

func (a *App) emit(typ string, data any) { a.disp.Emit(events.Event{Type: typ, Data: data}) }

func (a *App) emitMessageEvent(typ string, m *core.Message) {
	cp := *m
	a.emit(typ, cp)
}

func (a *App) emitMessageUpdated(ctx context.Context, chatJID, messageID string) {
	rowID, err := a.store.LookupMessageRow(ctx, chatJID, messageID)
	if err != nil {
		a.log.Warn("app: skip message.updated emit", "chat", chatJID, "id", messageID, "err", err)
		return
	}
	m, err := a.store.GetMessage(ctx, rowID)
	if err != nil {
		a.log.Warn("app: skip message.updated emit", "chat", chatJID, "id", messageID, "err", err)
		return
	}
	a.emit("message.updated", *m)
}

func (a *App) emitChatUpdated(ctx context.Context, chatJID string) {
	c, err := a.store.GetChat(ctx, chatJID)
	if err != nil {
		a.log.Warn("app: skip chat.updated emit", "chat", chatJID, "err", err)
		return
	}
	if c.Kind == core.KindDirect {
		a.fillDirectLIDs(ctx, []core.Chat{*c})
	}
	a.emit("chat.updated", *c)
}

func (a *App) ingestError(what string, err error) {
	a.ingestErrors.Add(1)
	a.log.Error("app: ingest failure", "what", what, "err", err)
}

// scheduleNameResolve debounces name resolution: history sync fires many
// contact batches; one pass a couple of seconds after the last is enough.
func (a *App) scheduleNameResolve() {
	a.markNamesPending()
	a.nameMu.Lock()
	defer a.nameMu.Unlock()
	if a.nameResolveDue != nil {
		a.nameResolveDue.Stop()
	}
	ctx := a.runCtx // run context: canceled on shutdown so the timer dies with the app
	a.nameResolveDue = time.AfterFunc(2*time.Second, func() {
		a.resolveNames(ctx)
	})
}

// resolveNames backfills chat display names: contacts by PN JID, translated
// through whatsmeow's LID map where the chat is LID-keyed, and group subjects
// fetched on demand (throttled — one network call per unnamed group).
// namesPending stays set when the pass fails, so the 60 s ticker retries;
// live @lid traffic re-arms it too as the LID→PN mapping grows. The success
// clear is generation-guarded so a re-arm landing mid-pass isn't lost.
func (a *App) resolveNames(ctx context.Context) {
	if !a.namesRunning.CompareAndSwap(false, true) {
		return // single-flight: a pass is already grinding
	}
	defer a.namesRunning.Store(false)
	start := time.Now()
	startGen := a.nameGen.Load()
	log := a.log.With("op", "resolveNames")
	defer func() {
		log.Info("names pass done", "elapsed_ms", time.Since(start).Milliseconds())
	}()
	contacts, err := a.store.ListContacts(ctx, "", 2000)
	if err != nil {
		a.ingestError("resolve contacts", err)
		return
	}
	nameByJID := make(map[string]string, len(contacts))
	for _, c := range contacts {
		nameByJID[c.JID] = firstNonEmpty(c.FullName, c.PushName, c.BusinessName)
	}
	lidToPN := a.wa.ResolveLIDs(ctx)
	// whatsmeow only knows mappings it saw live; accounts without SenderAlt
	// (business senders) stay unmapped there. Our own rows carry the same
	// evidence — same message stored under both sender forms — so fold that
	// in (fresh whatsmeow entries win on conflict). Derive into a CLONE:
	// ResolveLIDs returns the client's shared cached map on a hit, and
	// receipt canonicalization reads it concurrently under the client lock.
	derived := maps.Clone(lidToPN)
	if derived == nil {
		derived = map[string]string{}
	}
	tDerive := time.Now()
	if err := a.store.DeriveSenderMappings(ctx, derived); err != nil {
		a.ingestError("derive sender mappings", err)
	}
	log.Info("names stage", "stage", "derive", "ms", time.Since(tDerive).Milliseconds(), "mappings", len(derived))
	// The enriched clone (whatsmeow cache + row-derived evidence) is the
	// pass's working map from here on.
	lidToPN = derived

	// Backfill: contact rows landed under one identity form only (historic
	// ingest had no twin mirroring) — copy names onto the twin jid so both
	// forms resolve. Idempotent; never overwrites a field the twin already
	// has.
	if mirrored, err := a.store.MirrorLIDContactNames(ctx, lidToPN); err != nil {
		a.ingestError("mirror lid contact names", err)
	} else if mirrored > 0 {
		log.Info("names stage", "stage", "mirror contacts", "rows", mirrored)
		a.emit("contacts.updated", map[string]any{"changed": mirrored})
	}

	// Address-book names first: rewrite every direct chat whose stored name
	// (often a push name) now differs from the contact's full name, and tell
	// the UI about each change. The needsName loop below only handles chats
	// still carrying fallback identifiers.
	tRefresh := time.Now()
	changed, err := a.store.RefreshDirectChatNames(ctx)
	if err != nil {
		a.ingestError("refresh direct chat names", err)
	} else {
		for _, jid := range changed {
			a.emitChatUpdated(ctx, jid)
		}
	}
	log.Info("names stage", "stage", "refresh", "ms", time.Since(tRefresh).Milliseconds(), "changed", len(changed))

	// Masked-title chats with no contact entry and no derivable mapping:
	// fall back to the canonical phone sender seen inside the chat.
	log.Info("names pass progress", "contacts", len(contacts), "lid_mappings", len(lidToPN))
	tFallback := time.Now()
	if fallbacks, err := a.store.DirectChatPhoneFallbacks(ctx); err != nil {
		a.ingestError("chat phone fallbacks", err)
	} else {
		log.Info("names stage", "stage", "fallbacks", "ms", time.Since(tFallback).Milliseconds(), "chats", len(fallbacks))
		for chatJID, pn := range fallbacks {
			if err := a.store.RenameChat(ctx, chatJID, fallbackName(pn, core.KindDirect)); err != nil {
				a.ingestError("fallback rename "+chatJID, err)
			} else {
				a.emitChatUpdated(ctx, chatJID)
			}
		}
	}

	chats, err := a.store.ListChatsForNames(ctx)
	if err != nil {
		a.ingestError("resolve chats", err)
		return
	}
	for _, c := range chats {
		if !needsName(c.DisplayName) {
			continue
		}
		if c.Kind == core.KindGroup {
			a.enqueueGroup(ctx, c.JID)
			continue
		}
		name := nameByJID[c.JID]
		if name == "" {
			if pn, ok := lidToPN[c.JID]; ok {
				name = nameByJID[pn]
			}
		}
		if name == "" {
			// No contact entry at all (common for business accounts). A
			// canonical phone form beats a masked "@•••" identifier — but
			// needsName rejects identifier forms by design, so rename
			// directly instead of flowing through the gate below. Chats
			// already carrying a real (push) name are left alone.
			if !needsName(c.DisplayName) {
				continue
			}
			pn, ok := lidToPN[c.JID]
			if !ok || pn == "" {
				if strings.HasSuffix(c.JID, "@lid") {
					continue // unmapped LID: nothing better than the mask
				}
				pn = c.JID
			}
			if err := a.store.RenameChat(ctx, c.JID, fallbackName(pn, core.KindDirect)); err != nil {
				a.ingestError("rename "+c.JID, err)
			} else {
				a.emitChatUpdated(ctx, c.JID)
			}
			continue
		}
		if err := a.store.RenameChat(ctx, c.JID, name); err != nil {
			a.ingestError("rename "+c.JID, err)
			continue
		}
		a.emitChatUpdated(ctx, c.JID)
	}
	// Business-name pass (once per launch): chats still carrying masked or
	// phone-form titles have no push name anywhere — the usync directory is
	// the last source (verified business names). Batched + throttled: this
	// is a network call, not a DB read.
	if !a.usyncNamesDone.Load() {
		a.usyncNamesDone.Store(true)
		a.usyncNamePass(ctx, log, lidToPN)
	}

	// Canonicalize LID senders already stored while the mapping was empty.
	if n, err := a.store.RewriteSenderJIDs(ctx, lidToPN); err != nil {
		a.ingestError("rewrite senders", err)
		return // pass incomplete: keep namesPending armed for the next tick
	} else if n > 0 {
		a.log.Info("app: rewrote LID senders", "rows", n)
	}

	// Fold LID-keyed direct chats into their phone twin: the server migrates
	// 1:1 chats to LID addressing, and rows stored before the mapping was
	// learned split one contact into two threads (Normalize canonicalizes
	// new writes; this heals what already landed).
	if merged, err := a.store.MergeLIDChats(ctx, lidToPN); err != nil {
		a.ingestError("merge lid chats", err)
	} else if len(merged) > 0 {
		a.log.Info("app: merged LID chats into phone threads", "chats", len(merged))
		for lid, pn := range merged {
			// The LID row is gone server-side (SQLite is truth) — clients
			// holding a stale copy must drop it, or every fold shows two
			// threads for one contact.
			a.emit("chat.removed", map[string]any{"jid": lid})
			a.emitChatUpdated(ctx, pn)
		}
	}
	a.kickGroupWorker(ctx)
	if a.nameGen.Load() == startGen {
		a.namesPending.Store(false) // success, nothing re-armed mid-pass
	}
}

// usyncNamePass titles direct chats whose name never resolved (business
// senders withhold push names) via the usync verified-name directory.
func (a *App) usyncNamePass(ctx context.Context, log *slog.Logger, lidToPN map[string]string) {
	if a.State() != core.StateConnected {
		return
	}
	chats, err := a.store.ListChatsForNames(ctx)
	if err != nil {
		a.ingestError("usync names: list chats", err)
		return
	}
	chatByPN := map[string]string{} // pn jid -> chat jid
	var order []string
	for _, c := range chats {
		if c.Kind != core.KindDirect || !needsName(c.DisplayName) {
			continue
		}
		pn := lidToPN[c.JID]
		if pn == "" && !strings.HasSuffix(c.JID, "@lid") {
			pn = c.JID
		}
		if pn == "" {
			continue
		}
		if _, dup := chatByPN[pn]; !dup {
			order = append(order, pn)
		}
		chatByPN[pn] = c.JID
	}
	if len(order) == 0 {
		return
	}
	const batch = 50
	for i := 0; i < len(order); i += batch {
		end := min(i+batch, len(order))
		names, err := a.wa.UserNames(ctx, order[i:end])
		if err != nil {
			a.ingestError("usync names", err)
			return // network trouble: stop, retry next launch
		}
		for pn, name := range names {
			chatJID := chatByPN[pn]
			if chatJID == "" {
				continue
			}
			if err := a.store.RenameChat(ctx, chatJID, name); err != nil {
				a.ingestError("usync rename "+chatJID, err)
				continue
			}
			// Persist as the contact's business name so transcript nicks
			// and mention labels resolve without waiting for a chat event.
			if _, err := a.store.UpsertContacts(ctx, []core.Contact{
				{JID: pn, BusinessName: name, UpdatedAt: time.Now().Unix()},
			}); err != nil {
				a.ingestError("usync contact persist "+pn, err)
			}
			a.emitChatUpdated(ctx, chatJID)
		}
		if end < len(order) {
			time.Sleep(500 * time.Millisecond) // stay polite to the server
		}
	}
	log.Info("names stage", "stage", "usync", "queried", len(order))
}

// needsName reports whether a display name is still a fallback, not a real one.
func needsName(name string) bool {
	return name == "" ||
		strings.HasPrefix(name, "+") ||
		strings.HasPrefix(name, "Group ") ||
		strings.Contains(name, "@")
}

func (a *App) enqueueGroup(ctx context.Context, jid string) {
	a.nameMu.Lock()
	defer a.nameMu.Unlock()
	a.groupPending[jid] = true
}

func (a *App) kickGroupWorker(ctx context.Context) {
	a.nameMu.Lock()
	if a.groupWorkerOn || len(a.groupPending) == 0 {
		a.nameMu.Unlock()
		return
	}
	a.groupWorkerOn = true
	a.nameMu.Unlock()
	go a.groupWorker(ctx)
}

// groupWorker renames unnamed groups, throttled to be gentle on the API.
func (a *App) groupWorker(ctx context.Context) {
	defer func() {
		a.nameMu.Lock()
		a.groupWorkerOn = false
		a.nameMu.Unlock()
	}()
	for {
		a.nameMu.Lock()
		var jid string
		for k := range a.groupPending {
			jid = k
			break
		}
		if jid != "" {
			delete(a.groupPending, jid)
		}
		a.nameMu.Unlock()
		if jid == "" {
			return
		}
		name, err := a.wa.GroupInfoName(ctx, jid)
		if err != nil {
			a.log.Warn("app: group name fetch failed", "chat", jid, "err", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}
		if name != "" {
			if err := a.store.RenameChat(ctx, jid, name); err != nil {
				a.log.Warn("app: group rename write failed", "chat", jid, "err", err)
			} else {
				a.emitChatUpdated(ctx, jid)
			}
		}
		time.Sleep(400 * time.Millisecond) // 2.5 groups/s ceiling
	}
}

// ---- services (called by IPC) ----

// State returns the current connection state.
func (a *App) State() core.ConnState {
	s, _ := a.state.Load().(core.ConnState)
	return s
}

// OwnJID returns the account jid of this linked device ("" until known).
func (a *App) OwnJID() string {
	jid, _ := a.ownJID.Load().(string)
	return jid
}

// Session returns the GET /session payload.
func (a *App) Session(ctx context.Context) core.SessionInfo {
	a.mu.Lock()
	defer a.mu.Unlock()
	acc, _ := a.ownJID.Load().(string)
	info := core.SessionInfo{State: a.State(), Account: acc}
	if info.State == core.StateLoggedOut {
		info.Account = ""
	}
	info.QR = a.qr
	info.Sync = a.sync
	return info
}

// StartLink begins QR linked-device login.
func (a *App) StartLink(ctx context.Context) error {
	if a.wa.LoggedIn() {
		return fmt.Errorf("already logged in")
	}
	return a.wa.StartQRLogin(ctx)
}

// Logout removes the WhatsApp session and wipes local conversation data.
func (a *App) Logout(ctx context.Context) error {
	if err := a.wa.Logout(ctx); err != nil {
		return err
	}
	a.ownJID.Store("")
	if a.media != nil {
		if err := a.media.ClearAll(ctx); err != nil {
			a.log.Warn("app: media cache wipe after logout", "err", err)
		}
	}
	if err := a.store.Wipe(ctx); err != nil {
		return fmt.Errorf("app: wipe after logout: %w", err)
	}
	a.setState(core.StateLoggedOut, "logout")
	return nil
}

// SendMedia sends an image/video/audio/document with an optional caption,
// persists the outgoing row with re-download material, and emits events.
func (a *App) SendMedia(ctx context.Context, chatJID string, data []byte, mime, filename, caption string, reply *core.ReplyRef) (*core.Message, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("empty media")
	}
	if len(data) > 20<<20 {
		return nil, fmt.Errorf("media too large (max 20 MB)")
	}
	ack, md, err := a.wa.SendMedia(ctx, chatJID, data, mime, filename, caption, reply)
	if err != nil {
		return nil, err
	}
	m := &core.Message{
		MessageID:     ack.MessageID,
		ChatJID:       chatJID,
		SenderJID:     firstNonEmpty(a.ownJID.Load().(string), "me"),
		FromMe:        true,
		Timestamp:     ack.Timestamp,
		Kind:          core.KindText, // replaced below from md.Kind
		Text:          caption,
		ReceiptStatus: "sent",
		Source:        "live",
		MentionedJIDs: []string{},
		Media:         md,
	}
	switch md.Kind {
	case "image":
		m.Kind = core.KindImage
	case "video":
		m.Kind = core.KindVideo
	case "audio":
		m.Kind = core.KindAudio
	case "document":
		m.Kind = core.KindDocument
	default:
		m.Kind = core.KindText
	}
	if reply != nil {
		m.ReplyToID = reply.ID
		m.ReplyToSender = reply.Sender
	}
	a.ensureChatFor(ctx, m)
	if _, err := a.store.InsertMessage(ctx, m); err != nil {
		return nil, err
	}
	a.messagesIngested.Add(1)
	a.emitMessageEvent("message.received", m)
	a.emitChatUpdated(ctx, chatJID)
	return m, nil
}

// Chats pages the chat list. cursorJID is the keyset tiebreaker for chats
// sharing one timestamp (empty = first page / legacy bare-ts cursor).
func (a *App) Chats(ctx context.Context, limit int, cursor int64, cursorJID string, filter string) ([]core.Chat, error) {
	chats, err := a.store.ListChats(ctx, limit, cursor, cursorJID, storage.ChatFilter(filter))
	if err == nil {
		a.fillDirectLIDs(ctx, chats)
	}
	return chats, err
}

// fillDirectLIDs stamps each direct chat with the peer's @lid twin from the
// lid map (reverse of ResolveLIDs). The DM header shows both identity forms;
// the data rides the chat row so no extra round trip is needed.
func (a *App) fillDirectLIDs(ctx context.Context, chats []core.Chat) {
	lidToPN := a.wa.ResolveLIDs(ctx)
	if len(lidToPN) == 0 {
		return
	}
	rev := make(map[string]string, len(lidToPN))
	for lid, pn := range lidToPN {
		rev[pn] = lid
	}
	for i := range chats {
		if chats[i].Kind == core.KindDirect && chats[i].LID == "" {
			chats[i].LID = rev[chats[i].JID]
		}
	}
}

// ChatMessages pages one chat's history by keyset cursor.
func (a *App) ChatMessages(ctx context.Context, chatJID string, beforeTS, beforeID int64, limit int) ([]core.Message, error) {
	return a.store.ListMessages(ctx, chatJID, beforeTS, beforeID, limit)
}

// SendText sends a text (optionally a reply with mentions), persists the
// outgoing row as "sent", and returns it.
func (a *App) SendText(ctx context.Context, chatJID, text string, reply *core.ReplyRef, mentioned []string) (*core.Message, error) {
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("empty message")
	}
	mentioned = sanitizeMentions(mentioned)
	ack, err := a.wa.SendText(ctx, chatJID, text, reply, mentioned)
	if err != nil {
		return nil, err
	}
	m := &core.Message{
		MessageID:     ack.MessageID,
		ChatJID:       chatJID,
		SenderJID:     firstNonEmpty(a.ownJID.Load().(string), "me"),
		FromMe:        true,
		Timestamp:     ack.Timestamp,
		Kind:          core.KindText,
		Text:          text,
		ReceiptStatus: "sent",
		Source:        "live",
		MentionedJIDs: mentioned,
	}
	if m.MentionedJIDs == nil {
		m.MentionedJIDs = []string{}
	}
	if reply != nil {
		m.ReplyToID = reply.ID
		m.ReplyToSender = reply.Sender
		// Quote preview for the sender's own transcript: the wire carries
		// only the reference — without this lookup the outgoing row had an
		// empty quoted_text and the reply looked "not working" locally.
		if q, qErr := a.store.QuotedTextOf(ctx, chatJID, reply.ID); qErr == nil && q != "" {
			m.QuotedText = q
		} else if qErr != nil {
			a.log.Warn("app: quoted text lookup", "chat", chatJID, "err", qErr)
		}
	}
	a.ensureChatFor(ctx, m)
	if _, err := a.store.InsertMessage(ctx, m); err != nil {
		return nil, err
	}
	a.messagesIngested.Add(1)
	a.emitMessageEvent("message.received", m)
	a.emitChatUpdated(ctx, chatJID)
	return m, nil
}

// React adds or removes (emoji == "") a reaction on a local message row.
func (a *App) React(ctx context.Context, rowID int64, emoji string) error {
	m, err := a.store.GetMessage(ctx, rowID)
	if err != nil {
		return err
	}
	own, _ := a.ownJID.Load().(string)
	if err := a.wa.React(ctx, m.ChatJID, core.MessageRef{
		ID: m.MessageID, SenderJID: m.SenderJID, FromMe: m.FromMe,
	}, emoji); err != nil {
		return err
	}
	if err := a.store.UpsertReaction(ctx, rowID, own, emoji, time.Now().Unix()); err != nil {
		return err
	}
	if emoji == "" {
		// Removal must also clear the @lid twin of our JID: reactions we
		// sent from a LID-addressed context (or an older build ingested)
		// are stored under that form, and deleting only the phone row
		// leaves the chip toggling forever.
		for lid, pn := range a.wa.ResolveLIDs(ctx) {
			if pn == own {
				if err := a.store.UpsertReaction(ctx, rowID, lid, "", time.Now().Unix()); err != nil {
					return err
				}
			}
		}
	}
	a.emitMessageUpdated(ctx, m.ChatJID, m.MessageID)
	a.emit("reaction.received", map[string]any{
		"message_rowid": rowID, "chat_jid": m.ChatJID, "reactor_jid": own, "emoji": emoji,
	})
	return nil
}

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
	// SetRevoked may clear chats.last_preview (deleted row was the newest):
	// the sidebar needs the refreshed chat row, not just the tombstoned message.
	a.emitChatUpdated(ctx, m.ChatJID)
	return nil
}

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

// Profile assembles a user's profile for the member panel: local contact
// names plus a live profile-picture URL (empty when none/hidden). role is
// the membership role within groupJID when given.
func (a *App) Profile(ctx context.Context, jid, groupJID string) (*core.UserProfile, error) {
	p := &core.UserProfile{JID: jid}
	// Canonicalize identity forms: show the phone JID when we know it and
	// the @lid form when we know that, whatever the caller passed in.
	if strings.HasSuffix(jid, "@lid") {
		p.LID = jid
		if lidToPN := a.wa.ResolveLIDs(ctx); lidToPN != nil {
			if pn, ok := lidToPN[jid]; ok {
				p.JID = pn
			}
		}
	} else if lidToPN := a.wa.ResolveLIDs(ctx); lidToPN != nil {
		for lid, pn := range lidToPN {
			if pn == jid {
				p.LID = lid
				break
			}
		}
	}
	if c, err := a.store.GetContact(ctx, p.JID); err == nil {
		p.FullName, p.PushName, p.BusinessName = c.FullName, c.PushName, c.BusinessName
	} else if !errors.Is(err, storage.ErrNotFound) {
		a.log.Warn("app: profile contact read", "jid", jid, "err", err)
	}
	if groupJID != "" {
		// Cache-first (same path as the member panel) so a cold cache
		// still resolves the role instead of silently returning "".
		if members, err := a.GroupMembers(ctx, groupJID); err == nil {
			for _, m := range members {
				if m.JID == jid || m.JID == p.JID {
					p.Role = m.Role
					break
				}
			}
		} else {
			a.log.Warn("app: profile role lookup", "group", groupJID, "err", err)
		}
	}
	if a.State() == core.StateConnected {
		a.picMu.Lock()
		cached, hit := a.picFetch[jid]
		a.picMu.Unlock()
		if hit && time.Since(cached.at) < 5*time.Minute {
			p.PictureURL = cached.url
			return p, nil
		}
		if url, err := a.wa.ProfilePicture(ctx, jid); err != nil {
			// No-photo/hidden-photo is "" from the adapter, not an error;
			// anything reaching here is a real fetch failure.
			a.log.Warn("app: profile picture unavailable", "jid", jid, "err", err)
		} else {
			p.PictureURL = url
			a.picMu.Lock()
			a.picFetch[jid] = picCacheEntry{at: time.Now(), url: url}
			a.picMu.Unlock()
		}
	}
	return p, nil
}

// sanitizeMentions bounds the mention list from the IPC body before it hits
// the wire, the row, and every later page read: max 128 entries (real group
// mentions), each ≤64 bytes and JID-shaped ("…@server"). Invalid entries
// drop silently — the UI builds this list itself, so anything malformed is
// a bug or a oversized payload, never a legit mention.
func sanitizeMentions(jids []string) []string {
	out := make([]string, 0, len(jids))
	for _, j := range jids {
		if len(j) == 0 || len(j) > 64 || !strings.Contains(j, "@") {
			continue
		}
		out = append(out, j)
		if len(out) >= 128 {
			break
		}
	}
	return out
}

// ContactIdentity resolves a jid to its PN↔LID pair via the learned lid
// map (no network). Either field is empty when the twin is unknown.
func (a *App) ContactIdentity(_ context.Context, jid string) core.ContactIdentity {
	out := core.ContactIdentity{JID: jid}
	lidToPN := a.wa.ResolveLIDs(context.Background())
	if strings.HasSuffix(jid, "@lid") {
		if pn, ok := lidToPN[jid]; ok && pn != "" {
			out.JID = pn
			out.LID = jid
		}
		return out
	}
	for lid, pn := range lidToPN {
		if pn == jid {
			out.LID = lid
			break
		}
	}
	return out
}

// Search runs local FTS + chat/contact search.
func (a *App) Search(ctx context.Context, q string, limit int) (core.SearchResult, error) {
	res := core.SearchResult{}
	msgs, err := a.store.SearchMessages(ctx, q, limit)
	if err != nil {
		return res, err
	}
	res.Messages = msgs
	contacts, err := a.store.ListContacts(ctx, q, limit)
	if err != nil {
		a.log.Warn("app: search contacts degraded", "err", err)
	} else {
		res.Contacts = contacts
	}
	// Chat-name matching scans the whole chats table (LIKE over display
	// name; ListChats clamps limits, so this is a dedicated store method).
	chatsLimit := limit
	if chatsLimit < 1 {
		chatsLimit = 25
	}
	chats, err := a.store.SearchChatsByName(ctx, q, chatsLimit)
	if err != nil {
		a.log.Warn("app: search chats degraded", "err", err)
	} else {
		res.Chats = chats
	}
	return res, nil
}

// Contacts lists/searches contacts.
func (a *App) Contacts(ctx context.Context, q string, limit int) ([]core.Contact, error) {
	return a.store.ListContacts(ctx, q, limit)
}

// GroupMembers returns a group's participants. Cache-first: the persisted
// group_participants rows answer instantly (UI nick panel + mention
// autocomplete); the network is consulted at most once per group per 10
// minutes, and a stale cache still beats a failed fetch.
func (a *App) GroupMembers(ctx context.Context, groupJID string) ([]core.GroupMember, error) {
	const refreshEvery = 10 * time.Minute
	a.memberMu.Lock()
	fresh := time.Since(a.memberFetchAt[groupJID]) < refreshEvery
	a.memberMu.Unlock()

	if fresh {
		if cached, err := a.store.GetGroupMembers(ctx, groupJID); err == nil && len(cached) > 0 {
			return cached, nil
		}
	}

	members, err := a.wa.GroupMembers(ctx, groupJID)
	if err != nil {
		if cached, cerr := a.store.GetGroupMembers(ctx, groupJID); cerr == nil && len(cached) > 0 {
			a.log.Warn("app: group members fetch failed, serving stale cache",
				"group", groupJID, "err", err)
			return cached, nil
		}
		return nil, err
	}
	if err := a.store.SetGroupMembers(ctx, groupJID, members); err != nil {
		// Cache write failed: don't stamp freshness — old rows would be
		// served as current for the whole 10-minute window.
		a.log.Warn("app: cache group members", "err", err)
		return members, nil
	}
	a.memberMu.Lock()
	a.memberFetchAt[groupJID] = time.Now()
	a.memberMu.Unlock()
	return members, nil
}

// ---- work inbox (v0.2) ----

// emitInboxChanged tells the client the work inbox's membership changed
// (done/snooze/star mutation, chat work/star flag). The UI refetches /inbox
// when its inbox tab is visible; the event is a hint, never a payload.
func (a *App) emitInboxChanged(reason string) {
	a.emit("inbox.changed", map[string]any{"reason": reason})
}

// Inbox assembles the actionable work inbox.
func (a *App) Inbox(ctx context.Context, limit int) (*core.Inbox, error) {
	return a.store.Inbox(ctx, time.Now().Unix(), limit)
}

// SetMessageDone marks a message done (or re-opens it) locally.
func (a *App) SetMessageDone(ctx context.Context, rowID int64, done bool) error {
	if err := a.store.SetMessageDone(ctx, rowID, done); err != nil {
		return err
	}
	if m, err := a.store.GetMessage(ctx, rowID); err == nil {
		a.emit("message.updated", *m)
	}
	a.emitInboxChanged("done")
	return nil
}

// SetMessageSnoozed hides a message until untilTS (0 clears).
func (a *App) SetMessageSnoozed(ctx context.Context, rowID int64, untilTS int64) error {
	if err := a.store.SetMessageSnoozed(ctx, rowID, untilTS); err != nil {
		return err
	}
	a.emitInboxChanged("snooze")
	return nil
}

// SetMessageStarred stars a message locally.
func (a *App) SetMessageStarred(ctx context.Context, rowID int64, starred bool) error {
	if err := a.store.SetMessageStarred(ctx, rowID, starred); err != nil {
		return err
	}
	if m, err := a.store.GetMessage(ctx, rowID); err == nil {
		a.emit("message.updated", *m)
	}
	a.emitInboxChanged("star")
	return nil
}

// SetChatStarred toggles a starred work contact.
func (a *App) SetChatStarred(ctx context.Context, jid string, starred bool) error {
	if err := a.store.SetChatStarred(ctx, jid, starred); err != nil {
		return err
	}
	a.emitChatUpdated(ctx, jid)
	a.emitInboxChanged("chat_star")
	return nil
}

// SetChatWork classifies a group as a work group.
func (a *App) SetChatWork(ctx context.Context, jid string, work bool) error {
	if err := a.store.SetChatWork(ctx, jid, work); err != nil {
		return err
	}
	a.emitChatUpdated(ctx, jid)
	a.emitInboxChanged("chat_work")
	return nil
}

// SetChatDone completes (or reopens) every pending inbox item of one
// conversation — the bulk action behind a conversation row's Done button.
func (a *App) SetChatDone(ctx context.Context, jid string, done bool) error {
	if err := a.store.SetChatDone(ctx, jid, done); err != nil {
		return err
	}
	a.emitInboxChanged("chat_done")
	return nil
}

// SetChatSnooze defers a whole conversation until untilTS (0 = clear); the
// deadline holds messages that arrive after it was set.
func (a *App) SetChatSnooze(ctx context.Context, jid string, untilTS int64) error {
	if err := a.store.SetChatSnooze(ctx, jid, untilTS); err != nil {
		return err
	}
	a.emitInboxChanged("chat_snooze")
	return nil
}

// Stats returns health counters.
func (a *App) Stats() (ingested, errors, dropped uint64) {
	return a.messagesIngested.Load(), a.ingestErrors.Load(), a.disp.Dropped()
}

// Uptime returns seconds since App construction.
func (a *App) Uptime() int64 { return int64(time.Since(a.start).Seconds()) }
