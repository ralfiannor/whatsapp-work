// Package whatsapp is the only package that imports whatsmeow. It owns the
// session store (session.db), converts protocol events into core events, and
// implements core.WAClient for the app layer.
package whatsapp

import (
	"context"
	"database/sql"
	_ "embed"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"google.golang.org/protobuf/proto"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/appstate"
	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	waCompanionReg "go.mau.fi/whatsmeow/proto/waCompanionReg"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	wlog "go.mau.fi/whatsmeow/util/log"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// Client wraps whatsmeow.Client behind core.WAClient.
type Client struct {
	cli        *whatsmeow.Client
	dev        *store.Device
	log        *slog.Logger
	sessDB     *sql.DB
	lidCache   map[string]string
	lidCacheAt time.Time

	// pushSeen dedups push-name emissions per sender so a full history
	// re-sync emits one contact per participant, not one per message.
	pushSeen map[string]string

	lastContactsEmit time.Time

	evCh chan core.RawEvent

	mu        sync.Mutex
	connState core.ConnState
	ownJIDs   []string
	qrCodes   []string
	qrIdx     int
	qrTimer   *time.Timer
	qrGen     uint64 // generation guard: stale timers from an older rotation die
}

// ensureOwnerOnly pins session.db to 0600: it holds the pairing
// credentials. sqlite keeps the mode of a pre-created file; -wal/-shm
// sidecars are covered by the sidecar's umask(077).
func ensureOwnerOnly(path string) error {
	if _, err := os.Stat(path); err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_RDWR, 0o600)
		if err != nil {
			return err
		}
		return f.Close()
	}
	return os.Chmod(path, 0o600)
}

// New opens (or creates) session.db and prepares the client. It does not
// connect; call Connect (existing session) or StartQRLogin (fresh device).
func New(ctx context.Context, dataDir string, lg *slog.Logger) (*Client, error) {
	if lg == nil {
		lg = slog.Default()
	}
	// whatsmeow's sqlstore.New opens the DB with the dialect as driver name —
	// "sqlite" is modernc's registration. Pragmas travel in the DSN; the
	// query string is stripped from non-file: DSNs by the driver. We keep the
	// *sql.DB handle: whatsmeow_lid_map is read in bulk for LID resolution.
	path := filepath.Join(dataDir, "session.db")
	if err := ensureOwnerOnly(path); err != nil {
		return nil, fmt.Errorf("whatsapp: secure session db: %w", err)
	}
	dsn := path +
		"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)"
	// whatsmeow internal logging stays at warn: it can be chatty, and this
	// app's policy is to never risk logging conversation content.
	waLog := warnAdapter{lg.With("lib", "whatsmeow")}
	sessDB, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("whatsapp: session db open: %w", err)
	}
	container := sqlstore.NewWithDB(sessDB, "sqlite", waLog)
	if err := container.Upgrade(ctx); err != nil {
		sessDB.Close()
		return nil, fmt.Errorf("whatsapp: session store upgrade: %w", err)
	}
	dev, err := container.GetFirstDevice(ctx)
	if err != nil {
		return nil, fmt.Errorf("whatsapp: first device: %w", err)
	}

	// Pairing identity: mimic WhatsApp Web (Chrome). whatsmeow's defaults
	// register as a web browser (BaseClientPayload Platform=WEB) but leave
	// DeviceProps.PlatformType=UNKNOWN and the QR clientType unset — phones
	// scan the code but refuse to pair with the mismatched device class.
	// Verified against a live web.whatsapp.com QR: its clientType is "1"
	// (PairClientChrome). All three signals must agree.
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CHROME.Enum()
	store.SetOSInfo("Mac OS X", [3]uint32{14, 8, 1})
	// Ask for a full history sync at each login so re-logins re-ingest the
	// past with the current normalizer (dedup makes this idempotent).
	store.DeviceProps.RequireFullSync = proto.Bool(true)

	cli := whatsmeow.NewClient(dev, waLog)
	cli.QRClientType = whatsmeow.PairClientChrome
	// whatsmeow defaults InitialAutoReconnect to false: a failed FIRST dial
	// never retried (autoReconnect only hooks established-socket
	// disconnects), stranding the core in "connecting" when the app launches
	// before the network is up.
	cli.InitialAutoReconnect = true
	// whatsmeow's downloader does an unbounded io.ReadAll of the response
	// body. A hostile peer that stamps a small fileLength but serves
	// gigabytes would OOM the sidecar before the media manager's
	// post-download check runs — cut the body at the transport instead.
	// Slack covers the 10-byte HMAC and media padding.
	cli.SetMediaHTTPClient(&http.Client{
		Transport: &limitedBodyTransport{
			rt:    http.DefaultTransport,
			limit: core.MaxMediaBytes + 4096,
		},
	})
	// Emit per-mutation events during app-state FULL syncs too. The default
	// silently applies the initial snapshot — including the phone's whole
	// contact list — so the contact names WhatsApp Web shows never reached
	// the app.
	cli.EmitAppStateEventsOnFullSync = true
	c := &Client{
		cli:    cli,
		dev:    dev,
		log:    lg,
		sessDB: sessDB,
		evCh:   make(chan core.RawEvent, 512),
	}
	c.refreshOwnJIDs()
	cli.AddEventHandler(c.onEvent)
	return c, nil
}

func (c *Client) refreshOwnJIDs() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ownJIDs = c.ownJIDs[:0]
	if c.dev.ID != nil && !c.dev.ID.IsEmpty() {
		c.ownJIDs = append(c.ownJIDs, c.dev.ID.ToNonAD().String())
	}
	if !c.dev.LID.IsEmpty() {
		c.ownJIDs = append(c.ownJIDs, c.dev.LID.ToNonAD().String())
	}
}

func (c *Client) ownJIDsCopy() []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]string, len(c.ownJIDs))
	copy(out, c.ownJIDs)
	return out
}

// LoggedIn reports whether a paired session exists.
func (c *Client) LoggedIn() bool { return c.cli.IsLoggedIn() }

// OwnJID returns the primary JID ("" before pairing).
func (c *Client) OwnJID() string {
	jids := c.ownJIDsCopy()
	if len(jids) == 0 {
		return ""
	}
	return jids[0]
}

// Events is the normalized event stream consumed by the app ingest loop.
func (c *Client) Events() <-chan core.RawEvent { return c.evCh }

// emit forwards a normalized event to the ingest loop. Blocking is preferred
// over dropping protocol events; the 5 s timeout turns a wedged ingest into a
// loud error instead of silent data loss.
func (c *Client) emit(ev core.RawEvent) {
	select {
	case c.evCh <- ev:
		return
	default:
	}
	select {
	case c.evCh <- ev:
	case <-time.After(5 * time.Second):
		c.log.Error("whatsapp: event queue full, dropping event (ingest stalled?)")
	}
}

// notePush remembers the last push name emitted for a sender and reports
// whether this one is new. Guarded by mu: the event loop is single-goroutine
// today, but the lock keeps it correct if that ever changes.
func (c *Client) notePush(jid, name string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pushSeen == nil {
		c.pushSeen = make(map[string]string)
	}
	if prev, ok := c.pushSeen[jid]; ok && prev == name {
		return false
	}
	c.pushSeen[jid] = name
	return true
}

// Connect brings up the socket. With no stored session the server sends QR
// codes (delivered as core.EventQR); pairing completes via PairSuccess.
func (c *Client) Connect(ctx context.Context) error {
	if !c.LoggedIn() {
		c.setState(core.StateLinking, "")
	} else {
		c.setState(core.StateConnecting, "")
	}
	if err := c.cli.Connect(); err != nil {
		return fmt.Errorf("whatsapp: connect: %w", err)
	}
	if c.LoggedIn() {
		// The contact-list app state is usually consumed long before this
		// process exists (version counter in the session store), so regular
		// patch syncs never re-emit it. Force one full pass per launch to
		// populate the address book names; dedup on contact upsert makes
		// the repeat harmless.
		go func() {
			syncCtx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
			defer cancel()
			if err := c.cli.FetchAppState(syncCtx, appstate.WAPatchCriticalUnblockLow, true, false); err != nil {
				c.log.Warn("whatsapp: contact app state full sync", "err", err)
			} else {
				c.log.Info("whatsapp: contact app state full sync complete")
			}
		}()
	}
	return nil
}

// StartQRLogin connects with a fresh device to obtain QR codes.
func (c *Client) StartQRLogin(ctx context.Context) error {
	if c.LoggedIn() {
		return fmt.Errorf("whatsapp: already logged in")
	}
	return c.Connect(ctx)
}

// Disconnect closes the socket (whatsmeow may auto-reconnect if enabled).
func (c *Client) Disconnect() { c.cli.Disconnect() }

// Logout removes the session server-side and deletes local session data.
func (c *Client) Logout(ctx context.Context) error {
	c.stopQRRotation()
	if err := c.cli.Logout(ctx); err != nil {
		// Local session removal must happen even if the network call failed.
		c.log.Warn("whatsapp: logout network call failed, removing session anyway", "err", err)
	}
	if err := c.dev.Delete(ctx); err != nil {
		return fmt.Errorf("whatsapp: delete session: %w", err)
	}
	c.refreshOwnJIDs()
	c.setState(core.StateLoggedOut, "logout")
	return nil
}

// deleteDeadDevice wipes the stored device row before surfacing logged-out.
// For a permanently dead device class (outdated client, temporary ban) the
// stored credentials can never log in again, and whatsmeow only takes the
// QR pre-login path when Store.ID is nil — keeping the row bricks login in
// a credential-login loop with no QR. StreamReplaced deliberately does NOT
// land here: the reconnect usually wins.
func (c *Client) deleteDeadDevice(reason string) {
	if err := c.dev.Delete(context.Background()); err != nil {
		c.log.Warn("whatsapp: delete dead device", "err", err)
	}
	c.refreshOwnJIDs()
	c.setState(core.StateLoggedOut, reason)
}

func (c *Client) setState(s core.ConnState, reason string) {
	c.mu.Lock()
	prev := c.connState
	if s == core.StateConnected {
		c.stopQRRotationLocked()
	}
	c.connState = s
	c.mu.Unlock()
	if prev != s {
		c.emit(core.EventConnState{State: s, Reason: reason})
	}
}

// State returns the current connection state (diagnostics/tests).
func (c *Client) State() core.ConnState {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.connState
}

// ---- sending ----

// buildText assembles the outgoing wire message. Plain Conversation carries
// no ContextInfo, so replies and/or mentions upgrade to ExtendedTextMessage.
func (c *Client) buildText(text string, reply *core.ReplyRef, mentioned []string) *waE2E.Message {
	if reply == nil && len(mentioned) == 0 {
		return &waE2E.Message{Conversation: &text}
	}
	ci := &waE2E.ContextInfo{MentionedJID: mentioned}
	if reply != nil && reply.ID != "" {
		participant := reply.Sender
		ci.StanzaID, ci.Participant = &reply.ID, &participant
	}
	return &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:        &text,
		ContextInfo: ci,
	}}
}

func (c *Client) SendText(ctx context.Context, chatJID, text string, reply *core.ReplyRef, mentioned []string) (core.SendAck, error) {
	to, err := types.ParseJID(chatJID)
	if err != nil || to.IsEmpty() {
		return core.SendAck{}, fmt.Errorf("whatsapp: bad chat jid %q", chatJID)
	}
	wireMentions := c.mentionJIDsForWire(to, mentioned)
	c.log.Info("whatsapp: send text", "chat", chatJID,
		"mentions_in", mentioned, "mentions_wire", wireMentions,
		"group_lid_space", to.Server == types.GroupServer && strings.Contains(to.User, "-"))
	resp, err := c.cli.SendMessage(ctx, to, c.buildText(mentionWireText(to, text, wireMentions), reply, wireMentions))
	if err != nil {
		return core.SendAck{}, fmt.Errorf("whatsapp: send: %w", err)
	}
	return core.SendAck{MessageID: resp.ID, Timestamp: resp.Timestamp.Unix()}, nil
}

// mentionWireText gates the positional token rewrite to LID-space groups.
// The composer already sends identity-digit tokens for every group; the
// word-boundary swallow below cannot know where a multi-word display label
// ends — applied outside LID space it corrupted labels on receivers
// ("@Nura Biks" became "@digits Biks", the receiver re-rendering the digits
// as the full name plus the swallowed tail).
func mentionWireText(chat types.JID, text string, wireMentions []string) string {
	if chat.Server != types.GroupServer || !strings.Contains(chat.User, "-") {
		return text
	}
	return rewriteMentionTokens(text, wireMentions)
}

// mentionJIDsForWire rewrites mentioned JIDs into the group's own identity
// space. LID-space groups (new-format JIDs, "<phone>-<id>@g.us") expect
// mention entries as @lid — sending the phone form there fails to bind on
// receiving clients: no highlight, and the phone re-renders the raw token
// plus the resolved name (text appears duplicated). Old-format groups and
// chats without a known LID twin pass through unchanged.
func (c *Client) mentionJIDsForWire(chat types.JID, mentioned []string) []string {
	if len(mentioned) == 0 || chat.Server != types.GroupServer ||
		!strings.Contains(chat.User, "-") {
		return mentioned
	}
	out := make([]string, 0, len(mentioned))
	for _, j := range mentioned {
		mapped := j
		if jid, err := types.ParseJID(j); err == nil &&
			jid.Server == types.DefaultUserServer && !jid.IsEmpty() {
			if lid, err := c.cli.Store.LIDs.GetLIDForPN(context.Background(), jid.ToNonAD()); err == nil && !lid.IsEmpty() {
				mapped = lid.ToNonAD().String()
			}
		}
		out = append(out, mapped)
	}
	return out
}

// rewriteMentionTokens replaces each "@" display-label token (in order of
// appearance) with "@" + the digits of the corresponding wire JID. In
// LID-space groups that is the token shape official clients emit — e.g.
// "@34411378638957" with MentionedJID 34411378638957@lid — and receivers
// bind the highlight from it; a display-label token with the same JID list
// does not bind there. Tokens pair with the mention list positionally: the
// composer orders its mention list by token position.
func rewriteMentionTokens(text string, wireMentions []string) string {
	if len(wireMentions) == 0 || !strings.Contains(text, "@") {
		return text
	}
	var out strings.Builder
	out.Grow(len(text))
	rest := text
	i := 0
	for rest != "" {
		at := strings.IndexByte(rest, '@')
		if at < 0 || i >= len(wireMentions) {
			out.WriteString(rest)
			break
		}
		out.WriteString(rest[:at])
		jid, err := types.ParseJID(wireMentions[i])
		if err != nil || jid.User == "" {
			out.WriteByte('@') // unknown pairing: keep the raw token
			rest = rest[at+1:]
		} else {
			out.WriteByte('@')
			out.WriteString(jid.User)
			// Swallow the display label that followed the "@": up to the
			// next whitespace boundary (replaced wholesale by the digits).
			tail := rest[at+1:]
			if sp := strings.IndexAny(tail, " \t\n"); sp >= 0 {
				rest = tail[sp:]
			} else {
				rest = ""
			}
		}
		i++
	}
	return out.String()
}

// SendMedia uploads attachment bytes and sends them as a reply-able media
// message. The returned MediaMeta holds proto + keys so the row can be
// re-downloaded later exactly like incoming media.
func (c *Client) SendMedia(ctx context.Context, chatJID string, data []byte, mime, filename, caption string, reply *core.ReplyRef) (core.SendAck, *core.MediaMeta, error) {
	to, err := types.ParseJID(chatJID)
	if err != nil || to.IsEmpty() {
		return core.SendAck{}, nil, fmt.Errorf("whatsapp: bad chat jid %q", chatJID)
	}
	mediaType, kind := mediaTypeFor(mime)
	if mediaType == "" {
		return core.SendAck{}, nil, fmt.Errorf("whatsapp: unsupported media type %q", mime)
	}
	up, err := c.cli.Upload(ctx, data, mediaType)
	if err != nil {
		return core.SendAck{}, nil, fmt.Errorf("whatsapp: upload: %w", err)
	}

	md := &core.MediaMeta{
		Kind: kind, MIME: mime, Size: int64(len(data)),
		URL: up.URL, DirectPath: up.DirectPath,
		MediaKey: up.MediaKey, FileSHA256: up.FileSHA256, FileEncSHA256: up.FileEncSHA256,
	}
	if len(up.FileEncSHA256) > 0 {
		md.ID = hex.EncodeToString(up.FileEncSHA256)
	}

	var msg *waE2E.Message
	switch kind {
	case "image":
		x := &waE2E.ImageMessage{
			URL: &up.URL, DirectPath: &up.DirectPath, Mimetype: &mime,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, MediaKey: up.MediaKey,
			FileLength: proto.Uint64(uint64(len(data))), Caption: &caption,
		}
		if reply != nil && reply.ID != "" {
			p := reply.Sender
			x.ContextInfo = &waE2E.ContextInfo{StanzaID: &reply.ID, Participant: &p}
		}
		msg = &waE2E.Message{ImageMessage: x}
		md.Proto, _ = proto.Marshal(x)
	case "video":
		x := &waE2E.VideoMessage{
			URL: &up.URL, DirectPath: &up.DirectPath, Mimetype: &mime,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, MediaKey: up.MediaKey,
			FileLength: proto.Uint64(uint64(len(data))), Caption: &caption,
		}
		if reply != nil && reply.ID != "" {
			p := reply.Sender
			x.ContextInfo = &waE2E.ContextInfo{StanzaID: &reply.ID, Participant: &p}
		}
		msg = &waE2E.Message{VideoMessage: x}
		md.Proto, _ = proto.Marshal(x)
	case "audio":
		x := &waE2E.AudioMessage{
			URL: &up.URL, DirectPath: &up.DirectPath, Mimetype: &mime,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, MediaKey: up.MediaKey,
			FileLength: proto.Uint64(uint64(len(data))),
		}
		msg = &waE2E.Message{AudioMessage: x}
		md.Proto, _ = proto.Marshal(x)
	default: // document
		if filename == "" {
			filename = "file"
		}
		x := &waE2E.DocumentMessage{
			URL: &up.URL, DirectPath: &up.DirectPath, Mimetype: &mime,
			FileEncSHA256: up.FileEncSHA256, FileSHA256: up.FileSHA256, MediaKey: up.MediaKey,
			FileLength: proto.Uint64(uint64(len(data))), FileName: &filename, Caption: &caption,
		}
		msg = &waE2E.Message{DocumentMessage: x}
		md.Proto, _ = proto.Marshal(x)
		md.Filename = filename
	}

	res, err := c.cli.SendMessage(ctx, to, msg)
	if err != nil {
		return core.SendAck{}, nil, fmt.Errorf("whatsapp: send media: %w", err)
	}
	return core.SendAck{MessageID: res.ID, Timestamp: res.Timestamp.Unix()}, md, nil
}

func mediaTypeFor(mime string) (whatsmeow.MediaType, string) {
	switch {
	case strings.HasPrefix(mime, "image/"):
		return whatsmeow.MediaImage, "image"
	case strings.HasPrefix(mime, "video/"):
		return whatsmeow.MediaVideo, "video"
	case strings.HasPrefix(mime, "audio/"):
		return whatsmeow.MediaAudio, "audio"
	default:
		return whatsmeow.MediaDocument, "document"
	}
}

func (c *Client) React(ctx context.Context, chatJID string, target core.MessageRef, emoji string) error {
	to, err := types.ParseJID(chatJID)
	if err != nil || to.IsEmpty() {
		return fmt.Errorf("whatsapp: bad chat jid %q", chatJID)
	}
	remote, fromMe := chatJID, target.FromMe
	key := &waCommon.MessageKey{RemoteJID: &remote, ID: &target.ID, FromMe: &fromMe}
	if target.SenderJID != "" && to.Server == types.GroupServer {
		p := target.SenderJID
		key.Participant = &p
	}
	msg := &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{Key: key, Text: &emoji}}
	if _, err := c.cli.SendMessage(ctx, to, msg); err != nil {
		return fmt.Errorf("whatsapp: react: %w", err)
	}
	return nil
}

func (c *Client) MarkRead(ctx context.Context, chatJID, senderJID string, messageIDs []string) error {
	chat, err := types.ParseJID(chatJID)
	if err != nil {
		return fmt.Errorf("whatsapp: bad chat jid %q", chatJID)
	}
	sender, _ := types.ParseJID(senderJID)
	if sender.IsEmpty() {
		sender = chat
	}
	if err := c.cli.MarkRead(ctx, messageIDs, time.Now(), chat, sender); err != nil {
		return fmt.Errorf("whatsapp: mark read: %w", err)
	}
	return nil
}

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

func (c *Client) GroupMembers(ctx context.Context, groupJID string) ([]core.GroupMember, error) {
	gid, err := types.ParseJID(groupJID)
	if err != nil {
		return nil, fmt.Errorf("whatsapp: bad group jid %q", groupJID)
	}
	if gid.Server != types.GroupServer {
		return nil, fmt.Errorf("whatsapp: not a group jid %q", groupJID)
	}
	info, err := c.cli.GetGroupInfo(ctx, gid)
	if err != nil {
		return nil, fmt.Errorf("whatsapp: group info: %w", err)
	}
	out := make([]core.GroupMember, 0, len(info.Participants))
	for _, p := range info.Participants {
		role := "member"
		if p.IsSuperAdmin {
			role = "superadmin"
		} else if p.IsAdmin {
			role = "admin"
		}
		// Prefer the phone JID: the app's identity space is PN everywhere
		// (contacts, message senders, LID rewrites); in LID-addressed
		// groups whatsmeow puts the LID in JID and the PN in PhoneNumber.
		jid := p.JID.ToNonAD()
		if !p.PhoneNumber.IsEmpty() {
			jid = p.PhoneNumber.ToNonAD()
		}
		lid := p.LID.ToNonAD()
		if lid.IsEmpty() && p.JID.Server == types.HiddenUserServer {
			lid = p.JID.ToNonAD()
		}
		member := core.GroupMember{JID: jid.String(), Role: role}
		if !lid.IsEmpty() {
			member.LID = lid.String()
		}
		out = append(out, member)
	}
	return out, nil
}

// GroupInfoName fetches a group's current subject.
func (c *Client) GroupInfoName(ctx context.Context, groupJID string) (string, error) {
	gid, err := types.ParseJID(groupJID)
	if err != nil {
		return "", fmt.Errorf("whatsapp: bad group jid %q", groupJID)
	}
	if gid.Server != types.GroupServer {
		return "", fmt.Errorf("whatsapp: not a group jid %q", groupJID)
	}
	info, err := c.cli.GetGroupInfo(ctx, gid)
	if err != nil {
		return "", fmt.Errorf("whatsapp: group info: %w", err)
	}
	return info.Name, nil // GroupInfo embeds GroupName; .Name promotes to string
}

// ProfilePicture fetches a user's profile-photo URL. No photo / hidden from
// linked devices returns "" (not an error) — the UI shows an initial instead.
func (c *Client) ProfilePicture(ctx context.Context, jid string) (string, error) {
	target, err := types.ParseJID(jid)
	if err != nil || target.IsEmpty() {
		return "", fmt.Errorf("whatsapp: bad jid %q", jid)
	}
	info, err := c.cli.GetProfilePictureInfo(ctx, target, &whatsmeow.GetProfilePictureParams{
		// Local member panel wants the full-size photo, not the 64px preview.
		Preview: false,
	})
	if err != nil {
		// No photo / hidden from linked devices are legitimate "" results
		// (whatsmeow sentinels; their Error() text shares nothing with the
		// old string sniff, which never matched and swallowed real errors).
		if errors.Is(err, whatsmeow.ErrProfilePictureNotSet) ||
			errors.Is(err, whatsmeow.ErrProfilePictureUnauthorized) {
			return "", nil
		}
		return "", fmt.Errorf("whatsapp: profile picture: %w", err)
	}
	if info == nil {
		return "", nil
	}
	return info.URL, nil
}

// UserNames batch-queries the usync directory (the same query WhatsApp Web
// uses for its contact sheet): verified/business display names per JID.
// Regular users' push names do NOT travel here (they ride message
// envelopes), so this exists for business senders that withhold push names.
func (c *Client) UserNames(ctx context.Context, jids []string) (map[string]string, error) {
	if len(jids) == 0 {
		return map[string]string{}, nil
	}
	parsed := make([]types.JID, 0, len(jids))
	for _, s := range jids {
		j, err := types.ParseJID(s)
		if err != nil || j.IsEmpty() || j.Server == types.GroupServer {
			continue
		}
		parsed = append(parsed, j.ToNonAD())
	}
	if len(parsed) == 0 {
		return map[string]string{}, nil
	}
	infos, err := c.cli.GetUserInfo(ctx, parsed)
	if err != nil {
		return nil, fmt.Errorf("whatsapp: usync names: %w", err)
	}
	out := make(map[string]string, len(infos))
	for jid, info := range infos {
		// VerifiedName/Details are optional pointers — dereferencing
		// unguarded panicked the core on the first usync answer set.
		if info.VerifiedName == nil || info.VerifiedName.Details == nil {
			continue
		}
		if name := info.VerifiedName.Details.GetVerifiedName(); name != "" {
			out[jid.ToNonAD().String()] = name
		}
	}
	return out, nil
}

// ResolveLIDs reads whatsmeow's lid→pn mapping table in bulk (the table
// refills organically: whatsmeow records every message's SenderAlt pair).
// Cached for 30 s — the live path consults it per message.
func (c *Client) ResolveLIDs(ctx context.Context) map[string]string {
	if ctx == nil {
		ctx = context.Background()
	}
	c.mu.Lock()
	if c.lidCache != nil && time.Since(c.lidCacheAt) < 30*time.Second {
		cached := c.lidCache
		c.mu.Unlock()
		return cached
	}
	c.mu.Unlock()

	rows, err := c.sessDB.QueryContext(ctx, `SELECT lid, pn FROM whatsmeow_lid_map`)
	if err != nil {
		c.log.Warn("whatsapp: lid map read", "err", err)
		return nil
	}
	defer rows.Close()
	out := make(map[string]string)
	for rows.Next() {
		var lid, pn string // table stores bare user parts — key by full JIDs
		if err := rows.Scan(&lid, &pn); err != nil || lid == "" || pn == "" {
			continue
		}
		out[lid+"@lid"] = pn + "@s.whatsapp.net" // server const has no "@"
	}
	if err := rows.Err(); err != nil {
		// A partial map must not be cached: identity-duality decisions
		// (canonicalSender, twinContacts) would run against incomplete data
		// for the full TTL. Skip the cache; the next call re-queries.
		c.log.Warn("whatsapp: lid map rows", "err", err)
		return nil
	}
	c.mu.Lock()
	c.lidCache, c.lidCacheAt = out, time.Now()
	c.mu.Unlock()
	return out
}

// DownloadMedia rehydrates the stored message proto and fetches + decrypts
// the media bytes (on-demand path — nothing downloads eagerly).
func (c *Client) DownloadMedia(ctx context.Context, kind string, protoBlob []byte) ([]byte, error) {
	if len(protoBlob) == 0 {
		return nil, fmt.Errorf("whatsapp: no stored proto for media")
	}
	msg, err := RehydrateMedia(kind, protoBlob)
	if err != nil {
		return nil, fmt.Errorf("whatsapp: media proto: %w", err)
	}
	data, err := c.cli.DownloadAny(ctx, msg)
	if err != nil {
		return nil, fmt.Errorf("whatsapp: download: %w", err)
	}
	return data, nil
}

// RehydrateMedia rebuilds the waE2E.Message wrapper from a stored inner
// media proto. normalize.go persists the INNER message (Marshal of
// ImageMessage etc.); unmarshaling that blob into waE2E.Message directly
// fails with wire-format errors because field numbers collide.
func RehydrateMedia(kind string, blob []byte) (*waE2E.Message, error) {
	msg := &waE2E.Message{}
	var err error
	switch kind {
	case "image":
		x := &waE2E.ImageMessage{}
		err = proto.Unmarshal(blob, x)
		msg.ImageMessage = x
	case "video":
		x := &waE2E.VideoMessage{}
		err = proto.Unmarshal(blob, x)
		msg.VideoMessage = x
	case "audio":
		x := &waE2E.AudioMessage{}
		err = proto.Unmarshal(blob, x)
		msg.AudioMessage = x
	case "document":
		x := &waE2E.DocumentMessage{}
		err = proto.Unmarshal(blob, x)
		msg.DocumentMessage = x
	case "sticker":
		x := &waE2E.StickerMessage{}
		err = proto.Unmarshal(blob, x)
		msg.StickerMessage = x
	default:
		return nil, fmt.Errorf("unknown media kind %q", kind)
	}
	if err != nil {
		return nil, err
	}
	return msg, nil
}

// ---- event handling ----

// onEvent runs on whatsmeow's dispatch goroutine; it only converts and
// forwards — persistence happens in the app ingest loop, preserving order.
func (c *Client) onEvent(raw any) {
	switch evt := raw.(type) {
	case *events.Connected:
		c.refreshOwnJIDs()
		c.setState(core.StateConnected, "")
		c.emitContacts()

	case *events.Disconnected:
		if c.LoggedIn() {
			c.setState(core.StateOffline, "socket closed")
		} else if c.State() == core.StateLinking {
			// QR codes are exhausted and the server closed the pre-login
			// socket; whatsmeow does not reconnect those. Staying in
			// "linking" strands the login screen on a dead QR forever —
			// surface logged-out so the UI offers a fresh link.
			c.setState(core.StateLoggedOut, "qr expired")
		}
	case *events.LoggedOut:
		c.refreshOwnJIDs()
		c.setState(core.StateLoggedOut, "logged out: "+evt.Reason.String())
	case *events.StreamReplaced:
		c.setState(core.StateLoggedOut, "stream replaced (session used elsewhere)")
	case *events.ClientOutdated:
		c.deleteDeadDevice("whatsmeow client outdated — update required")
	case *events.TemporaryBan:
		c.deleteDeadDevice(evt.String())
	case *events.ConnectFailure:
		if evt.Reason.IsLoggedOut() {
			c.setState(core.StateLoggedOut, evt.Reason.String())
		} else {
			c.setState(core.StateOffline, evt.Reason.String())
		}
	case *events.KeepAliveTimeout:
		c.log.Warn("whatsapp: keepalive timeout", "count", evt.ErrorCount)

	case *events.QR:
		c.startQRRotation(evt.Codes)
	case *events.PairSuccess:
		c.refreshOwnJIDs()
		c.stopQRRotation()
		// A fresh pairing means a fresh device + directory: let the next
		// Connected emit contacts even if the old account emitted recently.
		c.mu.Lock()
		c.lastContactsEmit = time.Time{}
		c.mu.Unlock()
		c.emit(core.EventPairSuccess{JID: evt.ID.String()})
	case *events.PairError:
		c.log.Error("whatsapp: pair error", "err", evt.Error)

	case *events.Message:
		source := "live"
		if evt.SourceWebMsg != nil {
			source = "history"
		}
		inc, err := Normalize(c.ownJIDsCopy(), evt, source, c.ResolveLIDs(nil))
		if err != nil {
			c.log.Error("whatsapp: normalize failed", "err", err)
			return
		}
		if inc.Kind == core.IncomingIgnore {
			return
		}
		c.emit(core.EventMessage{Incoming: inc, Source: source})
		// One contact row per (sender, name): offline catch-up replays the
		// same senders many times and a full row per message just floods
		// ingest. History-blob pushnames are handled in ConvertHistory.
		if inc.Kind == core.IncomingNew && !inc.Message.FromMe && evt.Info.PushName != "" &&
			c.notePush(inc.Message.SenderJID, evt.Info.PushName) {
			c.emit(core.EventContacts{Contacts: []core.Contact{{
				JID: inc.Message.SenderJID, PushName: evt.Info.PushName,
			}}})
		}

	case *events.Receipt:
		c.onReceipt(evt)

	case *events.PushName:
		// Emit BOTH identity forms: raw sender may be the LID while the
		// transcript renders the phone JID (canonicalization) — a name row
		// stored under only one form never resolves for the other.
		cts := []core.Contact{{JID: evt.JID.ToNonAD().String(), PushName: evt.NewPushName}}
		if alt := evt.JIDAlt.ToNonAD(); !alt.IsEmpty() && alt.String() != evt.JID.ToNonAD().String() {
			cts = append(cts, core.Contact{JID: alt.String(), PushName: evt.NewPushName})
		}
		c.emit(core.EventContacts{Contacts: cts})
	case *events.Contact:
		if a := evt.Action; a != nil {
			// Address-book records frequently carry only FirstName —
			// requiring FullName dropped nearly every contact.
			name := a.GetFullName()
			if name == "" {
				name = a.GetFirstName()
			}
			if name != "" {
				c.emit(core.EventContacts{Contacts: []core.Contact{{
					JID: evt.JID.String(), FullName: name,
				}}})
			}
		}

	case *events.GroupInfo:
		if chat := GroupInfoToChat(evt); chat != nil {
			chat.UpdatedAt = time.Now().Unix()
			c.emit(core.EventChatUpsert{Chat: *chat})
		}

	case *events.HistorySync:
		c.onHistorySync(evt)

	case *events.UndecryptableMessage:
		// whatsmeow requests a resend automatically.
		c.log.Warn("whatsapp: undecryptable message",
			"chat", evt.Info.Chat.String(), "id", evt.Info.ID)
	}
}

func (c *Client) onReceipt(evt *events.Receipt) {
	var status string
	switch evt.Type {
	case types.ReceiptTypeRead:
		status = "read"
	case types.ReceiptTypeReadSelf:
		status = "read_self"
	case types.ReceiptTypePlayed:
		status = "read" // media played == seen for our purposes
	case types.ReceiptTypeDelivered:
		status = "delivered"
	default:
		return // retry/sender bookkeeping
	}
	c.mu.Lock()
	lidMap := c.lidCache
	own := firstOwnPN(c.ownJIDs)
	c.mu.Unlock()
	// The chat key of a receipt can arrive in the @lid form too (LID-migrated
	// direct chats): outgoing rows live under the phone form, so map both.
	chatJID := evt.Chat.ToNonAD().String()
	if pn, ok := lidMap[chatJID]; ok && pn != "" {
		chatJID = pn
	}
	c.emit(core.EventReceipt{
		ChatJID:          chatJID,
		MessageSenderJID: receiptSender(evt.MessageSender, lidMap, own),
		ChatIsGroup:      evt.IsGroup,
		MessageIDs:       evt.MessageIDs,
		Status:           status,
		Timestamp:        evt.Timestamp.Unix(),
	})
}

// receiptSender normalizes the receipt's named message sender to
// the form outgoing rows are stored under (own phone JID). Receipts in
// LID-addressed chats carry the @lid twin, and grouped group receipts can
// omit the sender entirely — either would match zero rows in
// UpdateReceiptStatus and the outgoing ticks would never advance.
func receiptSender(ms types.JID, lidMap map[string]string, ownPN string) string {
	if ms.IsEmpty() {
		// Own-message receipts: the sender of record is us.
		return ownPN
	}
	s := ms.ToNonAD().String()
	if pn, ok := lidMap[s]; ok && pn != "" {
		return pn
	}
	return s
}

func firstOwnPN(ownJIDs []string) string {
	for _, j := range ownJIDs {
		if strings.HasSuffix(j, "@s.whatsapp.net") {
			return j
		}
	}
	if len(ownJIDs) > 0 {
		return ownJIDs[0]
	}
	return ""
}

func (c *Client) onHistorySync(evt *events.HistorySync) {
	data := evt.Data
	if data == nil {
		return
	}
	// One progress event per payload; "done" only at the server's final
	// payload — a per-payload "done" made clients tear down their sync UI
	// (and power assertions) after every conversation chunk.
	stage := "messages"
	if data.GetProgress() >= 100 {
		stage = "done"
	}
	c.emit(core.EventSyncProgress{Stage: stage, Progress: float64(data.GetProgress())})

	for _, ev := range ConvertHistory(c.ownJIDsCopy(), data, c.cli.ParseWebMessage, c.ResolveLIDs(nil)) {
		c.emit(ev)
	}
}

// emitContacts pushes the session store's contact directory (populated by
// history sync) so the app can index names. Throttled: Connected fires on
// every reconnect, and re-upserting the whole directory each time is pure
// write churn — push-name/contact events keep names fresh in between. The
// throttle is stamped only after a successful non-empty emit, so a failed
// read doesn't silence the next reconnect.
func (c *Client) emitContacts() {
	c.mu.Lock()
	fresh := time.Since(c.lastContactsEmit) < 10*time.Minute
	c.mu.Unlock()
	if fresh {
		return
	}
	cts, err := c.dev.Contacts.GetAllContacts(context.Background())
	if err != nil {
		c.log.Warn("whatsapp: contacts load", "err", err)
		return
	}
	if len(cts) == 0 {
		return
	}
	c.mu.Lock()
	c.lastContactsEmit = time.Now()
	c.mu.Unlock()
	out := make([]core.Contact, 0, len(cts))
	for jid, ci := range cts {
		out = append(out, core.Contact{
			JID: jid.String(), FullName: ci.FullName, PushName: ci.PushName, BusinessName: ci.BusinessName,
		})
	}
	c.emit(core.EventContacts{Contacts: out})
}

// ---- QR rotation ----

// startQRRotation emits QR codes over time: the first lives 60 s, later ones
// 20 s each (mirrors WhatsApp Web). Rotation stops on connect/pair/logout.
func (c *Client) startQRRotation(codes []string) {
	c.mu.Lock()
	if len(codes) == 0 {
		c.mu.Unlock()
		return
	}
	c.stopQRRotationLocked()
	c.qrGen++
	c.qrCodes, c.qrIdx = codes, 0
	code, wait := c.advanceQRLocked()
	c.mu.Unlock()

	c.emit(core.EventQR{Code: code, ExpiresTS: time.Now().Add(wait).Unix()})
}

// advanceQRLocked arms the timer for the next code and returns the current
// one with its lifetime. Caller holds c.mu.
func (c *Client) advanceQRLocked() (code string, wait time.Duration) {
	if c.qrIdx >= len(c.qrCodes) {
		return "", 0
	}
	code = c.qrCodes[c.qrIdx]
	wait = 20 * time.Second
	if c.qrIdx == 0 {
		wait = 60 * time.Second
	}
	gen := c.qrGen
	c.qrTimer = time.AfterFunc(wait, func() {
		c.mu.Lock()
		if c.qrTimer == nil || c.qrGen != gen {
			c.mu.Unlock()
			return // rotation stopped or restarted under us
		}
		c.qrIdx++
		next, nextWait := c.advanceQRLocked()
		c.mu.Unlock()
		if next == "" {
			return
		}
		// emit outside the lock: a full event channel must never stall
		// every other WhatsApp event under c.mu
		c.emit(core.EventQR{Code: next, ExpiresTS: time.Now().Add(nextWait).Unix()})
	})
	return code, wait
}

func (c *Client) stopQRRotation() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.stopQRRotationLocked()
}

func (c *Client) stopQRRotationLocked() {
	if c.qrTimer != nil {
		c.qrTimer.Stop()
		c.qrTimer = nil
	}
	c.qrCodes, c.qrIdx = nil, 0
}

// ---- logging adapter ----

// warnAdapter bridges whatsmeow's log.Logger onto slog at warn level:
// info/debug are dropped so the library can never flood (or leak into) logs.
type warnAdapter struct{ l *slog.Logger }

func (a warnAdapter) Errorf(msg string, args ...any) { a.l.Error(fmt.Sprintf(msg, args...)) }
func (a warnAdapter) Warnf(msg string, args ...any)  { a.l.Warn(fmt.Sprintf(msg, args...)) }
func (warnAdapter) Infof(string, ...any)             {}
func (warnAdapter) Debugf(string, ...any)            {}
func (a warnAdapter) Sub(module string) wlog.Logger  { return warnAdapter{l: a.l.With("sub", module)} }

// ---- bounded media download ----

// limitedBodyTransport wraps a RoundTripper so every media response body is
// cut at `limit` bytes while streaming — whatsmeow's downloader does an
// unbounded io.ReadAll, so the cap must bite before the bytes land in RAM.
type limitedBodyTransport struct {
	rt    http.RoundTripper
	limit int64
}

func (t *limitedBodyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.rt.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	resp.Body = &limitedBody{rc: resp.Body, remaining: t.limit}
	return resp, nil
}

type limitedBody struct {
	rc        io.ReadCloser
	remaining int64
}

func (b *limitedBody) Read(p []byte) (int, error) {
	if b.remaining <= 0 {
		return 0, fmt.Errorf("whatsapp: media download exceeds byte cap")
	}
	if int64(len(p)) > b.remaining {
		p = p[:b.remaining]
	}
	n, err := b.rc.Read(p)
	b.remaining -= int64(n)
	return n, err
}

func (b *limitedBody) Close() error { return b.rc.Close() }

var _ core.WAClient = (*Client)(nil)
