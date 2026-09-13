// Package core holds the pure domain types shared across layers.
//
// It has no dependencies on storage, transport, or whatsmeow: the whatsapp
// adapter translates protocol objects into these types, and storage/IPC
// consume them. Wire (JSON) shapes for the SwiftUI client are the same
// structs — see docs/protocol.md.
package core

// ChatKind distinguishes direct conversations from groups.
type ChatKind string

const (
	KindDirect ChatKind = "direct"
	KindGroup  ChatKind = "group"
)

// MessageKind is the normalized content type of a message.
type MessageKind string

const (
	KindText        MessageKind = "text"
	KindImage       MessageKind = "image"
	KindVideo       MessageKind = "video"
	KindAudio       MessageKind = "audio"
	KindDocument    MessageKind = "document"
	KindSticker     MessageKind = "sticker"
	KindSystem      MessageKind = "system"
	KindUnsupported MessageKind = "unsupported"
)

// ConnState is the login/connection lifecycle state surfaced to the UI.
type ConnState string

const (
	StateLoggedOut  ConnState = "logged_out"
	StateLinking    ConnState = "linking"
	StateConnecting ConnState = "connecting"
	StateConnected  ConnState = "connected"
	StateOffline    ConnState = "offline" // was connected, lost the socket, reconnecting
)

// Chat is a conversation row. It doubles as the /chats wire object.
type Chat struct {
	JID             string   `json:"jid"`
	Kind            ChatKind `json:"kind"`
	DisplayName     string   `json:"display_name"`
	LastMessageID   string   `json:"last_message_id,omitempty"`
	LastMessageTS   int64    `json:"last_message_ts,omitempty"`
	LastPreview     string   `json:"last_preview,omitempty"`
	LastReadTS      int64    `json:"-"`
	UnreadCount     int      `json:"unread_count"`
	MentionedUnread int      `json:"mentioned_unread"`
	IsPinned        bool     `json:"is_pinned"`
	IsMuted         bool     `json:"is_muted"`
	IsArchived      bool     `json:"is_archived"`
	IsWork          bool     `json:"is_work"`
	IsStarred       bool     `json:"is_starred"`
	// LID is the peer's @lid twin for direct chats, stamped from the lid
	// map at read time (not persisted on the row).
	LID             string   `json:"lid,omitempty"`
	UpdatedAt       int64    `json:"-"`
}

// MaxMediaBytes caps a single media item's download. The proto's
// FileLength is attacker-supplied — the cap is enforced against ACTUAL
// received bytes on every path (transport-level while streaming, and the
// post-download re-check).
const MaxMediaBytes = 100 << 20 // 100 MB

// MediaMeta is everything needed to render a media message and to
// re-download its bytes on demand. URLs expire (docs/architecture.md R4),
// so the key/hashes and the serialized proto are persisted at receive time.
type MediaMeta struct {
	ID            string `json:"id"`
	Kind          string `json:"kind"`
	MIME          string `json:"mime"`
	Size          int64  `json:"size"`
	Filename      string `json:"filename,omitempty"`
	Width         int    `json:"width,omitempty"`
	Height        int    `json:"height,omitempty"`
	DurationMS    int64  `json:"duration_ms,omitempty"`
	URL           string `json:"-"`
	DirectPath    string `json:"-"`
	MediaKey      []byte `json:"-"`
	FileSHA256    []byte `json:"-"`
	FileEncSHA256 []byte `json:"-"`
	Proto         []byte `json:"-"`
	State         string `json:"state"`
	LocalPath     string `json:"local_path,omitempty"`
}

// Message is one message row. It doubles as the /messages wire object.
type Message struct {
	ID            int64       `json:"id"`
	MessageID     string      `json:"message_id"`
	ChatJID       string      `json:"chat_jid"`
	SenderJID     string      `json:"sender_jid"`
	FromMe        bool        `json:"from_me"`
	Timestamp     int64       `json:"timestamp"`
	Kind          MessageKind `json:"kind"`
	RawKind       string      `json:"raw_kind,omitempty"`
	Text          string      `json:"text,omitempty"`
	ReplyToID     string      `json:"reply_to_id,omitempty"`
	ReplyToSender string      `json:"reply_to_sender,omitempty"`
	QuotedText    string      `json:"quoted_text,omitempty"`
	HasMention    bool        `json:"has_mention"`
	MentionedJIDs []string    `json:"mentioned_jids"`
	ReceiptStatus string      `json:"receipt_status,omitempty"`
	Source        string      `json:"-"`
	Revoked       bool        `json:"revoked"`
	Forwarded     bool        `json:"forwarded"`
	EditedTS      int64       `json:"edited_ts,omitempty"`
	// Starred/Done mirror local_message_state so the transcript can render
	// work-inbox state on the row itself (LEFT JOIN on message reads).
	Starred       bool        `json:"starred"`
	Done          bool        `json:"done"`
	CreatedAt     int64       `json:"-"`
	UpdatedAt     int64       `json:"-"`
	Media         *MediaMeta  `json:"media,omitempty"`
	Reactions     []Reaction  `json:"reactions,omitempty"`
}

// Reaction is one emoji attached to a message.
type Reaction struct {
	ReactorJID string `json:"reactor_jid"`
	Emoji      string `json:"emoji"`
}

// ReplyRef identifies the message being replied to when sending.
type ReplyRef struct {
	ID     string `json:"id"`
	Sender string `json:"sender"`
}

// MessageRef identifies an existing message for reactions and receipts.
type MessageRef struct {
	ID        string
	SenderJID string
	FromMe    bool
}

// SendAck is the server acknowledgment for a sent message.
type SendAck struct {
	MessageID string
	Timestamp int64
}

// Contact is a known WhatsApp contact.
type Contact struct {
	JID          string `json:"jid"`
	FullName     string `json:"full_name"`
	PushName     string `json:"push_name"`
	BusinessName string `json:"business_name"`
	UpdatedAt    int64  `json:"-"`
}

// GroupMember is one participant of a group chat. JID is the canonical
// phone form when known; LID carries the alternate @lid digits for groups
// addressed in LID space (mention tokens there must use them).
type GroupMember struct {
	JID         string `json:"jid"`
	DisplayName string `json:"display_name"`
	Role        string `json:"role"`
	LID         string `json:"lid,omitempty"`
}

// QRInfo is the current QR code during linked-device login.
type QRInfo struct {
	Code      string `json:"code"`
	ExpiresTS int64  `json:"expires_ts"`
}

// SyncInfo is the initial history-sync progress.
type SyncInfo struct {
	Stage    string  `json:"stage"`
	Progress float64 `json:"progress"`
}

// SessionInfo is the GET /session payload.
type SessionInfo struct {
	State   ConnState `json:"state"`
	Account string    `json:"account,omitempty"`
	QR      *QRInfo   `json:"qr,omitempty"`
	Sync    *SyncInfo `json:"sync,omitempty"`
}

// SearchHit is one FTS match.
type SearchHit struct {
	RowID     int64  `json:"rowid"`
	MessageID string `json:"message_id"`
	ChatJID   string `json:"chat_jid"`
	Timestamp int64  `json:"timestamp"`
	Kind      string `json:"kind"`
	Snippet   string `json:"snippet"`
}

// UserProfile is the full profile payload for the member panel's "View
// Profile" (names from the local contact index, photo URL fetched live).
type UserProfile struct {
	// JID is the canonical phone-number form when known (input may be LID).
	JID          string `json:"jid"`
	LID          string `json:"lid,omitempty"` // alternate @lid form when known
	FullName     string `json:"full_name"`
	PushName     string `json:"push_name"`
	BusinessName string `json:"business_name"`
	// Role in the requesting group when known ("admin" | "member" | "").
	Role       string `json:"role,omitempty"`
	PictureURL string `json:"picture_url,omitempty"`
}

// ContactIdentity is the PN↔LID pair for a person: jid is the canonical
// phone form when known, lid the alternate @lid form when known (either may
// equal the input).
type ContactIdentity struct {
	JID string `json:"jid"`
	LID string `json:"lid,omitempty"`
}

// SearchResult is the GET /search payload.
type SearchResult struct {
	Messages []SearchHit `json:"messages"`
	Chats    []Chat      `json:"chats"`
	Contacts []Contact   `json:"contacts"`
}

// InboxItem is one message row used by the recently-done audit section.
type InboxItem struct {
	MessageID  string `json:"message_id"`
	RowID      int64  `json:"rowid"`
	ChatJID    string `json:"chat_jid"`
	ChatName   string `json:"chat_name"`
	SenderJID  string `json:"sender_jid"`
	Timestamp  int64  `json:"timestamp"`
	Text       string `json:"text"`
	HasMention bool   `json:"has_mention"`
	Starred    bool   `json:"starred"`
}

// InboxConversation is one actionable conversation in the work inbox: the
// chat plus a digest of its pending items (newest message, count, whether
// any item mentions me). Done/Snooze act on the whole conversation — a busy
// group is one row to clear, not fifty.
type InboxConversation struct {
	ChatJID      string `json:"chat_jid"`
	ChatName     string `json:"chat_name"`
	Kind         string `json:"kind"` // direct | group
	IsWork       bool   `json:"is_work"`
	IsStarred    bool   `json:"is_starred"`
	LastMessageID string `json:"last_message_id"`
	LastRowID    int64  `json:"last_rowid"`
	LastSenderJID string `json:"last_sender_jid"`
	LastText     string `json:"last_text"`
	LastKind     string `json:"last_kind"`
	LastTimestamp int64  `json:"last_timestamp"`
	HasMention   bool   `json:"has_mention"` // any pending item mentions me
	Count        int    `json:"count"`       // pending items in this conversation
}

// InboxCounts summarizes the inbox for badge totals (conversations).
type InboxCounts struct {
	Total    int `json:"total"`
	Mentions int `json:"mentions"`
	Direct   int `json:"direct"`
	Work     int `json:"work"`
}

// Inbox is the GET /inbox payload: actionable conversations, grouped.
type Inbox struct {
	Mentions     []InboxConversation `json:"mentions"`
	Direct       []InboxConversation `json:"direct_messages"`
	WorkGroups   []InboxConversation `json:"work_groups"`
	StarredChats []Chat              `json:"starred_chats"`
	DoneRecent   []InboxItem         `json:"done_recent"`
	Counts       InboxCounts         `json:"counts"`
}
