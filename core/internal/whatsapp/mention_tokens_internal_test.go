package whatsapp

import (
	"testing"

	"go.mau.fi/whatsmeow/types"
)

func mustJID(t *testing.T, raw string) types.JID {
	t.Helper()
	j, err := types.ParseJID(raw)
	if err != nil || j.IsEmpty() {
		t.Fatalf("bad jid %q: %v", raw, err)
	}
	return j
}

// Safety net: tokens already carry identity digits (the composer rewrites
// display labels before sending); the adapter must keep them intact and
// map single-word tokens it can bound.
func TestRewriteMentionTokens(t *testing.T) {
	cases := []struct {
		name     string
		text     string
		mentions []string
		want     string
	}{
		{"digits passthrough", "@229660558364874 test", []string{"229660558364874@lid"}, "@229660558364874 test"},
		{"single word label", "@Ann x", []string{"111@lid"}, "@111 x"},
		{"no mentions passthrough", "@Ann only", nil, "@Ann only"},
		{"plain text", "no tokens here", []string{"1@lid"}, "no tokens here"},
	}
	for _, tc := range cases {
		if got := rewriteMentionTokens(tc.text, tc.mentions); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

// mentionWireText gates the positional token rewrite to LID-space groups.
// In old-format groups the composer now sends identity-digit tokens itself;
// the word-boundary swallow here cannot know where a multi-word display
// label ends and corrupted it ("@Nura Biks" → "@digits Biks" on receivers).
func TestMentionWireTextGatedToLIDSpaceGroups(t *testing.T) {
	nonLID := mustJID(t, "120363410035450855@g.us")
	lid := mustJID(t, "4782936427-1234567890@g.us")
	dm := mustJID(t, "4915204107177@s.whatsapp.net")
	mentions := []string{"4915204107177@s.whatsapp.net"}
	text := "@Nura Biks lu ada update?"

	if got := mentionWireText(nonLID, text, mentions); got != text {
		t.Errorf("non-LID group: got %q, want unchanged %q", got, text)
	}
	if got := mentionWireText(dm, text, mentions); got != text {
		t.Errorf("dm: got %q, want unchanged %q", got, text)
	}
	// LID-space groups still get the positional upgrade for single-word
	// tokens the composer could not pair (roster miss).
	if got, want := mentionWireText(lid, "@Ann x", []string{"111@lid"}), "@111 x"; got != want {
		t.Errorf("lid group: got %q, want %q", got, want)
	}
}
