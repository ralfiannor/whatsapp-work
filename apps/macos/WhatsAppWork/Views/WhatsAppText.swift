// WhatsApp text formatting renderer: *bold*, _italic_, ~strike~, `mono`,
// ```block``` and inline links — zero dependencies, single-pass tokenizer.
import SwiftUI

enum WAToken: Equatable {
    case plain(String)
    case bold(String)
    case italic(String)
    case strike(String)
    case mono(String)

    var text: String {
        switch self {
        case .plain(let s), .bold(let s), .italic(let s),
             .strike(let s), .mono(let s):
            return s
        }
    }
}

func parseWhatsApp(_ raw: String) -> [WAToken] {
    var tokens: [WAToken] = []
    let chars = Array(raw)
    var plain = ""
    var i = 0

    func flush() {
        if !plain.isEmpty { tokens.append(.plain(plain)); plain = "" }
    }

    func take(delimiter: Character, kind: (String) -> WAToken) -> Bool {
        // marker must open (not at end) and close before string end
        guard i + 1 < chars.count else { return false }
        var j = i + 1
        var body = ""
        while j < chars.count {
            if chars[j] == delimiter {
                if !body.isEmpty {
                    flush()
                    tokens.append(kind(body))
                    i = j + 1
                    return true
                }
                return false // empty ** → literal
            }
            body.append(chars[j])
            j += 1
        }
        return false // no closer → literal
    }

    while i < chars.count {
        let c = chars[i]
        var handled = true
        switch c {
        case "*": handled = take(delimiter: "*") { .bold($0) }
        case "_": handled = take(delimiter: "_") { .italic($0) }
        case "~": handled = take(delimiter: "~") { .strike($0) }
        case "`": handled = take(delimiter: "`") { .mono($0) }
        default: handled = false
        }
        if handled { continue }
        plain.append(c)
        i += 1
    }
    flush()
    return tokens
}

/// Renders message body text with WhatsApp formatting and clickable links.
///
/// Perf: NSDataDetector init is expensive (regex + locale data) and List
/// re-evaluates row bodies constantly while scrolling — so the detector is
/// a process-wide singleton and rendered strings are memoized by text.
enum MessageTextRenderer {
    static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
}

// MARK: - mIRC-style line rendering

/// Stable nick color from a JID — mIRC's per-user palette behavior.
enum IRCPalette {
    static func nickColor(_ jid: String) -> Color {
        // Classic mIRC 16-color set, thinned to entries readable on both
        // light and dark backgrounds.
        let palette: [Color] = [
            Color(red: 0.75, green: 0.20, blue: 0.20), // red
            Color(red: 0.20, green: 0.45, blue: 0.75), // blue
            Color(red: 0.20, green: 0.55, blue: 0.30), // green
            Color(red: 0.70, green: 0.45, blue: 0.10), // brown/orange
            Color(red: 0.55, green: 0.30, blue: 0.70), // purple
            Color(red: 0.15, green: 0.55, blue: 0.60), // teal
            Color(red: 0.75, green: 0.35, blue: 0.55), // pink
            Color(red: 0.45, green: 0.45, blue: 0.50), // slate
        ]
        var h: UInt64 = 5381
        for b in jid.utf8 {
            h = (h << 5) &+ h &+ UInt64(b)
        }
        return palette[Int(h % UInt64(palette.count))]
    }
}

/// One flat IRC line: `[HH:MM] <nick> body…` in attributed runs. Rendered
/// with SwiftUI Text only for fast List scrolling on Intel. Links remain
/// clickable without a pointing-hand cursor; formatting, mentions, receipt
/// marks, contact-name changes, and font size participate in rendering/cache.
struct IRCLineText: View {
    let message: Message
    var fontSize: Double = 12.5

    private static var cache: [String: AttributedString] = [:]
    private static let cacheLimit = 800
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func timeString(_ ts: Int64) -> String {
        tsFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
            .font(.system(size: fontSize, weight: .regular, design: .monospaced))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        // v9 key: includes the contact-name version and the font size —
        // both re-shape the attributed string (mentions re-resolve after
        // contacts load; typography changes re-style every run) — plus the
        // forwarded flag, which adds a leading marker run.
        let key = "v9|\(fontSize)|\(message.forwarded ?? false)|\(message.id)|\(message.text ?? "")|\(message.edited_ts ?? 0)|\(message.revoked ? 1 : 0)|\(message.reactions?.count ?? 0)|\(message.receipt_status ?? "")|\(state.contactNamesVersion)"
        if let hit = Self.cache[key] {
            return hit
        }
        let value = Self.render(message: message, ownPart: ownUserPart,
                                bodyOverride: resolveMentionLabels(),
                                mentionLabels: resolvedMentionLabels,
                                fontSize: fontSize)
        if Self.cache.count >= Self.cacheLimit {
            Self.cache.removeAll(keepingCapacity: true)
        }
        Self.cache[key] = value
        return value
    }

    /// The "@Name" tokens that are REAL mentions for this message (from
    /// mentioned_jids, resolved through local names). Masked/unknown names
    /// are excluded — coloring "@+254…" would just be noise.
    private var resolvedMentionLabels: Set<String> {
        guard let mentioned = message.mentioned_jids, !mentioned.isEmpty else { return [] }
        var out: Set<String> = []
        for jid in mentioned {
            let name = state.nameFor(jid)
            if !name.isEmpty && !name.hasPrefix("+") && !name.hasPrefix("•••") {
                out.insert("@" + name)
            }
        }
        return out
    }

    /// Incoming mentions in LID groups arrive as raw numeric tokens in the
    /// text ("@170000000000001", "@+254…") while MentionedJIDs carries the
    /// real JIDs. Rewrite ONLY numeric tokens (paired in order with the
    /// mention list) to the local name. Display labels that already follow
    /// the "@" — including multi-word names — are left untouched: the old
    /// space-delimited-token logic mangled them ("@Annie" → "@Annie Rose 👻"
    /// and doubled the rest of the label).
    private func resolveMentionLabels() -> String? {
        guard let mentioned = message.mentioned_jids, !mentioned.isEmpty,
              let text = message.text, text.contains("@") else { return nil }
        var out = ""
        var cursor = text.startIndex
        var idx = 0
        var matched = false
        while let r = text.range(of: "@[0-9]{5,}", options: .regularExpression,
                                 range: cursor..<text.endIndex) {
            matched = true
            let name = idx < mentioned.count ? state.nameFor(mentioned[idx]) : ""
            idx += 1
            out += text[cursor..<r.lowerBound]
            let real = !name.isEmpty && !name.hasPrefix("+") && !name.hasPrefix("•••")
            out += real ? "@" + name : String(text[r])
            cursor = r.upperBound
        }
        guard matched else { return nil }
        out += text[cursor...]
        return out == text ? nil : out
    }

    @EnvironmentObject private var state: AppState
    private var ownUserPart: String {
        guard let jid = state.ownJID else { return "" }
        return String(jid.prefix(while: { $0 != "@" }))
    }

    private static let mentionRE = try? NSRegularExpression(pattern: "@[A-Za-z0-9_]{4,}")

    /// Splits a string into alternating non-link / link pieces; every URL the
    /// detector finds becomes clickable, even mid-sentence.
    static func linkPieces(_ text: String) -> [(String, URL?)] {
        guard let detector = MessageTextRenderer.linkDetector else { return [(text, nil)] }
        let full = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: full).filter { $0.url != nil }
        guard !matches.isEmpty else { return [(text, nil)] }
        var out: [(String, URL?)] = []
        var cursor = text.startIndex
        for m in matches {
            guard let r = Range(m.range, in: text), r.lowerBound >= cursor else { continue }
            if cursor < r.lowerBound {
                out.append((String(text[cursor..<r.lowerBound]), nil))
            }
            out.append((String(text[r]), m.url))
            cursor = r.upperBound
        }
        if cursor < text.endIndex {
            out.append((String(text[cursor...]), nil))
        }
        return out
    }

    /// Colors @mention tokens that map to the message's real mentioned JIDs
    /// (plus your own number's token). Spans are matched against the FULL
    /// display labels (multi-word included — a word-character regex never
    /// matched "@Annie Rose 👻"), longest-first so "@Anna" wins over "@Ann",
    /// with word boundaries so emails/domains stay plain.
    static func mentionStyled(_ text: String, ownPart: String, labels: Set<String>,
                              fontSize: Double = 12.5) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(text) }
        var needles = labels
        if !ownPart.isEmpty {
            needles.insert("@" + ownPart)
        }
        let ordered = needles.filter { $0.count > 1 }.sorted { $0.count > $1.count }
        guard !ordered.isEmpty else { return AttributedString(text) }
        let escaped = needles.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard let re = try? NSRegularExpression(
            pattern: "(?<![\\w@])(\(escaped))(?![\\w])") else {
            return AttributedString(text)
        }
        let ns = text as NSString
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return AttributedString(text) }

        var out = AttributedString()
        var cursor = 0
        for m in matches {
            guard let r = Range(m.range, in: text), r.lowerBound.utf16Offset(in: text) >= cursor else { continue }
            let lo = r.lowerBound.utf16Offset(in: text)
            if lo > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: lo - cursor)))
            }
            let token = String(text[r])
            var run = AttributedString(token)
            let isOwn = ownPart != "" && token == "@" + ownPart
            run.foregroundColor = isOwn ? Color(red: 0.95, green: 0.65, blue: 0.10) : mentionColor
            run.font = .system(size: fontSize, weight: .bold, design: .monospaced)
            out += run
            cursor = r.upperBound.utf16Offset(in: text)
        }
        if cursor < ns.length {
            out += AttributedString(ns.substring(from: cursor))
        }
        return out
    }

    static func render(message: Message, ownPart: String, bodyOverride: String? = nil,
                       mentionLabels: Set<String> = [], fontSize: Double = 12.5) -> AttributedString {
        var out = AttributedString()
        // Forwarded marker: a quiet ↪ glyph, same convention as the quote
        // arrow — text marker first (a11y: never color/glyph alone). Hidden
        // on revoked rows, which already say «deleted».
        if message.forwarded == true && !message.revoked {
            var mark = AttributedString("↪ ")
            mark.foregroundColor = .secondary
            mark.font = .system(size: fontSize - 1.5, weight: .semibold, design: .monospaced)
            out += mark
        }
        for token in parseWhatsApp(bodyOverride ?? bodyText(message)) {
            for (piece, url) in linkPieces(token.text) {
                var segment = AttributedString(piece)
                switch token {
                case .plain: break
                case .bold: segment.font = .system(size: fontSize, weight: .bold, design: .monospaced)
                case .italic: segment.font = .system(size: fontSize, weight: .regular, design: .monospaced).italic()
                case .strike: segment.strikethroughStyle = .single
                case .mono:
                    segment.font = .system(size: fontSize, design: .monospaced)
                    // Inline code must be distinguishable from plain text
                    // (both are monospaced here) — a flat wash, no card.
                    segment.backgroundColor = Color.primary.opacity(0.07)
                }
                if let url {
                    segment.link = url
                    segment.foregroundColor = linkColor
                    segment.underlineStyle = .single
                    out += segment
                } else {
                    // Keep the fix: the token format must also apply to the
                    // mention-styled result, or bold/strike never rendered.
                    var styled = mentionStyled(piece, ownPart: ownPart,
                                               labels: mentionLabels, fontSize: fontSize)
                    applyFormat(token, to: &styled, fontSize: fontSize)
                    out += styled
                }
            }
        }

        // suffixes: edited, revoked — inline tail. Receipts render inline
        // too, except failed, which gets its own actionable line in the row.
        var suffix = ""
        if message.revoked {
            suffix += "  «deleted»"
        } else if (message.edited_ts ?? 0) > 0 {
            suffix += "  (edited)"
        }
        if !suffix.isEmpty {
            var run = AttributedString(suffix)
            run.foregroundColor = .secondary
            run.font = .system(size: fontSize - 1.5, design: .monospaced)
            out += run
        }
        if message.from_me, message.receipt_status != "failed" {
            out += receiptRun(message, fontSize: fontSize)
        }
        return out
    }

    /// WhatsApp-familiar marks: ✓ sent · ✓✓ delivered · accent ✓✓ read.
    /// Read gets color AND a distinct position at line end (not shape alone).
    private static func receiptRun(_ m: Message, fontSize: Double) -> AttributedString {
        let mark: String
        switch m.receipt_status {
        case "delivered", "read": mark = "✓✓"
        case "pending": mark = "…"
        default: mark = "✓" // sent
        }
        var run = AttributedString("  " + mark)
        run.foregroundColor = m.receipt_status == "read" ? readColor : Color.secondary
        run.font = .system(size: fontSize - 1.5, design: .monospaced)
        return run
    }

    /// Token format applied on top of mention-styled runs (fix companion).
    private static func applyFormat(_ token: WAToken, to s: inout AttributedString, fontSize: Double) {
        switch token {
        case .plain: break
        case .bold: s.font = .system(size: fontSize, weight: .bold, design: .monospaced)
        case .italic: s.font = .system(size: fontSize, weight: .regular, design: .monospaced).italic()
        case .strike:
            s.strikethroughStyle = .single
        case .mono:
            s.font = .system(size: fontSize, design: .monospaced)
            s.backgroundColor = Color.primary.opacity(0.07)
        }
    }

    private static let linkColor = Color(red: 0.35, green: 0.65, blue: 0.95)
    private static let mentionColor = Color(red: 0.35, green: 0.65, blue: 0.95)
    private static let readColor = Color(red: 0.35, green: 0.65, blue: 0.95)

    /// Body text for the line. Media kinds render NO bracket placeholder:
    /// the row's MediaBubble already shows a thumbnail or a kind/size/file
    /// button — "[image]"/"[file: x]" above it was pure duplication. Captions
    /// still render as the line itself.
    private static func bodyText(_ m: Message) -> String {
        if m.revoked { return "" }
        switch m.kind {
        case "image", "video":
            return (m.text ?? "").trimmingCharacters(in: .whitespaces)
        case "audio", "sticker", "document":
            return ""
        default: return m.text ?? ""
        }
    }

}
