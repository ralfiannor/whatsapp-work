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

/// Scroll-position trigger for older-message paging.
///
/// macOS SwiftUI `List` does not fire `onAppear` for an offscreen top-sentinel
/// row when the user scrolls up (verified live 2026-09-05: the sentinel's
/// `onAppear` never executed even with the viewport parked at the very top),
/// so the sentinel-based trigger never requested page 2. This monitor observes
/// the enclosing `NSScrollView`'s clip-view offset directly and reports the
/// false→true transition into "at top".
struct TopPagingMonitor: NSViewRepresentable {
    var onReachTop: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onReachTop = onReachTop
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onReachTop = onReachTop
    }

    final class ProbeView: NSView {
        var onReachTop: () -> Void = {}

        private var observedClip: NSClipView?
        private var isAtTop = false
        /// Stays false until the first non-top observation: suppresses firing
        /// during the initial layout pass that precedes the open-chat
        /// scroll-to-bottom (the clip view can briefly sit at offset 0).
        private var hasSeenScrolledAway = false
        /// Re-anchor arm: the document height when the last page fired. When
        /// history prepends (height grows) the clip jumps to the equivalent
        /// offset — the row the reader was on stays put, and the next
        /// scroll-up has offset room to fire again. Without this the offset
        /// stays pinned at the top and no bounds change ever re-triggers.
        private var docHeightAtFire: CGFloat?
        private var armed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { attach() } else { detach() }
        }

        private func attach() {
            guard observedClip == nil,
                  let clip = enclosingScrollView?.contentView as? NSClipView else { return }
            clip.postsBoundsChangedNotifications = true
            observedClip = clip
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipBoundsChanged),
                name: NSClipView.boundsDidChangeNotification, object: clip)
        }

        private func detach() {
            guard let clip = observedClip else { return }
            NotificationCenter.default.removeObserver(
                self, name: NSClipView.boundsDidChangeNotification, object: clip)
            observedClip = nil
        }

        private var docHeight: CGFloat {
            observedClip?.documentView?.frame.height ?? 0
        }

        @objc private func clipBoundsChanged() {
            guard let clip = observedClip else { return }

            if armed, let heightAtFire = docHeightAtFire {
                let height = docHeight
                if height > heightAtFire {
                    // New older rows prepended: shift to the equivalent
                    // position so the reader's row stays visually fixed.
                    clip.scroll(to: NSPoint(x: 0, y: height - heightAtFire))
                }
                armed = false
                docHeightAtFire = nil
                isAtTop = false
                return
            }

            guard clip.bounds.minY <= TopPagingThreshold.atTopBound(visibleHeight: clip.visibleRect.height) else {
                hasSeenScrolledAway = true
                isAtTop = false
                return
            }
            if !isAtTop, hasSeenScrolledAway {
                isAtTop = true
                armed = true
                docHeightAtFire = docHeight
                onReachTop()
            }
        }
    }
}
