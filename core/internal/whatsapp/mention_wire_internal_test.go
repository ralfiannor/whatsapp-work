package whatsapp

import (
	"context"
	"database/sql"
	"testing"

	"go.mau.fi/whatsmeow"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	wlog "go.mau.fi/whatsmeow/util/log"

	_ "modernc.org/sqlite"
)

// LID-space groups must carry mentions as @lid; old-format groups and
// unknown twins pass through untouched.
func TestMentionJIDsForWire(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:?_pragma=foreign_keys(ON)")
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	container := sqlstore.NewWithDB(db, "sqlite", wlog.Noop)
	ctx := context.Background()
	if err := container.Upgrade(ctx); err != nil {
		t.Fatal(err)
	}
	dev, err := container.GetFirstDevice(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if dev.LIDs == nil { // fresh empty store: wire the lid map by hand
		dev.LIDs = container.LIDMap
	}
	lid := types.NewJID("170000000000001", types.HiddenUserServer)
	pn := types.NewJID("6285111000001", types.DefaultUserServer)
	if err := dev.LIDs.PutLIDMapping(ctx, lid, pn); err != nil {
		t.Fatal(err)
	}
	c := &Client{cli: whatsmeow.NewClient(dev, wlog.Noop)}

	// LID-space group (new-format JID with dash): known PN maps to its LID,
	// unknown JIDs pass through.
	lidGroup := types.NewJID("6285222000002-1589438461", types.GroupServer)
	got := c.mentionJIDsForWire(lidGroup, []string{pn.String(), "4999999999999@s.whatsapp.net"})
	if len(got) != 2 || got[0] != lid.ToNonAD().String() || got[1] != "4999999999999@s.whatsapp.net" {
		t.Fatalf("lid-space mapping = %v", got)
	}

	// Old-format group and direct chats: untouched.
	oldGroup := types.NewJID("1203630abcdef", types.GroupServer)
	got = c.mentionJIDsForWire(oldGroup, []string{pn.String()})
	if len(got) != 1 || got[0] != pn.String() {
		t.Fatalf("old-format group should pass through, got %v", got)
	}
	direct := types.NewJID("6285111000001", types.DefaultUserServer)
	got = c.mentionJIDsForWire(direct, []string{pn.String()})
	if len(got) != 1 || got[0] != pn.String() {
		t.Fatalf("direct chat should pass through, got %v", got)
	}

	// An already-LID mention must not be double-mapped.
	got = c.mentionJIDsForWire(lidGroup, []string{lid.String()})
	if len(got) != 1 || got[0] != lid.ToNonAD().String() {
		t.Fatalf("lid mention mangled: %v", got)
	}
}
