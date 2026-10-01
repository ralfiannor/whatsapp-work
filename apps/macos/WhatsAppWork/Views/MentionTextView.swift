import AppKit
import SwiftUI

/// Pure mention-range finder: the SAME token-boundary rules the send path
/// (`AppState.containsMentionToken` → `deliver`) uses, so what the composer
/// colors is exactly what goes onto the wire as a mention.
enum MentionTokenMatcher {
    static func matchedRanges(text: String, labels: [String]) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for label in labels where !label.isEmpty {
            var searchStart = text.startIndex
            while let r = text.range(of: "@\(label)", range: searchStart..<text.endIndex) {
                let afterOK = r.upperBound == text.endIndex || !isWordChar(text[r.upperBound])
                // `index(before:)` is only valid when the match is NOT at the
                // string's start — evaluating it eagerly crashed in Release.
                let beforeOK = r.lowerBound == text.startIndex
                    || !isWordChar(text[text.index(before: r.lowerBound)])
                if afterOK && beforeOK {
                    out.append(r)
                }
                searchStart = r.upperBound
            }
        }
        return out
    }

    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }
}

/// Composer input with colored mentions. ONE NSTextView for the composer —
/// the AGENTS.md rule bans AppKit text views per transcript ROW, and this
/// is not one. Resolved "@Label" tokens render in the accent color; any
/// other "@" text stays default-colored (unresolved, will not be sent as a
/// mention).
///
/// Sizing: a bare, vertically-resizable NSTextView reports an unbounded
/// fitting size to SwiftUI (the composer once rendered as a giant box), so
/// the text view lives in an NSScrollView and `sizeThatFits` returns a
/// content-hugging height clamped to a 1…5-line envelope — the scroll view
/// scrolls beyond five lines, matching the old TextField's
/// `lineLimit(1...5)`.
struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    var resolvedLabels: [String]
    var font: NSFont
    /// Runs before Enter is handled (mention popup accepts the first row);
    /// return true to consume.
    var enterInterceptor: () -> Bool
    var onEnter: () -> Void
    var onFocusChange: (Bool) -> Void
    /// Bump to focus the field (replaces @FocusState bridging).
    var focusRequest: Int

    /// Height envelope: one line min, ~five lines max (plus the outer
    /// .padding(6) applied by the composer — totals match the old field).
    private static let minHeight: CGFloat = 22
    private static let maxHeight: CGFloat = 84
    /// TextKit line-fragment padding (5 per side) — stripped from the
    /// measurement width so wrapping matches the laid-out text.
    private static let sideInset: CGFloat = 10

    func makeNSView(context: Context) -> NSScrollView {
        let tv = ComposerTextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.drawsBackground = false
        tv.isRichText = true
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.string = text
        tv.onFocus = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.onFocusChange(focused)
        }
        Self.recolor(tv, labels: resolvedLabels, font: font)
        context.coordinator.textView = tv
        context.coordinator.parent = self

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        return scroll
    }

    // Parameter must be the concrete NSViewType (NSScrollView) to witness
    // the protocol requirement; a supertype is not a valid witness.
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ComposerTextView else { return }
        if !context.coordinator.isEditing, tv.string != text {
            tv.string = text
        }
        tv.font = font
        Self.recolor(tv, labels: resolvedLabels, font: font)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            if let window = tv.window {
                window.makeFirstResponder(tv)
            }
        }
    }

    /// Content-hugging height at the proposed width: measure the plain
    /// one-font text (mention colors never affect metrics) and clamp into
    /// the 1…5-line envelope. This is what keeps the frame proportional.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        let width = proposal.width ?? nsView.bounds.width
        guard width.isFinite, width > 0 else { return nil }
        let attributed = NSAttributedString(
            string: text.isEmpty ? " " : text, attributes: [.font: font])
        let bounds = attributed.boundingRect(
            with: NSSize(width: max(width - Self.sideInset, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let height = min(max(ceil(bounds.height), Self.minHeight), Self.maxHeight)
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MentionTextView
        var isEditing = false
        var lastFocusRequest = 0
        weak var textView: NSTextView?

        init(_ parent: MentionTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = tv.string
            isEditing = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if parent.enterInterceptor() { return true }
                // Plain Return sends (old TextField onSubmit behavior);
                // ⌘/⌥ Return falls through and inserts a newline.
                let mods = NSApp.currentEvent?.modifierFlags
                    .intersection(.deviceIndependentFlagsMask) ?? []
                if mods.contains(.command) || mods.contains(.option) {
                    return false
                }
                parent.onEnter()
                return true
            }
            return false
        }
    }

    /// Full-sweep recolor: reset every attribute to the plain default,
    /// then accent-color resolved mention ranges. Cheap at composer size
    /// (≤5 lines); preserves selection because only attributes change.
    static func recolor(_ tv: NSTextView, labels: [String], font: NSFont) {
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let text = tv.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        tv.textStorage?.setAttributes(plain, range: full)
        for range in MentionTokenMatcher.matchedRanges(text: text, labels: labels) {
            tv.textStorage?.addAttribute(.foregroundColor, value: NSColor.controlAccentColor,
                                         range: NSRange(range, in: text))
        }
        tv.typingAttributes = plain
    }
}

/// NSTextView subclass that reports first-responder changes (focus in/out)
/// even when focus moves without ending the editing session.
final class ComposerTextView: NSTextView {
    var onFocus: ((Bool) -> Void)?

    /// ⌘A and ⌘/⌥ Return are handled here because key equivalents dispatch
    /// BEFORE keyDown: the send button owns the ⌘Return key equivalent, so
    /// without this a modified Return while composing would trigger the
    /// button (send) instead of inserting a newline. The SwiftUI-hosted
    /// text view is also not reliably on the replaced-menu responder path
    /// for ⌘A.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder == self else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers
        if key == "a", mods.contains(.command),
           !mods.contains(.option), !mods.contains(.control), !mods.contains(.shift) {
            selectAll(nil)
            return true
        }
        if key == "\r", mods.contains(.command) || mods.contains(.option),
           !mods.contains(.shift), !mods.contains(.control) {
            insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocus?(false) }
        return ok
    }
}
