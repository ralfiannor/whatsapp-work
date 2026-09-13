package app_test

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
)

// Search must match chat display names across ALL chats — a page-limited
// list made ⌘K blind to every chat older than the newest page.
func TestSearchMatchesOlderChats(t *testing.T) {
	a, fw, _, st := newTestApp(t)

	// >50 chats with traffic so a clamped implementation cannot see the
	// oldest one; the target is the very last chat created.
	target := "1203630999999999@g.us"
	for i := 0; i < 60; i++ {
		chat := fmt.Sprintf("2547010%02d@s.whatsapp.net", i)
		name := "Filler " + string(rune('A'+i%26))
		if i == 39 {
			chat = target
			name = "Zebralanche Workspace"
		}
		fw.push(core.EventChatUpsert{Chat: core.Chat{JID: chat, Kind: core.KindDirect, DisplayName: name}})
		fw.push(incomingMsg(fmt.Sprintf("search-m%d", i), chat, chat, fmt.Sprintf("msg %d", i)))
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		// Poll for the TARGET row specifically: counting pages races the
		// async ingest and can pass before the last chat lands.
		if _, err := st.GetChat(context.Background(), target); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("target chat not ingested in time")
		}
		time.Sleep(10 * time.Millisecond)
	}

	res, err := a.Search(context.Background(), "zebralanche", 25)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, c := range res.Chats {
		if c.JID == target {
			found = true
		}
	}
	if !found {
		t.Fatalf("search over all chats missed the older target chat; got %d chats", len(res.Chats))
	}
}
