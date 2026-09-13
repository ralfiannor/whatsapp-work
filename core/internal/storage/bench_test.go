package storage_test

import (
	"context"
	"fmt"
	"os"
	"strconv"
	"testing"

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
