import AppKit
import SwiftUI

/// Where "at top" begins, as a fraction of the visible transcript height.
/// Preloading one viewport-quarter before the hard top is the standard
/// infinite-scroll feel, and it keeps the trigger working when a layout
/// (e.g. DM rows without the nick column) can never quite reach offset 0.
enum TopPagingThreshold {
    static func atTopBound(visibleHeight: CGFloat) -> CGFloat {
        max(2, visibleHeight * 0.25)
    }
}

/// Lets every transcript path that prepends older rows (scroll paging, the
/// Load Earlier button) keep the reader's place. The probe registers itself
/// here; the view calls `holdPositionForPrepend()` right after the older page
/// was merged into state — same main-actor turn, before SwiftUI lays the new
/// rows out.
@MainActor
final class TranscriptScrollBridge {
    fileprivate weak var probe: TopPagingMonitor.ProbeView?

    func holdPositionForPrepend() {
        probe?.holdBottomDistance()
    }
}

/// Scroll-position trigger for older-message paging.
///
/// macOS SwiftUI `List` does not fire `onAppear` for an offscreen top-sentinel
/// row when the user scrolls up, so this probe observes the List's
/// `NSScrollView` clip offset directly. SwiftUI hosts a `.background`
/// representable NEXT TO the List's scroll view, not inside it
/// (`enclosingScrollView` is nil on macOS 14), so the probe locates the
/// scroll view that occupies its own frame.
///
/// Level-triggered: any scroll inside the top region fetches a page unless
/// one is in flight; a fetch that brings nothing (start of history, failure)
/// parks the trigger until the reader leaves the top region.
struct TopPagingMonitor: NSViewRepresentable {
    /// The probe outlives chat switches (MessageList keeps its identity);
    /// a new chat re-arms the initial-layout guard.
    var chatJID: String
    var bridge: TranscriptScrollBridge
    /// Fetches one older page; true when rows were prepended.
    var onReachTop: @MainActor () async -> Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        update(view)
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        update(view)
    }

    private func update(_ view: ProbeView) {
        view.onReachTop = onReachTop
        bridge.probe = view
        if view.chatJID != chatJID {
            view.chatJID = chatJID
            view.resetForNewTranscript()
        }
        // The List's scroll view may not exist yet when the probe first
        // lands in the window; retry after this update pass.
        DispatchQueue.main.async { [weak view] in view?.attachIfNeeded() }
    }

    final class ProbeView: NSView {
        var onReachTop: @MainActor () async -> Bool = { false }
        var chatJID = ""

        private weak var observedClip: NSClipView?
        private weak var observedDocument: NSView?
        /// Stays false until the first non-top observation: suppresses firing
        /// during the initial layout pass that precedes the open-chat
        /// scroll-to-bottom (the clip view briefly sits at offset 0).
        private var hasSeenScrolledAway = false
        private var loading = false
        private var exhausted = false
        /// Distance from the viewport top to the document bottom, pinned
        /// while a prepended page lays out. Rows above the viewport grow the
        /// document; rows below it do not move, so keeping this distance
        /// keeps the row under the reader fixed. SwiftUI does not do this
        /// for List (verified: the offset stays put and the content jumps),
        /// and NSTableView settles row heights over several passes.
        private var heldBottomDistance: CGFloat?
        private var holdDeadline = Date.distantPast
        private var holdRelease: DispatchWorkItem?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { detach() } else { attachIfNeeded() }
        }

        func resetForNewTranscript() {
            hasSeenScrolledAway = false
            exhausted = false
            endHold()
        }

        func attachIfNeeded() {
            if let clip = observedClip, clip.window != nil, observedDocument != nil { return }
            detach()
            guard window != nil,
                  let scrollView = enclosingScrollView ?? siblingScrollView(),
                  let document = scrollView.documentView else { return }
            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            document.postsFrameChangedNotifications = true
            observedClip = clip
            observedDocument = document
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(
                self, selector: #selector(documentFrameChanged),
                name: NSView.frameDidChangeNotification, object: document)
        }

        private func detach() {
            NotificationCenter.default.removeObserver(self)
            observedClip = nil
            observedDocument = nil
            endHold()
        }

        /// The scroll view covering at least half of our frame, searched
        /// from the nearest ancestor outwards. Scroll views nested inside
        /// another scroll view (rows, text fields) are skipped.
        private func siblingScrollView() -> NSScrollView? {
            let mine = convert(bounds, to: nil)
            let myArea = mine.width * mine.height
            guard myArea > 0 else { return nil }
            var ancestor = superview
            while let container = ancestor {
                var best: (view: NSScrollView, overlap: CGFloat)?
                var stack = container.subviews
                while let view = stack.popLast() {
                    guard let scrollView = view as? NSScrollView else {
                        stack.append(contentsOf: view.subviews)
                        continue
                    }
                    let overlap = scrollView.convert(scrollView.bounds, to: nil).intersection(mine)
                    let area = overlap.isNull ? 0 : overlap.width * overlap.height
                    if area > (best?.overlap ?? 0) { best = (scrollView, area) }
                }
                if let best, best.overlap >= myArea / 2 { return best.view }
                ancestor = container.superview
            }
            return nil
        }

        private var documentHeight: CGFloat {
            observedDocument?.frame.height ?? 0
        }

        @objc private func clipBoundsChanged() {
            guard let clip = observedClip else { return }
            if heldBottomDistance != nil {
                // NSTableView re-anchors on its own while it measures the
                // new rows; keep overriding it until the layout settles.
                applyHold()
                return
            }
            let atTop = clip.bounds.minY <= TopPagingThreshold.atTopBound(visibleHeight: clip.bounds.height)
            guard atTop else {
                hasSeenScrolledAway = true
                exhausted = false
                return
            }
            guard hasSeenScrolledAway, !loading, !exhausted else { return }
            loading = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                let loaded = await self.onReachTop()
                self.loading = false
                if !loaded { self.exhausted = true }
            }
        }

        @objc private func documentFrameChanged() {
            guard heldBottomDistance != nil else { return }
            applyHold()
            scheduleHoldRelease()
        }

        func holdBottomDistance() {
            guard let clip = observedClip else { return }
            heldBottomDistance = documentHeight - clip.bounds.minY
            // Hard cap: a hold must never fight the reader's own scrolling
            // for longer than a layout pass or two.
            holdDeadline = Date().addingTimeInterval(1)
            scheduleHoldRelease()
        }

        private func applyHold() {
            guard let clip = observedClip, let held = heldBottomDistance else { return }
            let target = max(0, documentHeight - held)
            guard abs(clip.bounds.minY - target) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }

        /// Releases the hold once the document height stops changing.
        private func scheduleHoldRelease() {
            holdRelease?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.endHold() }
            holdRelease = item
            let delay = min(0.3, max(0, holdDeadline.timeIntervalSinceNow))
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }

        private func endHold() {
            holdRelease?.cancel()
            holdRelease = nil
            heldBottomDistance = nil
        }
    }
}
