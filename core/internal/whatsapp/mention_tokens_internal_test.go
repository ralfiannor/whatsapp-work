package whatsapp

import "testing"

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
