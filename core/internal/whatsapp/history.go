package whatsapp

import (
	"go.mau.fi/whatsmeow/proto/waHistorySync"
	waWeb "go.mau.fi/whatsmeow/proto/waWeb"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// webMessageParser is the whatsmeow call ConvertHistory needs; injected so
// the conversion is unit-testable without a live client.
type webMessageParser func(chat types.JID, web *waWeb.WebMessageInfo) (*events.Message, error)

// ConvertHistory turns a HistorySync payload into ordered core events:
// one EventHistoryBatch per conversation, then one EventContacts for the
// pushnames. Pushnames come from the payload's top-level list AND from the
// per-message envelopes (the top-level list only covers recent/direct
// chats — big-group senders would otherwise stay masked). Unparsable
// conversations/messages are skipped silently — history sync must never
// abort on partial data (R3, R11).
func ConvertHistory(myJIDs []string, data *waHistorySync.HistorySync, parse webMessageParser, lidToPN map[string]string) []core.RawEvent {
	if data == nil {
		return nil
	}
	var out []core.RawEvent
	pushByJID := map[string]string{}
	own := make(map[string]bool, len(myJIDs))
	for _, j := range myJIDs {
		own[j] = true
	}
	for _, conv := range data.GetConversations() {
		chatJID, err := types.ParseJID(conv.GetID())
		if err != nil || chatJID.IsEmpty() {
			continue
		}
		switch chatJID.Server {
		case types.DefaultUserServer, types.HiddenUserServer, types.GroupServer:
		default:
			continue
		}
		kind := core.KindDirect
		if chatJID.Server == types.GroupServer {
			kind = core.KindGroup
		}

		batch := core.EventHistoryBatch{Chat: core.Chat{
			JID:  chatJID.String(),
			Kind: kind,
			// Synced history counts as read (docs/schema.md): the read
			// position starts at the newest synced timestamp.
			LastReadTS: int64(conv.GetLastMsgTimestamp()),
		}}
		if name := conv.GetName(); name != "" {
			batch.Chat.DisplayName = name
		}
		for _, hm := range conv.GetMessages() {
			web := hm.GetMessage()
			if web == nil {
				continue
			}
			msgEvt, err := parse(chatJID, web)
			if err != nil || msgEvt == nil {
				continue
			}
			inc, err := Normalize(myJIDs, msgEvt, "history", lidToPN)
			if err != nil || inc.Kind == core.IncomingIgnore {
				continue
			}
			batch.Items = append(batch.Items, inc)
			if pn := msgEvt.Info.PushName; pn != "" && !inc.Message.FromMe && !own[inc.Message.SenderJID] {
				pushByJID[inc.Message.SenderJID] = pn
			}
		}
		out = append(out, batch)
	}

	// The top-level list is the server's curated view; it wins on conflict
	// with per-message snapshots.
	for _, p := range data.GetPushnames() {
		if p.GetPushname() == "" {
			continue
		}
		if jid, err := types.ParseJID(p.GetID()); err == nil && !jid.IsEmpty() {
			pushByJID[jid.String()] = p.GetPushname()
		}
	}
	var contacts []core.Contact
	for jid, pn := range pushByJID {
		contacts = append(contacts, core.Contact{JID: jid, PushName: pn})
	}
	if len(contacts) > 0 {
		out = append(out, core.EventContacts{Contacts: contacts})
	}
	return out
}

// GroupInfoToChat maps a group-metadata event into a chat upsert when it
// carries a name change; nil when there is nothing name-worthy.
func GroupInfoToChat(evt *events.GroupInfo) *core.Chat {
	if evt == nil || evt.Name == nil || evt.Name.Name == "" {
		return nil
	}
	return &core.Chat{
		JID:         evt.JID.String(),
		Kind:        core.KindGroup,
		DisplayName: evt.Name.Name,
	}
}
