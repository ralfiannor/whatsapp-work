package core

// Normalized events. The whatsapp adapter converts whatsmeow's raw events
// into these and pushes them on its Events() channel; the app layer ingests
// them in a single goroutine (total order) — see docs/architecture.md §3.

// IncomingKind classifies a normalized message event.
type IncomingKind string

const (
	IncomingNew      IncomingKind = "new"
	IncomingEdit     IncomingKind = "edit"
	IncomingRevoke   IncomingKind = "revoke"
	IncomingReaction IncomingKind = "reaction"
	IncomingIgnore   IncomingKind = "ignore"
)

// Incoming is the result of normalizing one events.Message.
type Incoming struct {
	Kind     IncomingKind
	Message  Message // New, Edit
	Revoke   RevokeRef
	Reaction ReactionRef
}

// RevokeRef points at the message being revoked.
type RevokeRef struct {
	ChatJID   string
	MessageID string
	SenderJID string
	Timestamp int64
}

// ReactionRef points at the message being reacted to.
type ReactionRef struct {
	ChatJID         string
	TargetMessageID string
	ReactorJID      string
	Emoji           string // "" = reaction removed
	Timestamp       int64
}

// RawEvent is implemented by every event crossing the adapter→app channel.
type RawEvent interface{ rawEvent() }

// EventMessage is a normalized incoming (or history-synced) message.
type EventMessage struct {
	Incoming Incoming
	Source   string // "live" | "history"
}

// EventReceipt is a delivery/read receipt for outgoing messages
// (or a read-self receipt from another own device — Status "read_self").
type EventReceipt struct {
	ChatJID          string
	MessageSenderJID string // sender of the referenced messages (own JID for outgoing receipts)
	ChatIsGroup      bool
	MessageIDs       []string
	Status           string // delivered | read | read_self | played
	Timestamp        int64
}

// EventConnState reports connection lifecycle transitions.
type EventConnState struct {
	State  ConnState
	Reason string
}

// EventQR reports a fresh QR code during linking.
type EventQR struct {
	Code      string
	ExpiresTS int64
}

// EventSyncProgress reports history-sync progress (0–100).
type EventSyncProgress struct {
	Stage    string // chats | messages | done
	Progress float64
}

// EventContacts reports contact name data (initial sync or push-name updates).
type EventContacts struct {
	Contacts []Contact
}

// EventChatUpsert reports chat metadata from history sync.
type EventChatUpsert struct {
	Chat Chat
}

// EventPairSuccess reports a completed linked-device pairing.
type EventPairSuccess struct {
	JID string
}

// EventReaction reports an incoming reaction add/remove. (Live reactions
// arrive inside EventMessage via IncomingKind=IncomingReaction; adapters may
// also emit this directly.)
type EventReaction struct {
	ChatJID         string
	TargetMessageID string
	ReactorJID      string
	Emoji           string // "" = removed
	Timestamp       int64
}

// EventHistoryBatch carries one conversation's history-sync result: chat
// metadata (incl. the synced read position) plus normalized messages. The app
// persists these in chunked transactions without per-message events (R3).
type EventHistoryBatch struct {
	Chat  Chat
	Items []Incoming
}

func (EventMessage) rawEvent()      {}
func (EventReceipt) rawEvent()      {}
func (EventConnState) rawEvent()    {}
func (EventQR) rawEvent()           {}
func (EventSyncProgress) rawEvent() {}
func (EventContacts) rawEvent()     {}
func (EventChatUpsert) rawEvent()   {}
func (EventPairSuccess) rawEvent()  {}
func (EventReaction) rawEvent()     {}
func (EventHistoryBatch) rawEvent() {}
