package storage_test

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/core"
	"github.com/ralfiannor/whatsapp-work/internal/storage"
)

// benchFixtureSize controls the search/page fixture size (WW_BENCH_N to
// override; the performance record in docs/performance.md uses 150k).
func benchFixtureSize() int {
	if n, err := strconv.Atoi(os.Getenv("WW_BENCH_N")); err == nil && n > 0 {
		return n
	}
	return 50_000
}

func seedBenchFixture(b *testing.B) (*storage.Store, string) {
	b.Helper()
	st := openTestStore(b)
	ctx := context.Background()
	jid := "bench@s.whatsapp.net"
	if err := st.EnsureChat(ctx, core.Chat{JID: jid, Kind: core.KindDirect, DisplayName: "Bench"}); err != nil {
		b.Fatal(err)
	}
	n := benchFixtureSize()
	const chunk = 500
	var buf []core.Message
	for i := 0; i < n; i++ {
		text := fmt.Sprintf("message %d about %s plans", i, fillerWord(i))
		if i%100 == 0 { // ~1% hit rate: realistic search selectivity
			text = fmt.Sprintf("message %d about deployment staging failures", i)
		}
		buf = append(buf, core.Message{
			MessageID: fmt.Sprintf("b%d", i), ChatJID: jid, SenderJID: jid,
			Timestamp: int64(1_700_000_000 + i), Kind: core.KindText,
			Text:   text,
			Source: "history", MentionedJIDs: []string{},
		})
		if len(buf) == chunk {
			if _, err := st.InsertMessages(ctx, buf); err != nil {
				b.Fatal(err)
			}
			buf = buf[:0]
		}
	}
	if len(buf) > 0 {
		if _, err := st.InsertMessages(ctx, buf); err != nil {
			b.Fatal(err)
		}
	}
	return st, jid
}

// fillerWord cycles unrelated vocabulary so FTS match lists stay selective.
func fillerWord(i int) string {
	words := []string{"lunch", "weekend", "design", "invoice", "meeting", "travel", "reading", "music", "weather", "family"}
	return words[i%len(words)]
}

// BenchmarkInsertMessagesBatch measures bulk history ingest throughput
// (rows/sec incl. FTS trigger + preview updates).
func BenchmarkInsertMessagesBatch(b *testing.B) {
	st, jid := seedBenchFixture(b)
	ctx := context.Background()
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		var buf []core.Message
		for j := 0; j < 500; j++ {
			buf = append(buf, core.Message{
				MessageID: fmt.Sprintf("x%d-%d", i, j), ChatJID: jid, SenderJID: jid,
				Timestamp: int64(1_800_000_000 + i*1000 + j), Kind: core.KindText,
				Text: "bench insert row", Source: "history", MentionedJIDs: []string{},
			})
		}
		if _, err := st.InsertMessages(ctx, buf); err != nil {
			b.Fatal(err)
		}
	}
	b.StopTimer()
	b.ReportMetric(float64(b.N*500)/b.Elapsed().Seconds(), "rows/s")
}

// BenchmarkInsertMessagesRedeliver measures re-ingesting rows we already
// hold — every row of a login's full history re-sync takes this path.
func BenchmarkInsertMessagesRedeliver(b *testing.B) {
	st, jid := seedBenchFixture(b)
	ctx := context.Background()
	n := benchFixtureSize()
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		var buf []core.Message
		for j := 0; j < 500; j++ {
			k := (i*500 + j) % n
			buf = append(buf, core.Message{
				MessageID: fmt.Sprintf("b%d", k), ChatJID: jid, SenderJID: jid,
				Timestamp: int64(1_700_000_000 + k), Kind: core.KindText,
				Text: fmt.Sprintf("message %d about %s plans", k, fillerWord(k)),
				Source: "history", MentionedJIDs: []string{},
			})
		}
		if _, err := st.InsertMessages(ctx, buf); err != nil {
			b.Fatal(err)
		}
	}
	b.StopTimer()
	b.ReportMetric(float64(b.N*500)/b.Elapsed().Seconds(), "rows/s")
}

// BenchmarkListMessagesPage is the chat-switch storage cost (page 1, 50 rows).
func BenchmarkListMessagesPage(b *testing.B) {
	st, jid := seedBenchFixture(b)
	ctx := context.Background()
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := st.ListMessages(ctx, jid, 0, 0, 50); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkSearchFTS is the ⌘K search cost over the fixture.
func BenchmarkSearchFTS(b *testing.B) {
	st, _ := seedBenchFixture(b)
	ctx := context.Background()
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		hits, err := st.SearchMessages(ctx, "deployment staging", 25)
		if err != nil || len(hits) == 0 {
			b.Fatalf("hits=%d err=%v", len(hits), err)
		}
	}
}

// BenchmarkChatsPage is the chat-list query cost.
func BenchmarkChatsPage(b *testing.B) {
	st, _ := seedBenchFixture(b)
	ctx := context.Background()
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := st.ListChats(ctx, 50, 0, "", storage.FilterAll); err != nil {
			b.Fatal(err)
		}
	}
}

// BenchmarkInbox is the /inbox refetch cost on a live-traffic fixture
// shaped like a real account: most incoming traffic lands in groups that
// are NOT marked Work (never inbox items), the rest in DMs and one work
// group.
func BenchmarkInbox(b *testing.B) {
	st := openTestStore(b)
	ctx := context.Background()
	n := benchFixtureSize()
	chats := []core.Chat{{JID: "work@g.us", Kind: core.KindGroup, DisplayName: "Work"}}
	for i := 0; i < 20; i++ {
		chats = append(chats, core.Chat{JID: fmt.Sprintf("noise%d@g.us", i), Kind: core.KindGroup})
	}
	for i := 0; i < 30; i++ {
		chats = append(chats, core.Chat{JID: fmt.Sprintf("2547%08d@s.whatsapp.net", i), Kind: core.KindDirect})
	}
	for _, c := range chats {
		if err := st.EnsureChat(ctx, c); err != nil {
			b.Fatal(err)
		}
	}
	if err := st.SetChatWork(ctx, "work@g.us", true); err != nil {
		b.Fatal(err)
	}
	base := time.Now().Unix() - int64(n)
	var buf []core.Message
	for i := 0; i < n; i++ {
		var jid string
		switch {
		case i%100 < 96:
			jid = fmt.Sprintf("noise%d@g.us", i%20)
		case i%100 < 99:
			jid = fmt.Sprintf("2547%08d@s.whatsapp.net", i%30)
		default:
			jid = "work@g.us"
		}
		buf = append(buf, core.Message{
			MessageID: fmt.Sprintf("l%d", i), ChatJID: jid, SenderJID: "254700000001@s.whatsapp.net",
			Timestamp: base + int64(i), Kind: core.KindText, Text: "live chatter",
			Source: "live", MentionedJIDs: []string{},
		})
		if len(buf) == 500 {
			if _, err := st.InsertMessages(ctx, buf); err != nil {
				b.Fatal(err)
			}
			buf = buf[:0]
		}
	}
	if len(buf) > 0 {
		if _, err := st.InsertMessages(ctx, buf); err != nil {
			b.Fatal(err)
		}
	}
	now := time.Now().Unix()
	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		if _, err := st.Inbox(ctx, now, 100); err != nil {
			b.Fatal(err)
		}
	}
}
