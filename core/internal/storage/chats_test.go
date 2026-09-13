package storage_test

import (
	"context"
	"testing"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

func TestListChatsFallbackName(t *testing.T) {
	s := openTestStore(t)
	ctx := context.Background()
	// PSA chat with no stored name must render as "WhatsApp", not raw JID.
	if err := s.EnsureChat(ctx, core.Chat{JID: "0@s.whatsapp.net", Kind: core.KindDirect}); err != nil {
		t.Fatal(err)
	}
	chats, err := s.ListChats(ctx, 10, 0, "", storage.FilterAll)
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range chats {
		if c.JID == "0@s.whatsapp.net" && c.DisplayName != "WhatsApp" {
			t.Fatalf("PSA name = %q, want WhatsApp", c.DisplayName)
		}
	}
}
