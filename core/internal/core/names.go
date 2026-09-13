package core

import "strings"

// FallbackChatName is the display-only name for chats without a stored
// name. Never surfaces raw JIDs like "97260054569119@lid".
func FallbackChatName(jid string, kind ChatKind) string {
	if kind == KindGroup {
		return "Group " + strings.SplitN(jid, "-", 2)[0]
	}
	if jid == "0@s.whatsapp.net" {
		return "WhatsApp" // official service account (PSA)
	}
	if i := strings.IndexByte(jid, '@'); i > 0 {
		user := jid[:i]
		if strings.HasSuffix(jid, "@lid") && len(user) > 6 {
			return "\u2022\u2022\u2022" + user[len(user)-4:]
		}
		return "+" + user
	}
	return jid
}
