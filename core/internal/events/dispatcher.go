// Package events implements the outbound fan-out dispatcher: the ingest
// pipeline persists first, then emits; subscribers (WS hub, notifications)
// receive buffered channels and never block ingest.
package events

import (
	"sync"
	"sync/atomic"
)

// Event is one outbound notification. Type is the wire name
// ("message.received", …); Data is a JSON-marshalable payload.
type Event struct {
	Type string
	Data any
}

// Dispatcher fans events out to subscribers.
//
// Emit is non-blocking by contract: a subscriber whose buffer is full has the
// event dropped (and counted). Events are hints — SQLite via REST is the
// source of truth — so dropping under backpressure is safe.
type Dispatcher struct {
	mu      sync.RWMutex
	subs    map[uint64]chan Event
	nextID  uint64
	dropped atomic.Uint64
}

func NewDispatcher() *Dispatcher {
	return &Dispatcher{subs: make(map[uint64]chan Event)}
}

// Subscribe registers a buffered channel. Cancel with Unsubscribe.
func (d *Dispatcher) Subscribe(buffer int) (id uint64, ch <-chan Event) {
	if buffer < 1 {
		buffer = 1
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.nextID++
	id = d.nextID
	chBuf := make(chan Event, buffer)
	d.subs[id] = chBuf
	return id, chBuf
}

// Unsubscribe removes a subscription. Safe to call twice.
func (d *Dispatcher) Unsubscribe(id uint64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if ch, ok := d.subs[id]; ok {
		delete(d.subs, id)
		close(ch)
	}
}

// Emit delivers ev to every current subscriber without blocking.
func (d *Dispatcher) Emit(ev Event) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	for _, ch := range d.subs {
		select {
		case ch <- ev:
		default:
			d.dropped.Add(1)
		}
	}
}

// Dropped returns the total number of events dropped across all subscribers.
func (d *Dispatcher) Dropped() uint64 { return d.dropped.Load() }
