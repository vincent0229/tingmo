import AppKit
import Foundation

/// Writes a note as Markdown, Word (.docx) or PDF. Word and PDF go Markdown → HTML → the system's own text engine,
/// so nothing extra has to be installed.
enum NoteExporter {
    static func fileExtension(_ format: String) -> String { ["docx", "pdf"].contains(format) ? format : "md" }

    @MainActor static func write(_ markdown: String, to url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "docx":
            let a = try attributed(markdown, layout: .word)
            let data = try a.data(from: NSRange(location: 0, length: a.length),
                                  documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        case "pdf":
            try writePDF(try attributed(markdown, layout: .page), to: url)
        default:
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @MainActor private static func attributed(_ markdown: String, layout: MarkdownHTML.Layout) throws -> NSAttributedString {
        let html = MarkdownHTML.document(markdown, layout: layout)
        guard let a = NSMutableAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                                documentAttributes: nil) else { throw AppError("纪要排版失败") }
        tune(a)
        return a
    }

    /// The HTML importer sizes tables for an 800-point window and indents lists deeply; refit both to the page.
    private static func tune(_ a: NSMutableAttributedString) {
        var tableWidth: [ObjectIdentifier: CGFloat] = [:]
        var cells = Set<ObjectIdentifier>()
        a.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: a.length)) { value, range, _ in
            guard let old = value as? NSParagraphStyle else { return }
            for case let cell as NSTextTableBlock in old.textBlocks {
                let table = cell.table, key = ObjectIdentifier(table)
                if tableWidth[key] == nil {
                    tableWidth[key] = table.contentWidthValueType == .absoluteValueType ? table.contentWidth : 0
                    table.setContentWidth(100, type: .percentageValueType)
                }
                guard cells.insert(ObjectIdentifier(cell)).inserted else { continue }
                if table.numberOfColumns == 1 {
                    cell.setContentWidth(0, type: .absoluteValueType)      // a width of 0 means "take what is left": the full line
                    // space above goes here: a top margin written in CSS is also taken off the right-hand side
                    let ruled = cell.width(for: .border, edge: .minY) > 0
                    cell.setWidth(ruled ? 18 : 6, type: .absoluteValueType, for: .margin, edge: .minY)
                    if !ruled { cell.setWidth(8, type: .absoluteValueType, for: .margin, edge: .maxY) }
                } else if table.numberOfColumns == 2, cell.backgroundColor != nil, cell.width(for: .border, edge: .minY) == 0 {
                    // the details block: a label column just wide enough for four characters, the rest for the value
                    cell.setContentWidth(cell.startingColumn == 0 ? 46 : 0, type: .absoluteValueType)
                } else if let total = tableWidth[key], total > 0, cell.contentWidthValueType == .absoluteValueType, cell.contentWidth > 0 {
                    cell.setContentWidth(min(100, cell.contentWidth / total * 100), type: .percentageValueType)
                }
            }
            if !old.textLists.isEmpty, let p = old.mutableCopy() as? NSMutableParagraphStyle {
                let indent = CGFloat(old.textLists.count - 1) * 16
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent + 3), NSTextTab(textAlignment: .left, location: indent + 15)]
                p.firstLineHeadIndent = 0
                p.headIndent = indent + 15
                a.addAttribute(.paragraphStyle, value: p, range: range)
            }
        }
    }

    /// A4 pages with 2 cm margins and a page number at the foot.
    @MainActor private static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        let paper = NSSize(width: 595.28, height: 841.89), margin: CGFloat = 56
        let view = PageView(frame: NSRect(x: 0, y: 0, width: paper.width - 2 * margin, height: 10))
        view.textStorage?.setAttributedString(text)
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 0
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        let info = NSPrintInfo(dictionary: [.jobSavingURL: url])
        info.jobDisposition = .save
        info.paperSize = paper
        info.topMargin = margin; info.bottomMargin = margin; info.leftMargin = margin; info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw AppError("生成 PDF 失败") }
    }

    /// The text of the note, plus a small page number centred in the bottom margin of every sheet.
    private final class PageView: NSTextView {
        override func drawPageBorder(with borderSize: NSSize) {
            guard let op = NSPrintOperation.current else { return }
            let saved = frame
            setFrameOrigin(.zero)
            setFrameSize(borderSize)
            lockFocus()
            let label = NSAttributedString(string: "\(op.currentPage)", attributes: [
                .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.6, alpha: 1)])
            let size = label.size()
            label.draw(at: NSPoint(x: (borderSize.width - size.width) / 2, y: borderSize.height - op.printInfo.bottomMargin / 2 - size.height / 2))
            unlockFocus()
            frame = saved
        }
    }
}

/// Just enough Markdown for our notes (and typical custom templates): front matter (dropped), headings, paragraphs,
/// lists and task lists, quotes and Obsidian callouts, tables, rules, bold, italic, inline code and links.
enum MarkdownHTML {
    /// `plain` is semantic HTML; `page` (PDF) adds ruled headings and a details block built from text tables;
    /// `word` gets the same look without tables, which the system's .docx writer leaves out.
    enum Layout { case plain, page, word }

    static func document(_ md: String, layout: Layout = .page) -> String {
        """
        <html><head><meta charset="utf-8"><style>
        body { font-family: "PingFang SC", -apple-system, "Helvetica Neue", sans-serif; font-size: 11px; line-height: 1.75; color: #1f1f1f; }
        h1 { font-size: 22px; font-weight: 600; line-height: 1.35; margin: 0 0 14px 0; }
        h2 { font-size: 14px; font-weight: 600; color: #111; margin: \(layout == .page ? "0" : "0 0 5px 0"); }
        table.h2 td { border-top: 1px solid #d6d6d2; padding-top: 9px; padding-bottom: 3px; }
        h3 { font-size: 11.5px; font-weight: 600; margin: 10px 0 2px 0; }
        h4, h5, h6 { font-size: 11px; font-weight: 600; margin: 8px 0 2px 0; }
        p { margin: 0 0 6px 0; }
        li { margin: 0 0 3px 0; }
        p.task { margin: 0 0 4px 17px; text-indent: -17px; }
        table.info td { background: #f5f5f2; padding: 4px 12px; vertical-align: top; font-size: 10.5px; line-height: 1.6; }
        table.info td.k, p.meta span { color: #7c7c80; }
        p.meta { margin: 0 0 2px 0; font-size: 10.5px; }
        table.quote td { border-left: 3px solid #c9c9c5; background: #f7f7f5; color: #555; padding: 6px 12px; }
        p.quote { margin: 6px 0 8px 14px; color: #555; }
        p.row { margin: 0 0 3px 0; font-size: 10.5px; }
        p.gap { margin: 0; font-size: 7px; line-height: 1; }
        code { font-family: Menlo, monospace; font-size: 9.5px; color: #77777c; }
        a { color: #2a5db0; text-decoration: none; }
        table.grid { border-collapse: collapse; } table.grid td, table.grid th { border: 1px solid #d5d5d2; padding: 4px 8px; vertical-align: top; font-size: 10.5px; }
        table.grid th { background: #f2f2ef; font-weight: 600; }
        </style></head><body>
        \(body(md, layout: layout))
        </body></html>
        """
    }

    static func body(_ md: String, layout: Layout = .plain) -> String {
        let styled = layout != .plain, page = layout == .page
        var lines = md.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // drop YAML front matter
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { lines.removeSubrange(0...end) }
        var out: [String] = []
        var para: [String] = []
        var list: (tag: String, items: [String])?
        var i = 0
        func flushPara() { if !para.isEmpty { out.append("<p>" + para.map(inline).joined(separator: "<br>") + "</p>"); para = [] } }
        func closeList() {
            guard let l = list else { return }
            list = nil
            if styled, l.tag == "ul", l.items.count >= 2, let rows = detailRows(l.items) {
                // "- **会议时间：** …" lists read better as a label column and a value column
                if page {
                    out.append("<table class=\"info\" cellspacing=\"0\" width=\"100%\">"
                               + rows.map { "<tr><td class=\"k\">\(inline($0.0))</td><td class=\"v\">\(inline($0.1))</td></tr>" }.joined() + "</table>")
                } else {
                    out.append(contentsOf: rows.map { "<p class=\"meta\"><span>\(inline($0.0))</span>\u{3000}\(inline($0.1))</p>" })
                }
            } else if styled, l.tag == "ul", l.items.allSatisfy({ $0.hasPrefix("☐ ") || $0.hasPrefix("☑ ") }) {
                out.append(contentsOf: l.items.map { "<p class=\"task\">\(inline($0))</p>" })     // a box per line, no bullet in front of it
            } else if layout == .word {
                // plain hanging paragraphs: list indents do not survive the .docx writer well
                out.append(contentsOf: l.items.enumerated().map { "<p class=\"task\">\(l.tag == "ol" ? "\($0.offset + 1)." : "•")\u{2002}\(inline($0.element))</p>" })
            } else {
                out.append("<\(l.tag)>" + l.items.map { "<li>\(inline($0))</li>" }.joined() + "</\(l.tag)>")
            }
        }
        func add(_ tag: String, _ item: String) {
            if list?.tag != tag { closeList(); list = (tag, []) }
            list?.items.append(item)
        }

        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushPara(); closeList(); i += 1; continue }
            // headings
            if let m = line.range(of: "^#{1,6} ", options: .regularExpression) {
                flushPara(); closeList()
                let level = line[m].count - 1
                let h = "<h\(level)>\(inline(String(line[m.upperBound...])))</h\(level)>"
                if page && level == 2 {
                    out.append("<table class=\"h2\" cellspacing=\"0\" width=\"100%\"><tr><td>\(h)</td></tr></table>")
                } else {
                    // .docx keeps only the space after a paragraph, so the gap above a section is a thin paragraph of its own
                    if layout == .word, level == 2, !out.isEmpty { out.append("<p class=\"gap\">\u{200B}</p>") }
                    out.append(h)
                }
                i += 1; continue
            }
            // rule: dropped in the page and Word layouts, where headings carry the spacing (and, on the page, their own rule)
            if line.range(of: "^(-{3,}|\\*{3,}|_{3,})$", options: .regularExpression) != nil {
                flushPara(); closeList()
                if !styled { out.append("<hr>") }
                i += 1; continue
            }
            // table: header row followed by a |---| row
            if line.hasPrefix("|"), i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).range(of: "^\\|?\\s*:?-{2,}", options: .regularExpression) != nil {
                flushPara(); closeList()
                var rows = [cells(line)]
                i += 2
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(cells(lines[i])); i += 1 }
                if layout == .word {      // no tables in .docx: one line per row
                    out.append("<p class=\"row\"><b>" + rows[0].map(inline).joined(separator: "\u{3000}|\u{3000}") + "</b></p>")
                    out.append(contentsOf: rows.dropFirst().map { "<p class=\"row\">" + $0.map(inline).joined(separator: "\u{3000}|\u{3000}") + "</p>" })
                } else {
                    out.append("<table\(page ? " class=\"grid\" cellspacing=\"0\"" : "")><tr>" + rows[0].map { "<th>\(inline($0))</th>" }.joined() + "</tr>"
                               + rows.dropFirst().map { "<tr>" + $0.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }.joined() + "</table>")
                }
                continue
            }
            // quote / callout
            if line.hasPrefix(">") {
                flushPara(); closeList()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var t = String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)
                    if let m = t.range(of: "^\\[![a-zA-Z]+\\]\\s*", options: .regularExpression) { t.removeSubrange(m) }
                    if !t.isEmpty { q.append(inline(t)) }
                    i += 1
                }
                let text = q.joined(separator: "<br>")
                out.append(page ? "<table class=\"quote\" cellspacing=\"0\" width=\"100%\"><tr><td>\(text)</td></tr></table>"
                           : styled ? "<p class=\"quote\">\(text)</p>" : "<blockquote>\(text)</blockquote>")
                continue
            }
            // lists
            if let m = line.range(of: "^[-*+] ", options: .regularExpression) {
                flushPara()
                var item = String(line[m.upperBound...])
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) } else if item.lowercased().hasPrefix("[x] ") { item = "☑ " + item.dropFirst(4) }
                add("ul", item)
                i += 1; continue
            }
            if let m = line.range(of: "^\\d+[.)] ", options: .regularExpression) {
                flushPara()
                add("ol", String(line[m.upperBound...]))
                i += 1; continue
            }
            closeList()
            para.append(line)
            i += 1
        }
        flushPara(); closeList()
        return out.joined(separator: "\n")
    }

    /// Splits "**标签：** 内容" items into (label, value); nil unless every item has that shape.
    private static func detailRows(_ items: [String]) -> [(String, String)]? {
        var rows: [(String, String)] = []
        for item in items {
            guard let m = item.range(of: "^\\*\\*[^*]{1,12}?[：:]\\*\\*\\s*", options: .regularExpression) else { return nil }
            let label = item[m].trimmingCharacters(in: .whitespaces).dropFirst(2).dropLast(3)
            rows.append((String(label), String(item[m.upperBound...])))
        }
        return rows
    }

    private static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Escapes HTML, then bold, italic, inline code and links (Markdown links and <url>).
    static func inline(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        func re(_ pattern: String, _ template: String) {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        re("`([^`]+)`", "<code>$1</code>")
        re("\\[([^\\]]+)\\]\\(&lt;([^)]+)&gt;\\)", "<a href=\"$2\">$1</a>")      // [text](<url with spaces>)
        re("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>")
        re("\\*\\*([^*]+)\\*\\*", "<b>$1</b>")
        re("(?<![*\\w])\\*([^*]+)\\*(?![*\\w])", "<i>$1</i>")
        re("==([^=]+)==", "<mark>$1</mark>")
        return t
    }
}
