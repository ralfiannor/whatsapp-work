package core

import "context"

// WAClient is the narrow port between the application layer and the WhatsApp
// protocol adapter. whatsmeow types never cross this boundary; the adapter
// (internal/whatsapp) is the only package that imports whatsmeow.
type WAClient interface {
	Connect(ctx context.Context) error
	Disconnect()
	Logout(ctx context.Context) error
	LoggedIn() bool
	OwnJID() string
	// StartQRLogin begins linked-device login; QR codes arrive as EventQR.
	StartQRLogin(ctx context.Context) error
	// SendText sends a text, optionally as a reply and/or mentioning the
	// given JIDs. mentioned may be nil; labels ("@Name") live in the text.
	SendText(ctx context.Context, chatJID, text string, reply *ReplyRef, mentioned []string) (SendAck, error)
	// SendMedia uploads attachment bytes to WhatsApp and sends the message;
	// the returned MediaMeta carries re-download material for persistence.
	SendMedia(ctx context.Context, chatJID string, data []byte, mime, filename, caption string, reply *ReplyRef) (SendAck, *MediaMeta, error)
	React(ctx context.Context, chatJID string, target MessageRef, emoji string) error
	// MarkRead sends read receipts for messages of one sender in one chat.
	MarkRead(ctx context.Context, chatJID, senderJID string, messageIDs []string) error
	// RevokeMessage deletes the caller's own message for everyone
	// ("delete for everyone"); messageID is the WhatsApp stanza id.
	RevokeMessage(ctx context.Context, chatJID, messageID string) error
	Events() <-chan RawEvent
	GroupMembers(ctx context.Context, groupJID string) ([]GroupMember, error)
	// ProfilePicture returns the user's profile-photo CDN URL ("" when the
	// user has none or hides it from linked devices).
	ProfilePicture(ctx context.Context, jid string) (string, error)
	// GroupInfoName fetches a group's current subject (network call).
	GroupInfoName(ctx context.Context, groupJID string) (string, error)
	// ResolveLIDs returns lid→phone-number JID mappings learned by whatsmeow
	// (LID migration: many chats/messages arrive with @lid senders).
	ResolveLIDs(ctx context.Context) map[string]string
	// UserNames batch-queries the usync directory for display names
	// (verified/business names — push names are NOT carried there). This is
	// the only name source for business senders, who usually withhold their
	// push name from linked devices.
	UserNames(ctx context.Context, jids []string) (map[string]string, error)
}
