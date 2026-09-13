// Package events provides a small typed fan-out dispatcher.
//
// Contract under test:
//   - Emit delivers events to every subscriber in emission order
//   - a slow subscriber never blocks Emit; its overflow is dropped and counted
//   - Unsubscribe is idempotent and stops delivery
package events_test

import (
	"testing"
	"time"

	"github.com/ralfiannor/whatsapp-work/internal/events"
)

func TestDispatcherDeliversInOrder(t *testing.T) {
	d := events.NewDispatcher()
	id, ch := d.Subscribe(16)
	defer d.Unsubscribe(id)

	for i := 0; i < 8; i++ {
		d.Emit(events.Event{Type: "tick", Data: i})
	}

	for i := 0; i < 8; i++ {
		select {
		case ev := <-ch:
			if ev.Type != "tick" {
				t.Fatalf("got type %q, want tick", ev.Type)
			}
			if ev.Data.(int) != i {
				t.Fatalf("out of order: got %d, want %d", ev.Data.(int), i)
			}
		case <-time.After(time.Second):
			t.Fatalf("timed out waiting for event %d", i)
		}
	}
	if d.Dropped() != 0 {
		t.Fatalf("dropped = %d, want 0", d.Dropped())
	}
}

func TestDispatcherDropsInsteadOfBlocking(t *testing.T) {
	d := events.NewDispatcher()
	id, ch := d.Subscribe(1) // tiny buffer on purpose
	defer d.Unsubscribe(id)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < 100; i++ {
			d.Emit(events.Event{Type: "tick", Data: i})
		}
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Emit blocked on a full subscriber channel")
	}

	if d.Dropped() < 90 {
		t.Fatalf("dropped = %d, want >= 90", d.Dropped())
	}
	// Whatever was delivered must be valid events.
	for ev := range ch {
		if ev.Type != "tick" {
			t.Fatalf("unexpected event type %q", ev.Type)
		}
		break
	}
}

func TestDispatcherUnsubscribeStopsDelivery(t *testing.T) {
	d := events.NewDispatcher()
	id, ch := d.Subscribe(4)
	d.Unsubscribe(id)
	d.Unsubscribe(id) // idempotent

	d.Emit(events.Event{Type: "tick"})
	select {
	case ev, ok := <-ch:
		if ok {
			t.Fatalf("received event after unsubscribe: %+v", ev)
		} // closed channel: zero value, no delivery — fine
	case <-time.After(50 * time.Millisecond):
	}
}

func TestDispatcherFanOut(t *testing.T) {
	d := events.NewDispatcher()
	id1, ch1 := d.Subscribe(4)
	id2, ch2 := d.Subscribe(4)
	defer d.Unsubscribe(id1)
	defer d.Unsubscribe(id2)

	d.Emit(events.Event{Type: "tick"})

	for _, ch := range []<-chan events.Event{ch1, ch2} {
		select {
		case <-ch:
		case <-time.After(time.Second):
			t.Fatal("subscriber did not receive the event")
		}
	}
}
