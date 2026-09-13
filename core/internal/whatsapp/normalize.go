package whatsapp

import (
	"encoding/hex"
	"fmt"

	"google.golang.org/protobuf/proto"

	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// Normalize converts one whatsmeow Message event into a domain Incoming.
// myJIDs holds the account's own JIDs (primary + LID twin) and drives mention
// detection. source is "live" or "history". Unknown content types degrade to
// kind=unsupported, never error — ingest must survive anything the protocol
// sends (docs/architecture.md R11).
func Normalize(myJIDs []string, evt *events.Message, source string, lidToPN map[string]string) (core.Incoming, error) {
	ignore := core.Incoming{Kind: core.IncomingIgnore}
	if evt == nil || evt.Message == nil || evt.Info.ID == "" {
		return ignore, nil
	}
	sender := canonicalSender(evt, lidToPN)
	chat := canonicalChat(evt, sender, lidToPN)
	myJIDs = withOwnLIDs(myJIDs, lidToPN)

	switch chat.Server {
	case types.DefaultUserServer, types.HiddenUserServer, types.GroupServer:
		// ok
	default:
		return ignore, nil // newsletter, broadcast/status, call, … (non-goals)
	}
	// A JID with an empty user part passes whatsmeow's IsEmpty (it only
	// checks the server) — ingesting it creates junk chat/sender rows keyed
	// by the bare server string.
	if chat.User == "" || sender.User == "" {
		return ignore, nil
	}

	// Sender-stamped envelope timestamps are remote input: a far-future
	// stamp poisons last_read_ts permanently (every honest message after it
	// is born read and the recompute cannot heal it) and pins the chat to
	// the top of the list; a zero stamp lands at unix-epoch-minus-one in
	// Unix() and breaks keyset cursors. Clamp to a sane window.
	ts := evt.Info.Timestamp.Unix()
	if ts < minSaneTS {
		ts = minSaneTS
	} else if ts > maxSaneTS {
		ts = maxSaneTS
	}

	m := core.Message{
		MessageID: truncateRunes(evt.Info.ID, 128),
		ChatJID:   chat.String(),
		SenderJID: sender.ToNonAD().String(),
		FromMe:    evt.Info.IsFromMe,
		Timestamp: ts,
		Source:    source,
	}
	msg := evt.Message

	// Control-plane messages first.
	if pm := msg.GetProtocolMessage(); pm != nil {
		target := pm.GetKey()
		switch pm.GetType() {
		case waE2E.ProtocolMessage_REVOKE:
			// The revoke names the original sender by Key.Participant, which
			// in LID-addressed groups carries the @lid form — the stored row
			// is canonical (phone form), so map it or the revoke matches 0
			// rows and silently no-ops. AD-suffixed forms
			// ("user:9@lid") must be stripped before the map lookup.
			part := participantOr(target, m.SenderJID)
			if p, err := types.ParseJID(part); err == nil && !p.IsEmpty() {
				part = p.ToNonAD().String()
			}
			if pn, ok := lidToPN[part]; ok && pn != "" {
				part = pn
			}
			return core.Incoming{
				Kind: core.IncomingRevoke,
				Revoke: core.RevokeRef{
					ChatJID:   m.ChatJID,
					MessageID: target.GetID(),
					SenderJID: part,
					Timestamp: m.Timestamp,
				},
			}, nil
		case waE2E.ProtocolMessage_MESSAGE_EDIT:
			edited := pm.GetEditedMessage()
			if edited == nil {
				return ignore, nil
			}
			em := m
			em.MessageID = target.GetID() // edits target the original stanza id
			em.Kind = core.KindText
			em.Text = textOf(edited)
			// An edit replaces the payload — its forwarding marker wins,
			// but never drop a flag the outer stanza carried.
			em.Forwarded = isForwarded(edited) || em.Forwarded
			em.EditedTS = m.Timestamp
			fillReply(edited.GetExtendedTextMessage().GetContextInfo(), &em, myJIDs)
			return core.Incoming{Kind: core.IncomingEdit, Message: em}, nil
		default:
			return ignore, nil // app-state sync noise, ephemeral settings, …
		}
	}

	if rm := msg.GetReactionMessage(); rm != nil {
		return core.Incoming{
			Kind: core.IncomingReaction,
			Reaction: core.ReactionRef{
				ChatJID:         m.ChatJID,
				TargetMessageID: rm.GetKey().GetID(),
				ReactorJID:      m.SenderJID,
				Emoji:           rm.GetText(),
				Timestamp:       m.Timestamp,
			},
		}, nil
	}

	// Sender-key distribution envelopes precede the real message; storing
	// them creates noise rows ("not synced") that never gain content.
	if msg.GetSenderKeyDistributionMessage() != nil ||
		msg.GetFastRatchetKeySenderKeyDistributionMessage() != nil {
		return ignore, nil
	}

	// System/stub messages (group joins/leaves/subject changes; mostly history).
	if evt.SourceWebMsg != nil &&
		evt.SourceWebMsg.GetMessageStubType() != waWeb.WebMessageInfo_UNKNOWN {
		m.Kind = core.KindSystem
		m.Text = stubText(evt)
		return core.Incoming{Kind: core.IncomingNew, Message: m}, nil
	}

	// Forwarded marker: any payload context carrying a nonzero forwarding
	// score (WhatsApp's own re-share indicator). Checked before the kind
	// switch so text, media and rich types all get it.
	m.Forwarded = isForwarded(msg)

	if txt := msg.GetConversation(); txt != "" {
		m.Kind, m.Text = core.KindText, truncateRunes(txt, maxTextRunes)
		return core.Incoming{Kind: core.IncomingNew, Message: m}, nil
	}
	if etm := msg.GetExtendedTextMessage(); etm != nil {
		m.Kind, m.Text = core.KindText, truncateRunes(etm.GetText(), maxTextRunes)
		fillReply(etm.GetContextInfo(), &m, myJIDs)
		return core.Incoming{Kind: core.IncomingNew, Message: m}, nil
	}

	var (
		md *core.MediaMeta
		pm proto.Message
		ci *waE2E.ContextInfo
	)
	switch {
	case msg.GetImageMessage() != nil:
		x := msg.GetImageMessage()
		m.Kind, m.Text = core.KindImage, x.GetCaption()
		md = mediaMeta("image", x.GetURL(), x.GetDirectPath(), x.GetMimetype(),
			int64(x.GetFileLength()), x.GetFileSHA256(), x.GetFileEncSHA256(), x.GetMediaKey(),
			int(x.GetWidth()), int(x.GetHeight()), 0, "")
		pm, ci = x, x.GetContextInfo()
	case msg.GetVideoMessage() != nil:
		x := msg.GetVideoMessage()
		m.Kind, m.Text = core.KindVideo, x.GetCaption()
		md = mediaMeta("video", x.GetURL(), x.GetDirectPath(), x.GetMimetype(),
			int64(x.GetFileLength()), x.GetFileSHA256(), x.GetFileEncSHA256(), x.GetMediaKey(),
			int(x.GetWidth()), int(x.GetHeight()), int64(x.GetSeconds())*1000, "")
		pm, ci = x, x.GetContextInfo()
	case msg.GetAudioMessage() != nil:
		x := msg.GetAudioMessage()
		m.Kind, m.Text = core.KindAudio, ""
		md = mediaMeta("audio", x.GetURL(), x.GetDirectPath(), x.GetMimetype(),
			int64(x.GetFileLength()), x.GetFileSHA256(), x.GetFileEncSHA256(), x.GetMediaKey(),
			0, 0, int64(x.GetSeconds())*1000, "")
		pm, ci = x, x.GetContextInfo()
	case msg.GetDocumentMessage() != nil:
		x := msg.GetDocumentMessage()
		name := x.GetFileName()
		if name == "" {
			name = x.GetTitle()
		}
		m.Kind, m.Text = core.KindDocument, x.GetCaption()
		md = mediaMeta("document", x.GetURL(), x.GetDirectPath(), x.GetMimetype(),
			int64(x.GetFileLength()), x.GetFileSHA256(), x.GetFileEncSHA256(), x.GetMediaKey(),
			0, 0, 0, name)
		pm, ci = x, x.GetContextInfo()
	case msg.GetStickerMessage() != nil:
		x := msg.GetStickerMessage()
		m.Kind, m.Text = core.KindSticker, ""
		md = mediaMeta("sticker", x.GetURL(), x.GetDirectPath(), x.GetMimetype(),
			int64(x.GetFileLength()), x.GetFileSHA256(), x.GetFileEncSHA256(), x.GetMediaKey(),
			int(x.GetWidth()), int(x.GetHeight()), 0, "")
		pm, ci = x, x.GetContextInfo()
	default:
		// Rich interactive types (bot menus, templates, events) carry real
		// text in their own fields — extract before declaring unsupported.
		if txt := extractRichText(msg); txt != "" {
			m.Kind = core.KindText
			m.Text = txt
			fillReply(richContext(msg), &m, myJIDs)
			return core.Incoming{Kind: core.IncomingNew, Message: m}, nil
		}
		m.Kind = core.KindUnsupported
		m.RawKind = rawKindOf(msg)
		return core.Incoming{Kind: core.IncomingNew, Message: m}, nil
	}

	if len(md.FileEncSHA256) > 0 {
		// The hex ID becomes the cache filename — bound it (a hostile
		// multi-MB field would exceed NAME_MAX at rename time).
		if len(md.FileEncSHA256) > 64 {
			md.FileEncSHA256 = md.FileEncSHA256[:64]
		}
		md.ID = hex.EncodeToString(md.FileEncSHA256)
	}
	// A hostile proto can lie about fileLength: zero/negative (int64 wrap)
	// would slip past the manager's positive-size pre-check.
	if md.Size <= 0 {
		md.Size = 0
	}
	md.Filename = truncateRunes(md.Filename, 255)
	if blob, err := proto.Marshal(pm); err == nil {
		md.Proto = blob // re-download material for later on-demand fetch (R4)
	}
	m.Media = md
	fillReply(ci, &m, myJIDs)
	return core.Incoming{Kind: core.IncomingNew, Message: m}, nil
}

// withOwnLIDs adds the LID twin of each own phone JID known to the lid→pn
// map. whatsmeow persists Device.LID at pair/connect, so the stored list
// normally covers both forms — but a session whose stored LID is empty (lost
// or predating LID addressing) still learns the own mapping live in the lid
// table. Without this fold, a mention of us in a LID-addressed group
// references a JID that matches neither stored identity form.
func withOwnLIDs(myJIDs []string, lidToPN map[string]string) []string {
	if len(myJIDs) == 0 || len(lidToPN) == 0 {
		return myJIDs
	}
	own := make(map[string]bool, len(myJIDs))
	for _, j := range myJIDs {
		own[j] = true
		own[bare(j)] = true
	}
	for lid, pn := range lidToPN {
		if (own[pn] || own[bare(pn)]) && !own[lid] {
			myJIDs = append(myJIDs, lid)
			own[lid] = true
		}
	}
	return myJIDs
}

// canonicalSender resolves a message sender to its phone-number JID:
// prefer the per-message SenderAlt (LID migrations carry both forms), fall
// back to the learned lid→pn table. Returns the chat JID when absent.
func canonicalSender(evt *events.Message, lidToPN map[string]string) types.JID {
	sender := evt.Info.Sender
	if sender.IsEmpty() {
		return evt.Info.Chat
	}
	if alt := evt.Info.SenderAlt; !alt.IsEmpty() && alt.Server == types.DefaultUserServer {
		return alt.ToNonAD()
	}
	if sender.Server == types.HiddenUserServer {
		if pn, ok := lidToPN[sender.ToNonAD().String()]; ok && pn != "" {
			if jid, err := types.ParseJID(pn); err == nil && !jid.IsEmpty() {
				return jid.ToNonAD()
			}
		}
	}
	return sender.ToNonAD()
}

// canonicalChat resolves a LID-addressed direct chat to the peer's
// phone-number JID. WhatsApp migrates 1:1 chats to LID addressing
// server-side; storing the raw LID splits one contact into two chat rows
// (the "new thread for the same contact" bug). Incoming 1:1 chats are the
// peer themselves, so the already-canonical sender names the phone thread;
// from-me echoes and unmapped LIDs fall back to the learned table. Groups
// and unmapped LIDs pass through unchanged — never guess a phone JID.
func canonicalChat(evt *events.Message, sender types.JID, lidToPN map[string]string) types.JID {
	chat := evt.Info.Chat
	if chat.Server != types.HiddenUserServer {
		return chat
	}
	if !evt.Info.IsFromMe && sender.Server == types.DefaultUserServer {
		return sender
	}
	if pn, ok := lidToPN[chat.ToNonAD().String()]; ok && pn != "" {
		if jid, err := types.ParseJID(pn); err == nil && !jid.IsEmpty() {
			return jid.ToNonAD()
		}
	}
	return chat
}

func mediaMeta(kind, url, directPath, mime string, size int64, sha, encSha, key []byte, w, h int, durMS int64, filename string) *core.MediaMeta {
	return &core.MediaMeta{
		Kind: kind, URL: url, DirectPath: directPath, MIME: mime, Size: size,
		FileSHA256: sha, FileEncSHA256: encSha, MediaKey: key,
		Width: w, Height: h, DurationMS: durMS, Filename: filename, State: "not_downloaded",
	}
}

// rawKindOf labels an unrecognized message with its protocol type for the
// "unsupported message" placeholder row.
func rawKindOf(msg *waE2E.Message) string {
	switch {
	case msg.GetContactsArrayMessage() != nil:
		return "contacts"
	case msg.GetContactMessage() != nil:
		return "contact_card"
	case msg.GetLocationMessage() != nil:
		return "location"
	case msg.GetLiveLocationMessage() != nil:
		return "live_location"
	case msg.GetPollCreationMessage() != nil, msg.GetPollUpdateMessage() != nil:
		return "poll"
	case msg.GetProductMessage() != nil:
		return "product"
	case msg.GetCall() != nil:
		return "call"
	case msg.GetGroupInviteMessage() != nil:
		return "group_invite"
	case msg.GetTemplateMessage() != nil:
		return "template"
	case msg.GetButtonsMessage() != nil, msg.GetListMessage() != nil,
		msg.GetInteractiveMessage() != nil, msg.GetButtonsResponseMessage() != nil,
		msg.GetListResponseMessage() != nil:
		return "interactive"
	case msg.GetSenderKeyDistributionMessage() != nil:
		return "skdm"
	case msg.GetStickerSyncRmrMessage() != nil:
		return "sticker_sync"
	default:
		return "unknown"
	}
}

func textOf(m *waE2E.Message) string {
	if m == nil {
		return ""
	}
	if t := m.GetConversation(); t != "" {
		return t
	}
	return m.GetExtendedTextMessage().GetText()
}

// isForwarded reports whether the payload carries WhatsApp's forwarding
// marker (a nonzero forwarding score on any per-type ContextInfo). Plain
// conversation messages cannot be forwarded natively, but the check is
// uniform across payload types anyway.
func isForwarded(msg *waE2E.Message) bool {
	if msg == nil {
		return false
	}
	for _, ci := range []*waE2E.ContextInfo{
		msg.GetExtendedTextMessage().GetContextInfo(),
		msg.GetImageMessage().GetContextInfo(),
		msg.GetVideoMessage().GetContextInfo(),
		msg.GetAudioMessage().GetContextInfo(),
		msg.GetDocumentMessage().GetContextInfo(),
		msg.GetStickerMessage().GetContextInfo(),
		msg.GetContactMessage().GetContextInfo(),
		msg.GetLocationMessage().GetContextInfo(),
		msg.GetLiveLocationMessage().GetContextInfo(),
	} {
		if ci != nil && ci.GetForwardingScore() > 0 {
			return true
		}
	}
	return false
}

func fillReply(ci *waE2E.ContextInfo, m *core.Message, myJIDs []string) {
	if ci == nil {
		return
	}
	if ci.GetStanzaID() != "" {
		m.ReplyToID = truncateRunes(ci.GetStanzaID(), 128)
		m.ReplyToSender = truncateRunes(ci.GetParticipant(), 128)
		if q := ci.GetQuotedMessage(); q != nil {
			m.QuotedText = truncateRunes(textOf(q), maxTextRunes)
		}
	}
	// Mention lists are remote-controlled length: cap the stored copy (the
	// send path caps at 32 — sanitizeMentions) so one envelope with
	// thousands of entries cannot bloat every page read.
	mentioned := ci.GetMentionedJID()
	if len(mentioned) > maxMentionEntries {
		mentioned = mentioned[:maxMentionEntries]
	}
	for _, jid := range mentioned {
		m.MentionedJIDs = append(m.MentionedJIDs, jid)
		for _, own := range myJIDs {
			if jid == own || bare(jid) == bare(own) {
				m.HasMention = true
				break
			}
		}
	}
}

// Remote-input bounds: nothing the protocol sends may store unbounded
// strings or out-of-window timestamps — chat previews, FTS rows and
// keyset cursors all inherit whatever lands here.
const (
	maxTextRunes    = 65_536 // WhatsApp's own text cap; hostile servers can exceed it
	maxMentionEntries = 32
	// Timestamp window: 90 days back (clock-skewed clients), 1 day ahead.
	minSaneTS int64 = 1_700_000_000 - 90*86400
	maxSaneTS int64 = 1_900_000_000 // ~2030: comfortably ahead of "now"
)

// truncateRunes bounds s to at most n runes without splitting one.
func truncateRunes(s string, n int) string {
	if len(s) <= n {
		return s // fast path: byte length under the cap implies rune count too
	}
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// bare strips the resource part of a JID for tolerant user comparison.
func bare(jid string) string {
	for i := 0; i < len(jid); i++ {
		if jid[i] == '@' || jid[i] == ':' {
			return jid[:i]
		}
	}
	return jid
}

func participantOr(key *waCommon.MessageKey, fallback string) string {
	if p := key.GetParticipant(); p != "" {
		return p
	}
	return fallback
}

// stubText renders a readable line for system/stub messages.
func stubText(evt *events.Message) string {
	web := evt.SourceWebMsg
	parts := web.GetMessageStubParameters()
	name := evt.Info.PushName
	if name == "" {
		name = evt.Info.Sender.User
	}
	switch web.GetMessageStubType() {
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_ADD,
		waWeb.WebMessageInfo_GROUP_PARTICIPANT_INVITE:
		return fmt.Sprintf("%s added %s", name, joinUsers(parts))
	case waWeb.WebMessageInfo_GROUP_PARTICIPANT_REMOVE,
		waWeb.WebMessageInfo_GROUP_PARTICIPANT_LEAVE:
		return fmt.Sprintf("%s left/was removed", name)
	case waWeb.WebMessageInfo_GROUP_CREATE:
		return fmt.Sprintf("%s created the group", name)
	case waWeb.WebMessageInfo_GROUP_CHANGE_SUBJECT:
		return "Group subject changed"
	case waWeb.WebMessageInfo_GROUP_CHANGE_ICON:
		return "Group icon changed"
	default:
		if len(parts) > 0 {
			return fmt.Sprintf("%v", parts)
		}
		return "System message"
	}
}

func joinUsers(parts []string) string {
	out := ""
	for i, p := range parts {
		if i > 0 {
			out += ", "
		}
		out += p
	}
	return out
}

// extractRichText pulls displayable text from interactive/bot message types
// that keep their text in dedicated fields.
func extractRichText(msg *waE2E.Message) string {
	if t := msg.GetTemplateMessage(); t != nil {
		if h := t.GetHydratedTemplate(); h != nil && h.GetHydratedContentText() != "" {
			return h.GetHydratedContentText()
		}
		if h := t.GetHydratedFourRowTemplate(); h != nil && h.GetHydratedContentText() != "" {
			return h.GetHydratedContentText()
		}
	}
	if b := msg.GetButtonsResponseMessage(); b != nil {
		return b.GetSelectedDisplayText()
	}
	if l := msg.GetListResponseMessage(); l != nil {
		if l.GetTitle() != "" {
			return l.GetTitle()
		}
		return l.GetDescription()
	}
	if i := msg.GetInteractiveMessage(); i != nil {
		if body := i.GetBody(); body != nil {
			return body.GetText()
		}
	}
	if e := msg.GetEventMessage(); e != nil {
		if e.GetName() != "" {
			return e.GetName() + " — " + e.GetDescription()
		}
		return e.GetDescription()
	}
	if sp := msg.GetStickerPackMessage(); sp != nil {
		return "Sticker pack: " + sp.GetName()
	}
	return ""
}

func richContext(msg *waE2E.Message) *waE2E.ContextInfo {
	switch {
	case msg.GetTemplateMessage() != nil:
		return msg.GetTemplateMessage().GetContextInfo()
	case msg.GetButtonsResponseMessage() != nil:
		return msg.GetButtonsResponseMessage().GetContextInfo()
	case msg.GetListResponseMessage() != nil:
		return msg.GetListResponseMessage().GetContextInfo()
	case msg.GetInteractiveMessage() != nil:
		return msg.GetInteractiveMessage().GetContextInfo()
	default:
		return nil
	}
}
