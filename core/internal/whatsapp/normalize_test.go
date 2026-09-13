// Normalization contract (whatsmeow → core):
//   - plain conversation text → kind text
//   - extended text with ContextInfo → reply refs extracted, mention flag set when own JID mentioned
//   - LID senders and LID-addressed direct chats canonicalize to phone JIDs
//     (one contact must never split into two chat threads)
//   - media messages → media kinds with full re-download metadata and serialized proto
//   - reactions and protocol revokes/edits → dedicated incoming kinds, not message rows
//   - unsupported message types → kind unsupported with raw_kind label, never an error
//   - non-user/group chat servers (newsletter, broadcast/status) are ignored
package whatsapp_test

import (
	"bytes"
	"testing"
	"google.golang.org/protobuf/proto"
	"time"

	waCommon "go.mau.fi/whatsmeow/proto/waCommon"
	"go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/whatsapp"
)

const (
	me    = "254700000001@s.whatsapp.net"
	alice = "254700000002@s.whatsapp.net"
	group = "1203630000000000@g.us"
	msgTS = 1700000100
)

func mustJID(s string) types.JID {
	j, err := types.ParseJID(s)
	if err != nil {
		panic(err)
	}
	return j
}

func info(chat, sender string, fromMe bool, id string) types.MessageInfo {
	chatJID := mustJID(chat)
	senderJID := mustJID(sender)
	return types.MessageInfo{
		MessageSource: types.MessageSource{Chat: chatJID, Sender: senderJID, IsFromMe: fromMe, IsGroup: chatJID.Server == types.GroupServer},
		ID:            id,
		Timestamp:     time.Unix(msgTS, 0),
	}
}

func str(s string) *string { return &s }
func u32(v uint32) *uint32 { return &v }
func u64(v uint64) *uint64 { return &v }
func b(v bool) *bool       { return &v }

func TestNormalizePlainText(t *testing.T) {
	evt := &events.Message{
		Info:    info(alice, alice, false, "m1"),
		Message: &waE2E.Message{Conversation: str("can you review this?")},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Kind != core.IncomingNew {
		t.Fatalf("kind = %v, want new", inc.Kind)
	}
	m := inc.Message
	if m.MessageID != "m1" || m.ChatJID != alice || m.SenderJID != alice || m.FromMe {
		t.Fatalf("routing fields wrong: %+v", m)
	}
	if m.Kind != core.KindText || m.Text != "can you review this?" || m.Timestamp != msgTS {
		t.Fatalf("content wrong: kind=%v text=%q ts=%d", m.Kind, m.Text, m.Timestamp)
	}
	if m.Media != nil {
		t.Fatalf("text message must not carry media: %+v", m.Media)
	}
}

func TestNormalizeReplyAndMention(t *testing.T) {
	evt := &events.Message{
		Info: info(group, alice, false, "m2"),
		Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: str("@me deploy failed, see above"),
			ContextInfo: &waE2E.ContextInfo{
				StanzaID:      str("m0"),
				Participant:   str(alice),
				QuotedMessage: &waE2E.Message{Conversation: str("yesterday's deploy log")},
				MentionedJID:  []string{me},
			},
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	m := inc.Message
	if !m.HasMention {
		t.Fatal("mention of own JID not detected")
	}
	if m.ReplyToID != "m0" || m.ReplyToSender != alice {
		t.Fatalf("reply ref = %s/%s, want m0/%s", m.ReplyToID, m.ReplyToSender, alice)
	}
	if m.QuotedText != "yesterday's deploy log" {
		t.Fatalf("quoted text = %q", m.QuotedText)
	}
	if len(m.MentionedJIDs) != 1 || m.MentionedJIDs[0] != me {
		t.Fatalf("mentioned jids = %+v", m.MentionedJIDs)
	}
}

func TestNormalizeMentionNotForOthers(t *testing.T) {
	evt := &events.Message{
		Info: info(group, alice, false, "m3"),
		Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        str("hey @other"),
			ContextInfo: &waE2E.ContextInfo{MentionedJID: []string{"254799999999@s.whatsapp.net"}},
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.HasMention {
		t.Fatal("mention flag set for someone else's mention")
	}
}

func TestNormalizeImageWithCaption(t *testing.T) {
	evt := &events.Message{
		Info: info(alice, alice, false, "m4"),
		Message: &waE2E.Message{ImageMessage: &waE2E.ImageMessage{
			URL:           str("https://mmg.example/img"),
			Mimetype:      str("image/jpeg"),
			Caption:       str("screenshot of the error"),
			FileSHA256:    []byte{0x01},
			FileEncSHA256: []byte{0x02},
			MediaKey:      []byte{0x03},
			FileLength:    u64(183241),
			Width:         u32(1280),
			Height:        u32(960),
			DirectPath:    str("/v/t62.7118-24/abc"),
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	m := inc.Message
	if m.Kind != core.KindImage {
		t.Fatalf("kind = %v, want image", m.Kind)
	}
	if m.Text != "screenshot of the error" {
		t.Fatalf("caption not copied to searchable text: %q", m.Text)
	}
	md := m.Media
	if md == nil {
		t.Fatal("media metadata missing")
	}
	if md.MIME != "image/jpeg" || md.Size != 183241 || md.Width != 1280 || md.Height != 960 {
		t.Fatalf("media dims wrong: %+v", md)
	}
	if md.URL == "" || md.DirectPath == "" || len(md.MediaKey) != 1 || len(md.FileEncSHA256) != 1 {
		t.Fatalf("re-download material missing: %+v", md)
	}
	if len(md.Proto) == 0 || !bytes.Contains(md.Proto, []byte("screenshot")) {
		t.Fatal("serialized proto blob missing or empty")
	}
}

func TestNormalizeAudioVideoDocumentSticker(t *testing.T) {
	cases := []struct {
		name string
		msg  *waE2E.Message
		kind core.MessageKind
	}{
		{"audio", &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			URL: str("u"), Mimetype: str("audio/ogg"), Seconds: u32(12), FileLength: u64(99),
		}}, core.KindAudio},
		{"video", &waE2E.Message{VideoMessage: &waE2E.VideoMessage{
			URL: str("u"), Mimetype: str("video/mp4"), Seconds: u32(7), FileLength: u64(1000),
		}}, core.KindVideo},
		{"document", &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			URL: str("u"), Mimetype: str("application/pdf"), FileName: str("spec.pdf"), FileLength: u64(42),
		}}, core.KindDocument},
		{"sticker", &waE2E.Message{StickerMessage: &waE2E.StickerMessage{
			URL: str("u"), Mimetype: str("image/webp"),
		}}, core.KindSticker},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			evt := &events.Message{Info: info(alice, alice, false, "m-"+tc.name), Message: tc.msg}
			inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
			if err != nil {
				t.Fatal(err)
			}
			if inc.Message.Kind != tc.kind {
				t.Fatalf("kind = %v, want %v", inc.Message.Kind, tc.kind)
			}
			if tc.name == "audio" && inc.Message.Media.DurationMS != 12000 {
				t.Fatalf("audio duration = %d ms", inc.Message.Media.DurationMS)
			}
			if tc.name == "document" && inc.Message.Media.Filename != "spec.pdf" {
				t.Fatalf("doc filename = %q", inc.Message.Media.Filename)
			}
		})
	}
}

func TestNormalizeReaction(t *testing.T) {
	evt := &events.Message{
		Info: info(group, alice, false, "r1"),
		Message: &waE2E.Message{ReactionMessage: &waE2E.ReactionMessage{
			Key:  &waCommon.MessageKey{RemoteJID: str(group), ID: str("m9"), FromMe: b(false), Participant: str(alice)},
			Text: str("✅"),
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Kind != core.IncomingReaction {
		t.Fatalf("kind = %v, want reaction", inc.Kind)
	}
	r := inc.Reaction
	if r.ChatJID != group || r.TargetMessageID != "m9" || r.Emoji != "✅" || r.ReactorJID != alice {
		t.Fatalf("reaction ref wrong: %+v", r)
	}

	// Removal = empty emoji text.
	evt.Message.ReactionMessage.Text = str("")
	inc, _ = whatsapp.Normalize([]string{me}, evt, "live", nil)
	if inc.Reaction.Emoji != "" {
		t.Fatalf("emoji removal not detected: %+v", inc.Reaction)
	}
}

func TestNormalizeRevoke(t *testing.T) {
	evt := &events.Message{
		Info: info(group, alice, false, "r2"),
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Key:  &waCommon.MessageKey{RemoteJID: str(group), ID: str("m9"), Participant: str(alice)},
			Type: waE2E.ProtocolMessage_REVOKE.Enum(),
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Kind != core.IncomingRevoke {
		t.Fatalf("kind = %v, want revoke", inc.Kind)
	}
	if inc.Revoke.MessageID != "m9" || inc.Revoke.ChatJID != group {
		t.Fatalf("revoke ref wrong: %+v", inc.Revoke)
	}
}

// In LID-addressed groups the revoke's Key.Participant carries the @lid
// form while the stored row is canonical (phone form) — the sender must be
// mapped or SetRevoked matches 0 rows and the message never disappears.
func TestNormalizeRevokeLIDParticipantCanonicalizes(t *testing.T) {
	lid := "11111111111111@lid"
	pn := "254799000111@s.whatsapp.net"
	evt := &events.Message{
		Info: info(group, lid, false, "r3"),
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Key:  &waCommon.MessageKey{RemoteJID: str(group), ID: str("m10"), Participant: str(lid)},
			Type: waE2E.ProtocolMessage_REVOKE.Enum(),
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", map[string]string{lid: pn})
	if err != nil {
		t.Fatal(err)
	}
	if inc.Kind != core.IncomingRevoke {
		t.Fatalf("kind = %v, want revoke", inc.Kind)
	}
	if inc.Revoke.SenderJID != pn {
		t.Fatalf("revoke sender = %q, want the phone form %q", inc.Revoke.SenderJID, pn)
	}
}

// AD-suffixed participants ("user:device@lid") must strip the suffix before
// the lidToPN lookup or the revoke silently no-ops.
func TestNormalizeRevokeADSuffixParticipantCanonicalizes(t *testing.T) {
	lid := "11111111111111@lid"
	pn := "254799000111@s.whatsapp.net"
	evt := &events.Message{
		Info: info(group, lid, false, "r4"),
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Key:  &waCommon.MessageKey{RemoteJID: str(group), ID: str("m11"), Participant: str("11111111111111:9@lid")},
			Type: waE2E.ProtocolMessage_REVOKE.Enum(),
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", map[string]string{lid: pn})
	if err != nil {
		t.Fatal(err)
	}
	if inc.Kind != core.IncomingRevoke {
		t.Fatalf("kind = %v, want revoke", inc.Kind)
	}
	if inc.Revoke.SenderJID != pn {
		t.Fatalf("revoke sender = %q, want the phone form %q", inc.Revoke.SenderJID, pn)
	}
}

// Sender-stamped timestamps are remote input: far-future stamps poison
// last_read_ts permanently and zero stamps break keyset cursors.
func TestNormalizeClampsHostileTimestamps(t *testing.T) {
	makeEvt := func(ts int64) *events.Message {
		evt := &events.Message{
			Info: info(alice, alice, false, "t1"),
			Message: &waE2E.Message{Conversation: str("hello")},
		}
		evt.Info.Timestamp = time.Unix(ts, 0)
		return evt
	}
	inc, err := whatsapp.Normalize([]string{me}, makeEvt(1<<62), "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.Timestamp > 1_900_000_000 {
		t.Fatalf("future stamp unclamped: %d", inc.Message.Timestamp)
	}
	inc, err = whatsapp.Normalize([]string{me}, makeEvt(0), "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.Timestamp < 1_700_000_000-90*86400 {
		t.Fatalf("zero stamp unclamped: %d", inc.Message.Timestamp)
	}
}

func TestNormalizeEdit(t *testing.T) {
	evt := &events.Message{
		Info: info(alice, alice, false, "e1"),
		Message: &waE2E.Message{ProtocolMessage: &waE2E.ProtocolMessage{
			Key:           &waCommon.MessageKey{RemoteJID: str(alice), ID: str("m8"), FromMe: b(false)},
			Type:          waE2E.ProtocolMessage_MESSAGE_EDIT.Enum(),
			EditedMessage: &waE2E.Message{Conversation: str("fixed typo")},
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Kind != core.IncomingEdit {
		t.Fatalf("kind = %v, want edit", inc.Kind)
	}
	if inc.Message.MessageID != "m8" || inc.Message.Text != "fixed typo" {
		t.Fatalf("edit target wrong: id=%s text=%q", inc.Message.MessageID, inc.Message.Text)
	}
}

func TestNormalizeUnsupportedType(t *testing.T) {
	evt := &events.Message{
		Info:    info(alice, alice, false, "u1"),
		Message: &waE2E.Message{ProductMessage: &waE2E.ProductMessage{}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Kind != core.IncomingNew || inc.Message.Kind != core.KindUnsupported {
		t.Fatalf("unsupported must degrade, not error: %+v", inc)
	}
	if inc.Message.RawKind == "" {
		t.Fatal("raw_kind label missing")
	}
	if inc.Message.Text != "" {
		t.Fatalf("unsupported must not invent text: %q", inc.Message.Text)
	}
}

func TestNormalizeIgnoresNonUserChats(t *testing.T) {
	for _, chat := range []string{"123@newsletter", "status@broadcast"} {
		evt := &events.Message{
			Info:    info(chat, chat, false, "x"),
			Message: &waE2E.Message{Conversation: str("nope")},
		}
		inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
		if err != nil {
			t.Fatal(err)
		}
		if inc.Kind != core.IncomingIgnore {
			t.Fatalf("chat %s not ignored: %+v", chat, inc)
		}
	}
}

func TestNormalizeFromMe(t *testing.T) {
	evt := &events.Message{
		Info:    info(alice, me, true, "o1"),
		Message: &waE2E.Message{Conversation: str("from my other device")},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !inc.Message.FromMe || inc.Message.SenderJID != me {
		t.Fatalf("from-me routing wrong: %+v", inc.Message)
	}
}

func TestNormalizeLIDSenderCanonicalized(t *testing.T) {
	lid := "999000111222333@lid"
	pn := "254799000111@s.whatsapp.net"
	evt := &events.Message{
		Info: types.MessageInfo{
			MessageSource: types.MessageSource{
				Chat: mustJID(group), Sender: mustJID(lid),
				SenderAlt: mustJID(pn), // the LID's phone-number twin
				IsGroup:   true,
			},
			ID: "m10", Timestamp: time.Unix(msgTS, 0),
		},
		Message: &waE2E.Message{Conversation: str("from a LID user")},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.SenderJID != pn {
		t.Fatalf("sender = %q, want PN %q", inc.Message.SenderJID, pn)
	}

	// Without SenderAlt, the learned table must map lid→pn.
	evt.Info.SenderAlt = types.EmptyJID
	inc, _ = whatsapp.Normalize([]string{me}, evt, "history", map[string]string{lid: pn})
	if inc.Message.SenderJID != pn {
		t.Fatalf("table fallback sender = %q, want %q", inc.Message.SenderJID, pn)
	}
}

// A 1:1 chat the server addresses under the peer's LID must land in the
// peer's phone-number thread — leaving the chat JID raw spawns a duplicate
// chat row for the same contact (shipped as the two-threads bug).
func TestNormalizeLIDChatCanonicalized(t *testing.T) {
	lid := "999000111222333@lid"
	pn := "254799000111@s.whatsapp.net"
	base := func() *events.Message {
		return &events.Message{
			Info: types.MessageInfo{
				MessageSource: types.MessageSource{
					Chat: mustJID(lid), Sender: mustJID(lid),
					SenderAlt: mustJID(pn),
				},
				ID: "c1", Timestamp: time.Unix(msgTS, 0),
			},
			Message: &waE2E.Message{Conversation: str("pasar reply")},
		}
	}

	// Incoming: chat is the peer, SenderAlt carries the phone twin.
	inc, err := whatsapp.Normalize([]string{me}, base(), "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.ChatJID != pn {
		t.Fatalf("chat = %q, want PN %q", inc.Message.ChatJID, pn)
	}

	// No SenderAlt: the learned lid→pn table must resolve the chat.
	evt := base()
	evt.Info.SenderAlt = types.EmptyJID
	inc, err = whatsapp.Normalize([]string{me}, evt, "live", map[string]string{lid: pn})
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.ChatJID != pn || inc.Message.SenderJID != pn {
		t.Fatalf("table fallback: chat=%q sender=%q, want %q", inc.Message.ChatJID, inc.Message.SenderJID, pn)
	}

	// From-me echo in a LID chat: sender is me, so only the table can name
	// the peer's phone thread.
	echo := base()
	echo.Info.Sender = mustJID(me)
	echo.Info.SenderAlt = types.EmptyJID
	echo.Info.IsFromMe = true
	inc, err = whatsapp.Normalize([]string{me}, echo, "live", map[string]string{lid: pn})
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.ChatJID != pn || inc.Message.SenderJID != me {
		t.Fatalf("from-me echo: chat=%q sender=%q, want %q/%s", inc.Message.ChatJID, inc.Message.SenderJID, pn, me)
	}

	// Unmapped LID stays LID — never guess a phone thread.
	evt = base()
	evt.Info.SenderAlt = types.EmptyJID
	inc, err = whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.ChatJID != lid {
		t.Fatalf("unmapped chat = %q, want LID %q", inc.Message.ChatJID, lid)
	}

	// Groups are never rewritten even when participants are LID users.
	grp := base()
	grp.Info.Chat = mustJID(group)
	grp.Info.IsGroup = true
	inc, err = whatsapp.Normalize([]string{me}, grp, "live", map[string]string{lid: pn})
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.ChatJID != group {
		t.Fatalf("group chat = %q, want %q", inc.Message.ChatJID, group)
	}
}

func TestNormalizeRichInteractiveText(t *testing.T) {
	cases := []struct {
		name string
		msg  *waE2E.Message
		want string
	}{
		{"template", &waE2E.Message{TemplateMessage: &waE2E.TemplateMessage{
			HydratedTemplate: &waE2E.TemplateMessage_HydratedFourRowTemplate{
				HydratedContentText: str("Menu hari ini tersedia"),
			},
		}}, "Menu hari ini tersedia"},
		{"buttons", &waE2E.Message{ButtonsResponseMessage: &waE2E.ButtonsResponseMessage{
			Response: &waE2E.ButtonsResponseMessage_SelectedDisplayText{
				SelectedDisplayText: "Pilih: Hemat",
			},
		}}, "Pilih: Hemat"},
		{"list", &waE2E.Message{ListResponseMessage: &waE2E.ListResponseMessage{
			Title: str("Paket Data"), Description: str("detail"),
		}}, "Paket Data"},
		{"interactive", &waE2E.Message{InteractiveMessage: &waE2E.InteractiveMessage{
			Body: &waE2E.InteractiveMessage_Body{Text: str("Ketuk untuk melanjutkan")},
		}}, "Ketuk untuk melanjutkan"},
		{"event", &waE2E.Message{EventMessage: &waE2E.EventMessage{
			Name: str("Rapat Tim"), Description: str("Rabu 20:00"),
		}}, "Rapat Tim — Rabu 20:00"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			evt := &events.Message{Info: info(group, alice, false, "r-"+tc.name), Message: tc.msg}
			inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
			if err != nil {
				t.Fatal(err)
			}
			if inc.Message.Kind != core.KindText || inc.Message.Text != tc.want {
				t.Fatalf("got kind=%v text=%q, want text=%q", inc.Message.Kind, inc.Message.Text, tc.want)
			}
		})
	}
}

func TestNormalizeSkdmIgnored(t *testing.T) {
	evt := &events.Message{
		Info:    info(group, alice, false, "sk1"),
		Message: &waE2E.Message{SenderKeyDistributionMessage: &waE2E.SenderKeyDistributionMessage{}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil || inc.Kind != core.IncomingIgnore {
		t.Fatalf("skdm must be ignored, got %+v err=%v", inc, err)
	}
}

// rehydrateMedia must reverse what normalize persists: inner media protos
// (Marshal(ImageMessage) etc.), not the outer waE2E.Message wrapper. The old
// unmarshal-into-Message path failed with "invalid wire-format data" on every
// download.
func TestRehydrateMedia(t *testing.T) {
	img := &waE2E.ImageMessage{
		URL:         proto.String("https://example.org/img"),
		DirectPath:  proto.String("/v/id"),
		Mimetype:    proto.String("image/jpeg"),
		FileLength:  proto.Uint64(1234),
		MediaKey:    []byte("key"),
		FileEncSHA256: []byte("enc"),
	}
	blob, err := proto.Marshal(img)
	if err != nil {
		t.Fatal(err)
	}
	msg, err := whatsapp.RehydrateMedia("image", blob)
	if err != nil {
		t.Fatalf("rehydrate: %v", err)
	}
	if msg.GetImageMessage().GetURL() != "https://example.org/img" ||
		msg.GetImageMessage().GetFileLength() != 1234 {
		t.Fatalf("roundtrip lost fields: %+v", msg.GetImageMessage())
	}

	// Cross-kind blobs are tolerated: WhatsApp media protos share field
	// numbers for url/mediaKey/encSha256, so a mismatched-but-parsable blob
	// is harmless (DownloadAny dispatches on the wrapped oneof field).
	if _, err := whatsapp.RehydrateMedia("audio", blob); err != nil {
		t.Fatalf("cross-kind parse should not error: %v", err)
	}
	if _, err := whatsapp.RehydrateMedia("image", []byte{0xff, 0xff, 0xff}); err == nil {
		t.Fatal("garbage blob must error")
	}
	if _, err := whatsapp.RehydrateMedia("hologram", blob); err == nil {
		t.Fatal("unknown kind must error")
	}
}

func TestNormalizeForwarded(t *testing.T) {
	// Forwarded text (WhatsApp turns forwarded plain text into
	// extended-text with a nonzero forwarding score).
	evt := &events.Message{
		Info: info(alice, alice, false, "f1"),
		Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text: str("fyi from the other team"),
			ContextInfo: &waE2E.ContextInfo{ForwardingScore: u32(7)},
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !inc.Message.Forwarded {
		t.Fatalf("forwarded flag lost: %+v", inc.Message)
	}

	// Normal text must stay unflagged.
	evt.Info.ID = "f2"
	evt.Message = &waE2E.Message{Conversation: str("regular message")}
	inc, err = whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.Forwarded {
		t.Fatalf("plain text marked forwarded: %+v", inc.Message)
	}

	// Zero score counts as not forwarded.
	evt.Info.ID = "f3"
	evt.Message = &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
		Text:        str("score zero"),
		ContextInfo: &waE2E.ContextInfo{ForwardingScore: u32(0)},
	}}
	inc, err = whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.Forwarded {
		t.Fatalf("zero score marked forwarded: %+v", inc.Message)
	}
}

// Documents carry captions (we send captioned documents ourselves); a mention
// or reply inside that caption must survive normalization exactly like an
// extended-text mention does.
func TestNormalizeDocumentCaptionMention(t *testing.T) {
	evt := &events.Message{
		Info: info(group, alice, false, "d1"),
		Message: &waE2E.Message{DocumentMessage: &waE2E.DocumentMessage{
			FileName: str("deploy.log"),
			Caption:  str("@me look at this trace"),
			ContextInfo: &waE2E.ContextInfo{
				StanzaID:     str("d0"),
				Participant:  str(alice),
				MentionedJID: []string{me},
			},
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	m := inc.Message
	if m.Kind != core.KindDocument {
		t.Fatalf("kind = %v, want document", m.Kind)
	}
	if m.Text != "@me look at this trace" {
		t.Fatalf("document caption lost: %q", m.Text)
	}
	if !m.HasMention {
		t.Fatal("mention inside document caption not detected")
	}
	if m.ReplyToID != "d0" {
		t.Fatalf("document reply context lost: %+v", m)
	}
	if m.Media == nil || m.Media.Filename != "deploy.log" {
		t.Fatalf("media meta wrong: %+v", m.Media)
	}
}

// Audio (and sticker) messages have no caption but DO carry reply context.
func TestNormalizeAudioReplyContext(t *testing.T) {
	evt := &events.Message{
		Info: info(group, alice, false, "a1"),
		Message: &waE2E.Message{AudioMessage: &waE2E.AudioMessage{
			ContextInfo: &waE2E.ContextInfo{
				StanzaID:    str("a0"),
				Participant: str(alice),
			},
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", nil)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.Kind != core.KindAudio {
		t.Fatalf("kind = %v, want audio", inc.Message.Kind)
	}
	if inc.Message.ReplyToID != "a0" || inc.Message.ReplyToSender != alice {
		t.Fatalf("audio reply context lost: %+v", inc.Message)
	}
}

// Sessions with an empty stored LID still learn their own lid→pn mapping in
// the lid table; a mention addressed to the LID twin must resolve to "me".
func TestNormalizeOwnLIDMentionViaMap(t *testing.T) {
	const myLID = "98765432109876@lid"
	lidToPN := map[string]string{myLID: me}
	evt := &events.Message{
		Info: info(group, alice, false, "l1"),
		Message: &waE2E.Message{ExtendedTextMessage: &waE2E.ExtendedTextMessage{
			Text:        str("ping @you"),
			ContextInfo: &waE2E.ContextInfo{MentionedJID: []string{myLID}},
		}},
	}
	inc, err := whatsapp.Normalize([]string{me}, evt, "live", lidToPN)
	if err != nil {
		t.Fatal(err)
	}
	if !inc.Message.HasMention {
		t.Fatal("mention of own LID twin not detected via lid map")
	}

	// And a LID that maps to someone else must NOT match.
	lidToPN = map[string]string{"11111111111111@lid": "254799999999@s.whatsapp.net"}
	evt.Info.ID = "l2"
	evt.Message.ExtendedTextMessage.ContextInfo.MentionedJID = []string{"11111111111111@lid"}
	inc, err = whatsapp.Normalize([]string{me}, evt, "live", lidToPN)
	if err != nil {
		t.Fatal(err)
	}
	if inc.Message.HasMention {
		t.Fatal("foreign LID mention matched own identity")
	}
}
