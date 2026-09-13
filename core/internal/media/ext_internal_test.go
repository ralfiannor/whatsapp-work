package media

import "testing"

// Strict assertions only for mappings the Go stdlib guarantees on every
// platform (builtin table or our explicit cases); host /etc/mime.types may
// add more, never remove these.
func TestExtFor(t *testing.T) {
	cases := []struct{ mimeType, want string }{
		{"image/jpeg", ".jpg"},
		{"image/png", ".png"},
		{"image/webp", ".webp"},
		{"audio/ogg", ".ogg"},
		{"audio/opus", ".ogg"},
		{"audio/mpeg", ".mp3"},
		{"application/pdf", ".pdf"},
		{"text/html", ".html"},
		{"text/plain", ".txt"},
		{"APPLICATION/PDF", ".pdf"},
		{"", ".bin"},
		{"application/octet-stream", ".bin"},
		{"application/x-never-a-real-type", ".bin"},
	}
	for _, c := range cases {
		if got := extFor(c.mimeType); got != c.want {
			t.Errorf("extFor(%q) = %q, want %q", c.mimeType, got, c.want)
		}
	}
}
