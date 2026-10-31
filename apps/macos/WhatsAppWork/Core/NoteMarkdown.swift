// Line-based Markdown block parser for local notes. Foundation renders the
// inline syntax (bold, italic, code, strikethrough, links); this only splits
// blocks. It is line-based on purpose: every list item keeps its source
// line, so a preview checkbox toggles exactly the "[ ]" it came from, and a
// single newline stays a line break (notes are typed line by line — strict
// Markdown would fold "call A\nemail B" into one sentence).
import Foundation

enum NoteMarkdown {
    enum ListMarker: Equatable {
        case bullet
        /// The number as typed ("3." / "3)"), not renumbered.
        case ordered(String)
        case task(done: Bool)
    }

    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(depth: Int, marker: ListMarker, text: String, line: Int)
        case quote(String)
        case code(String)
        case rule
        case table(header: [String], rows: [[String]])
    }

    static func blocks(_ source: String) -> [Block] {
        let lines = sourceLines(source).map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        var out: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        /// Indent columns of the open list levels: 2- and 4-space nesting
        /// styles both map to depth 1, 2, …
        var listIndents: [Int] = []

        func flushText() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))) }
            paragraph = []
            quote = []
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushText()
                listIndents = []
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                out.append(.code(code.joined(separator: "\n")))
                i += 1 // closing fence (an unclosed fence runs to the end)
                continue
            }
            if trimmed.isEmpty {
                flushText()
                i += 1
                continue
            }
            if !isRule(trimmed), let item = listItem(line) {
                flushText()
                let depth = depth(forIndent: item.indent, in: &listIndents)
                out.append(.listItem(depth: depth, marker: item.marker, text: item.text, line: i))
                i += 1
                continue
            }
            listIndents = []
            if let heading = heading(trimmed) {
                flushText()
                out.append(heading)
            } else if isRule(trimmed) {
                flushText()
                out.append(.rule)
            } else if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty { flushText() }
                var content = trimmed.dropFirst()
                if content.first == " " { content = content.dropFirst() }
                quote.append(String(content))
            } else if i + 1 < lines.count, trimmed.contains("|"), isTableSeparator(lines[i + 1]) {
                flushText()
                let header = tableCells(trimmed)
                var rows: [[String]] = []
                i += 2
                while i < lines.count {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(normalized(tableCells(row), count: header.count))
                    i += 1
                }
                out.append(.table(header: header, rows: rows))
                continue
            } else {
                if !quote.isEmpty { flushText() }
                paragraph.append(trimmed)
            }
            i += 1
        }
        flushText()
        return out
    }

    /// The source with list item `line`'s checkbox flipped, or nil when that
    /// line is not a task item. Everything else round-trips byte for byte.
    static func togglingTask(in source: String, line: Int) -> String? {
        var lines = sourceLines(source)
        guard lines.indices.contains(line),
              let item = listItem(lines[line]),
              case .task(let done) = item.marker else { return nil }
        let boxes = done ? ["[x]", "[X]"] : ["[ ]"]
        guard let range = boxes.lazy.compactMap({ lines[line].range(of: $0) }).first else { return nil }
        lines[line].replaceSubrange(range, with: done ? "[ ]" : "[x]")
        return lines.joined(separator: "\n")
    }

    /// Notes.app convention: the first non-empty line is the title.
    static func title(of body: String) -> String {
        summaryLines(body).first ?? "New Note"
    }

    /// The line under the title, for the list row's second line.
    static func preview(of body: String) -> String {
        let lines = summaryLines(body)
        return lines.count > 1 ? lines[1] : ""
    }

    /// Inline Markdown (bold, italic, `code`, ~~strike~~, links) as Foundation
    /// parses it; falls back to the literal text if parsing fails.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    // MARK: - parsing helpers

    /// Shared by `blocks` and `togglingTask`: both must agree on line numbers.
    private static func sourceLines(_ source: String) -> [String] {
        source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func summaryLines(_ body: String) -> [String] {
        var out: [String] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let plain = plainText(String(raw))
            if !plain.isEmpty { out.append(plain) }
            if out.count == 2 { break }
        }
        return out
    }

    /// A source line without block markers or inline syntax.
    private static func plainText(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("```") || text.hasPrefix("~~~") || isRule(text) || isTableSeparator(text) {
            return ""
        }
        if let item = listItem(text) {
            text = item.text
        } else if case .heading(_, let heading)? = heading(text) {
            text = heading
        } else {
            while text.hasPrefix(">") { text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces) }
        }
        return String(inline(text).characters).trimmingCharacters(in: .whitespaces)
    }

    private static func heading(_ trimmed: String) -> Block? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil } // "#tag" is text
        return .heading(level: hashes, text: rest.trimmingCharacters(in: .whitespaces))
    }

    /// "---", "***", "___" (spaces allowed between).
    private static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private struct ParsedItem {
        let indent: Int
        let marker: ListMarker
        let text: String
    }

    private static func listItem(_ line: String) -> ParsedItem? {
        var indent = 0
        var rest = Substring(line)
        while let c = rest.first, c == " " || c == "\t" {
            indent += c == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        var marker: ListMarker
        if let c = rest.first, "-*+".contains(c), rest.dropFirst().first == " " {
            marker = .bullet
            rest = rest.dropFirst(2)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let after = rest.dropFirst(digits.count)
            guard (1...9).contains(digits.count), let delim = after.first, delim == "." || delim == ")",
                  after.dropFirst().first == " " else { return nil }
            marker = .ordered(String(digits) + String(delim))
            rest = after.dropFirst(2)
        }
        if marker == .bullet {
            for (box, done) in [("[ ]", false), ("[x]", true), ("[X]", true)] where rest.hasPrefix(box) {
                let after = rest.dropFirst(3)
                if after.isEmpty || after.first == " " {
                    marker = .task(done: done)
                    rest = after
                }
                break
            }
        }
        return ParsedItem(indent: indent, marker: marker,
                          text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func depth(forIndent indent: Int, in levels: inout [Int]) -> Int {
        while let last = levels.last, indent < last { levels.removeLast() }
        if let last = levels.last, indent == last { return levels.count - 1 }
        levels.append(indent)
        return levels.count - 1
    }

    /// "| --- | :-: |" — dashes with optional alignment colons per cell.
    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        return tableCells(trimmed).allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func tableCells(_ trimmed: String) -> [String] {
        var row = Substring(trimmed)
        if row.hasPrefix("|") { row = row.dropFirst() }
        if row.hasSuffix("|") { row = row.dropLast() }
        return row.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func normalized(_ cells: [String], count: Int) -> [String] {
        cells.count >= count
            ? Array(cells.prefix(count))
            : cells + Array(repeating: "", count: count - cells.count)
    }
}
