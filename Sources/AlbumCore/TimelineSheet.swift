import Foundation

/// Adds one entry to the timeline workbook in date order, keeping the sheet's formatting:
/// the new row copies the styles of the row above, the following rows are renumbered, and the
/// "By year" formulas are stretched to cover the new row.
public enum TimelineSheet {
    public enum Value: Sendable, Equatable {
        case text(String)
        case number(Double)
        case empty
    }

    public struct Outcome: Sendable {
        /// The entry's `order` number.
        public var order: Int
        public var totalEntries: Int
        /// Anything that couldn't be done automatically, for the owner.
        public var notes: [String]
    }

    /// `values` is keyed by column header (`start`, `entry_name`, `new_path`, …). A header that starts
    /// with a key also matches (`old_path` → `old_path (before phase 2)`).
    public static func addEntry(to url: URL, sheetName: String = "Timeline", values: [String: Value], year: Int?) throws -> Outcome {
        var zip = try ZipArchive.read(url)
        let sheetPath = try worksheetPath(named: sheetName, in: zip)
        guard let sheetData = zip[sheetPath], var xml = String(data: sheetData, encoding: .utf8) else {
            throw AlbumError.invalid("Can't read the \(sheetName) sheet")
        }
        let shared = sharedStrings(zip)
        guard let body = xml.range(of: #"<sheetData>([\s\S]*)</sheetData>"#, options: .regularExpression) else {
            throw AlbumError.invalid("The \(sheetName) sheet has no rows")
        }
        var rows = parseRows(String(xml[body]).replacingOccurrences(of: "<sheetData>", with: "").replacingOccurrences(of: "</sheetData>", with: ""))
        guard let header = rows.first(where: { $0.number == 1 }) else { throw AlbumError.invalid("The \(sheetName) sheet has no header row") }
        var columns: [(letter: String, title: String)] = []
        for c in header.cells { columns.append((c.column, c.text(shared) ?? "")) }
        func column(_ key: String) -> String? {
            columns.first { $0.title == key }?.letter ?? columns.first { $0.title.hasPrefix(key) }?.letter
        }
        guard let startCol = column("start") else { throw AlbumError.invalid("No “start” column in \(sheetName)") }
        let orderCol = column("order")
        let dataRows = rows.filter { $0.number > 1 }
        let lastRowBefore = rows.map(\.number).max() ?? 1

        // Insert after the last entry that starts in the same month or earlier.
        let newStart: String = { if case .text(let s) = values["start"] { return s } else { return "" } }()
        var insertAt = 2
        for r in dataRows {
            let s = r.cell(startCol)?.text(shared) ?? ""
            if !s.isEmpty, s <= newStart { insertAt = r.number + 1 }
        }
        // Copy the look of a neighbouring entry (never the header's).
        let template = rows.first { $0.number == insertAt - 1 && $0.number > 1 } ?? rows.first { $0.number == insertAt && $0.number > 1 }
        // Is `order` simply row − 1 everywhere? Then renumber it; otherwise just shift it.
        let orderIsRowMinusOne = orderCol.map { col in
            dataRows.allSatisfy { Int($0.cell(col)?.rawValue ?? "") == $0.number - 1 }
        } ?? false

        for i in rows.indices where rows[i].number >= insertAt {
            rows[i].shift(by: 1)
            if let col = orderCol, let j = rows[i].cells.firstIndex(where: { $0.column == col }), let old = Int(rows[i].cells[j].rawValue ?? "") {
                rows[i].cells[j].setNumber(orderIsRowMinusOne ? rows[i].number - 1 : old + 1)
            }
        }
        let aboveOrder = orderCol.flatMap { col in rows.first { $0.number == insertAt - 1 }?.cell(col)?.rawValue }.flatMap(Int.init) ?? 0
        let order = orderIsRowMinusOne ? insertAt - 1 : aboveOrder + 1

        var newRow = Row(number: insertAt, attributes: template?.attributes ?? "", cells: [])
        for (letter, title) in columns {
            var v: Value = .empty
            if title == "order" { v = .number(Double(order)) }
            else if let exact = values[title] { v = exact }
            else if let key = values.keys.first(where: { title.hasPrefix($0) }) { v = values[key]! }
            let style = template?.cell(letter)?.style
            newRow.cells.append(Cell.make(column: letter, row: insertAt, style: style, value: v))
        }
        rows.append(newRow)
        rows.sort { $0.number < $1.number }
        let lastRow = lastRowBefore + 1

        let newBody = "<sheetData>" + rows.map(\.xml).joined() + "</sheetData>"
        xml.replaceSubrange(body, with: newBody)
        xml = stretchRefs(in: xml, tags: ["dimension", "autoFilter"], from: lastRowBefore, to: lastRow)
        zip[sheetPath] = Data(xml.utf8)

        // Other sheets: stretch formulas such as COUNTIF(Timeline!$E$2:$E$338, …) and drop stale results.
        var notes: [String] = []
        for name in try worksheetNames(in: zip) where name.path != sheetPath {
            guard let d = zip[name.path], var other = String(data: d, encoding: .utf8) else { continue }
            let before = other
            other = stretchFormulas(in: other, sheet: sheetName, from: lastRowBefore, to: lastRow)
            if let year, name.title == "By year" {
                let (updated, note) = addYearRow(to: other, year: year, shared: shared, timelineLastRow: lastRow, sheet: sheetName)
                other = updated
                if let note { notes.append(note) }
            }
            if other != before { zip[name.path] = Data(other.utf8) }
        }
        zip["xl/workbook.xml"] = zip["xl/workbook.xml"].flatMap { String(data: $0, encoding: .utf8) }.map { Data(forceRecalc($0).utf8) }
        try zip.write(to: url)
        return Outcome(order: order, totalEntries: lastRow - 1, notes: notes)
    }

    /// Reads every row of a sheet as text (shared strings resolved); used by tests and the app's history view.
    public static func readRows(_ url: URL, sheetName: String = "Timeline") throws -> [[String]] {
        let zip = try ZipArchive.read(url)
        let path = try worksheetPath(named: sheetName, in: zip)
        guard let d = zip[path], let xml = String(data: d, encoding: .utf8),
              let body = xml.range(of: #"<sheetData>([\s\S]*)</sheetData>"#, options: .regularExpression) else { return [] }
        let shared = sharedStrings(zip)
        let rows = parseRows(String(xml[body]))
        // One string per column (A, B, C, …), with "" for empty cells.
        return rows.map { r in
            var out: [String] = []
            for c in r.cells {
                let i = columnIndex(c.column)
                while out.count < i { out.append("") }
                out.append(c.formula.map { "=" + $0 } ?? c.text(shared) ?? "")
            }
            return out
        }
    }

    static func columnIndex(_ letters: String) -> Int {
        letters.unicodeScalars.reduce(0) { $0 * 26 + Int($1.value) - 64 } - 1
    }

    // MARK: Workbook structure

    struct SheetRef { var title: String; var path: String }

    static func worksheetNames(in zip: ZipArchive) throws -> [SheetRef] {
        guard let wb = zip["xl/workbook.xml"].flatMap({ String(data: $0, encoding: .utf8) }),
              let rels = zip["xl/_rels/workbook.xml.rels"].flatMap({ String(data: $0, encoding: .utf8) })
        else { throw AlbumError.invalid("Not a valid .xlsx workbook") }
        var targets: [String: String] = [:]
        for tag in matches(#"<Relationship\b[^>]*>"#, in: rels) {
            if let id = attribute("Id", in: tag), let target = attribute("Target", in: tag) {
                targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
            }
        }
        return matches(#"<sheet\b[^>]*>"#, in: wb).compactMap { tag in
            guard let name = attribute("name", in: tag), let id = attribute("r:id", in: tag), let path = targets[id] else { return nil }
            return SheetRef(title: unescape(name), path: path)
        }
    }

    static func worksheetPath(named name: String, in zip: ZipArchive) throws -> String {
        guard let ref = try worksheetNames(in: zip).first(where: { $0.title == name }) else {
            throw AlbumError.invalid("No sheet named “\(name)”")
        }
        return ref.path
    }

    static func sharedStrings(_ zip: ZipArchive) -> [String] {
        guard let d = zip["xl/sharedStrings.xml"], let xml = String(data: d, encoding: .utf8) else { return [] }
        return matches(#"<si>[\s\S]*?</si>"#, in: xml).map { si in
            matches(#"<t\b[^>]*>[\s\S]*?</t>"#, in: si).map { t in
                unescape(t.replacingOccurrences(of: #"^<t\b[^>]*>|</t>$"#, with: "", options: .regularExpression))
            }.joined()
        }
    }

    static func forceRecalc(_ wb: String) -> String {
        if let r = wb.range(of: #"<calcPr\b[^>]*/>"#, options: .regularExpression) {
            var tag = String(wb[r])
            if tag.contains("fullCalcOnLoad=") {
                tag = tag.replacingOccurrences(of: #"fullCalcOnLoad="[^"]*""#, with: #"fullCalcOnLoad="1""#, options: .regularExpression)
            } else {
                tag = tag.replacingOccurrences(of: "/>", with: #" fullCalcOnLoad="1"/>"#)
            }
            return wb.replacingCharacters(in: r, with: tag)
        }
        return wb
    }

    // MARK: Rows and cells

    struct Cell {
        var column: String
        var attributes: String  // everything except r=
        var inner: String?      // nil for <c …/>

        var style: String? { TimelineSheet.attribute("s", in: "<c \(attributes)>") }
        var type: String? { TimelineSheet.attribute("t", in: "<c \(attributes)>") }
        var rawValue: String? {
            guard let inner, let r = inner.range(of: #"<v>([\s\S]*?)</v>"#, options: .regularExpression) else { return nil }
            return String(inner[r]).replacingOccurrences(of: #"</?v>"#, with: "", options: .regularExpression)
        }
        var formula: String? {
            guard let inner, let r = inner.range(of: #"<f\b[^>]*>([\s\S]*?)</f>"#, options: .regularExpression) else { return nil }
            return TimelineSheet.unescape(String(inner[r]).replacingOccurrences(of: #"^<f\b[^>]*>|</f>$"#, with: "", options: .regularExpression))
        }

        func text(_ shared: [String]) -> String? {
            switch type {
            case "s": return rawValue.flatMap(Int.init).flatMap { $0 < shared.count ? shared[$0] : nil }
            case "inlineStr":
                guard let inner else { return nil }
                return TimelineSheet.matches(#"<t\b[^>]*>[\s\S]*?</t>"#, in: inner).map {
                    TimelineSheet.unescape($0.replacingOccurrences(of: #"^<t\b[^>]*>|</t>$"#, with: "", options: .regularExpression))
                }.joined()
            case "str": return rawValue.map(TimelineSheet.unescape)
            default: return rawValue
            }
        }

        mutating func setNumber(_ n: Int) {
            attributes = attributes.replacingOccurrences(of: #"\s*\bt="[^"]*""#, with: "", options: .regularExpression)
            inner = "<v>\(n)</v>"
        }

        func xml(row: Int) -> String {
            let attrs = attributes.isEmpty ? "" : " " + attributes
            if let inner { return "<c r=\"\(column)\(row)\"\(attrs)>\(inner)</c>" }
            return "<c r=\"\(column)\(row)\"\(attrs)/>"
        }

        static func make(column: String, row: Int, style: String?, value: Value) -> Cell {
            let s = style.map { "s=\"\($0)\"" } ?? ""
            switch value {
            case .empty:
                return Cell(column: column, attributes: s, inner: nil)
            case .number(let d):
                let text = d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
                return Cell(column: column, attributes: s, inner: "<v>\(text)</v>")
            case .text(let t):
                let attrs = [s, "t=\"inlineStr\""].filter { !$0.isEmpty }.joined(separator: " ")
                return Cell(column: column, attributes: attrs, inner: "<is><t xml:space=\"preserve\">\(TimelineSheet.escape(t))</t></is>")
            }
        }
    }

    struct Row {
        var number: Int
        var attributes: String  // everything except r=
        var cells: [Cell]

        func cell(_ column: String) -> Cell? { cells.first { $0.column == column } }

        mutating func shift(by n: Int) { number += n }

        var xml: String {
            let attrs = attributes.isEmpty ? "" : " " + attributes
            return "<row r=\"\(number)\"\(attrs)>" + cells.map { $0.xml(row: number) }.joined() + "</row>"
        }
    }

    static func parseRows(_ body: String) -> [Row] {
        matches(#"<row\b[^>]*?(?:/>|>[\s\S]*?</row>)"#, in: body).compactMap { rowXML in
            guard let open = rowXML.range(of: #"^<row\b[^>]*?/?>"#, options: .regularExpression) else { return nil }
            let tag = String(rowXML[open])
            guard let r = attribute("r", in: tag).flatMap(Int.init) else { return nil }
            let attrs = otherAttributes(tag, dropping: ["r"])
            let cells = matches(#"<c\b[^>]*?(?:/>|>[\s\S]*?</c>)"#, in: rowXML).compactMap { c -> Cell? in
                guard let cOpen = c.range(of: #"^<c\b[^>]*?/?>"#, options: .regularExpression) else { return nil }
                let cTag = String(c[cOpen])
                guard let ref = attribute("r", in: cTag) else { return nil }
                let letters = String(ref.prefix { $0.isLetter })
                let inner: String? = cTag.hasSuffix("/>") ? nil
                    : String(c[cOpen.upperBound...]).replacingOccurrences(of: #"</c>$"#, with: "", options: .regularExpression)
                return Cell(column: letters, attributes: otherAttributes(cTag, dropping: ["r"]), inner: inner)
            }
            return Row(number: r, attributes: attrs, cells: cells)
        }
    }

    /// `<dimension ref="A1:P338"/>` → `A1:P339` when the range ended at the old last row.
    static func stretchRefs(in xml: String, tags: [String], from old: Int, to new: Int) -> String {
        var out = xml
        for tag in tags {
            let pattern = "(<\(tag)\\b[^>]*\\bref=\"[A-Z]+\\d+:[A-Z]+)\(old)\""
            out = out.replacingOccurrences(of: pattern, with: "$1\(new)\"", options: .regularExpression)
        }
        return out
    }

    /// `Timeline!$E$2:$E$338` → `$E$339`, inside `<f>` formulas, and removes their cached values.
    static func stretchFormulas(in xml: String, sheet: String, from old: Int, to new: Int) -> String {
        let quoted = NSRegularExpression.escapedPattern(for: sheet)
        let pattern = "((?:'\(quoted)'|\(quoted))!\\$?[A-Z]+\\$?\\d+:\\$?[A-Z]+\\$?)\(old)(?!\\d)"
        var changed = false
        var out = ""
        var rest = Substring(xml)
        while let r = rest.range(of: #"<c\b[^>]*>(?:(?!</c>)[\s\S])*?<f\b[^>]*>[\s\S]*?</f>[\s\S]*?</c>"#, options: .regularExpression) {
            out += rest[..<r.lowerBound]
            var cell = String(rest[r])
            let updated = cell.replacingOccurrences(of: pattern, with: "$1\(new)", options: .regularExpression)
            if updated != cell {
                changed = true
                cell = updated.replacingOccurrences(of: #"<v>[\s\S]*?</v>|<v/>"#, with: "", options: .regularExpression)
            }
            out += cell
            rest = rest[r.upperBound...]
        }
        out += rest
        return changed ? out : xml
    }

    /// Adds a row for a new year at the bottom of "By year" (copying the last year's formulas),
    /// when the year is later than every year listed and nothing follows the last year row.
    static func addYearRow(to xml: String, year: Int, shared: [String], timelineLastRow: Int, sheet: String) -> (String, String?) {
        guard let body = xml.range(of: #"<sheetData>([\s\S]*)</sheetData>"#, options: .regularExpression) else { return (xml, nil) }
        let rows = parseRows(String(xml[body]))
        let yearRows = rows.filter { $0.number > 1 && Int($0.cell("A")?.text(shared) ?? "") != nil }
        let years = yearRows.compactMap { Int($0.cell("A")?.text(shared) ?? "") }
        if years.contains(year) { return (xml, nil) }
        if yearRows.isEmpty, rows.allSatisfy({ $0.number <= 1 }) {
            // A new sheet: the first year row, with the standard formulas.
            let r = 2, t = "\(sheet)!", end = timelineLastRow
            let formulas = [
                ("B", "COUNTIF(\(t)$E$2:$E$\(end),A\(r))"),
                ("C", "COUNTIFS(\(t)$E$2:$E$\(end),A\(r),\(t)$G$2:$G$\(end),\"event\")"),
                ("D", "SUMIF(\(t)$E$2:$E$\(end),A\(r),\(t)$L$2:$L$\(end))"),
                ("E", "SUMIF(\(t)$E$2:$E$\(end),A\(r),\(t)$M$2:$M$\(end))"),
                ("F", "SUMIF(\(t)$E$2:$E$\(end),A\(r),\(t)$N$2:$N$\(end))"),
            ]
            var row = Row(number: r, attributes: "", cells: [Cell.make(column: "A", row: r, style: nil, value: .number(Double(year)))])
            for (col, f) in formulas { row.cells.append(Cell(column: col, attributes: "", inner: "<f>\(escape(f))</f>")) }
            var out = xml.replacingOccurrences(of: "</sheetData>", with: row.xml + "</sheetData>")
            out = out.replacingOccurrences(of: "<sheetData/>", with: "<sheetData>" + row.xml + "</sheetData>")
            out = out.replacingOccurrences(of: #"(<dimension\b[^>]*\bref="[A-Z]+\d+:[A-Z]+)1""#, with: "$12\"", options: .regularExpression)
            return (out, nil)
        }
        guard let last = yearRows.last, let lastYear = years.last, year > lastYear,
              rows.allSatisfy({ $0.number <= last.number }) else {
            return (xml, "Add \(year) to the “By year” sheet by hand (it couldn't be added automatically).")
        }
        let n = last.number + 1
        var row = Row(number: n, attributes: last.attributes, cells: [])
        for c in last.cells {
            var copy = c
            if c.column == "A" {
                copy = Cell.make(column: "A", row: n, style: c.style, value: .number(Double(year)))
            } else if var inner = c.inner {
                // Relative references to the year cell (A12) move to the new row (A13); $-anchored ranges stay.
                inner = inner.replacingOccurrences(of: "(?<![$A-Z])A\(last.number)(?!\\d)", with: "A\(n)", options: .regularExpression)
                inner = inner.replacingOccurrences(of: #"<v>[\s\S]*?</v>"#, with: "", options: .regularExpression)
                copy.inner = inner
            }
            row.cells.append(copy)
        }
        var out = xml
        let insertion = row.xml
        out = out.replacingOccurrences(of: "</sheetData>", with: insertion + "</sheetData>")
        out = out.replacingOccurrences(of: "(<dimension\\b[^>]*\\bref=\"[A-Z]+\\d+:[A-Z]+)\(last.number)\"", with: "$1\(n)\"", options: .regularExpression)
        return (out, nil)
    }

    // MARK: Small XML helpers

    static func matches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = "\\s" + NSRegularExpression.escapedPattern(for: name) + "=\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        return (tag as NSString).substring(with: m.range(at: 1))
    }

    static func otherAttributes(_ tag: String, dropping: Set<String>) -> String {
        let found = matches(#"\s[\w:]+="[^"]*""#, in: tag)
        return found.filter { attr in
            let name = attr.trimmingCharacters(in: .whitespaces).split(separator: "=").first.map(String.init) ?? ""
            return !dropping.contains(name)
        }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .joined(separator: " ")
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension TimelineSheet {
    public static let columns = ["order", "start", "end", "months", "year", "entry_name", "kind", "period", "new_path",
                                 "old_path", "album_folders", "photos", "videos", "size_gb", "date_confidence", "notes"]

    /// Writes a new, empty timeline workbook (a "Timeline" sheet with the standard columns, frozen
    /// header and filter, and a "By year" summary), for a library that doesn't have one yet.
    public static func createEmpty(at url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw AlbumError.invalid("\(url.lastPathComponent) already exists; it won't be replaced.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let letters = (0..<columns.count).map { String(UnicodeScalar(65 + $0)!) }
        let widths = [7, 9, 9, 7, 6, 32, 8, 10, 60, 50, 8, 8, 8, 8, 10, 60]
        func header(_ titles: [String]) -> String {
            "<row r=\"1\">" + titles.enumerated().map { i, t in
                "<c r=\"\(letters[i])1\" s=\"1\" t=\"inlineStr\"><is><t>\(escape(t))</t></is></c>"
            }.joined() + "</row>"
        }
        let cols = widths.enumerated().map { "<col min=\"\($0 + 1)\" max=\"\($0 + 1)\" width=\"\($1)\" customWidth=\"1\"/>" }.joined()
        let ns = #"xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships""#
        let timeline = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet \(ns)><dimension ref="A1:P1"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols>\(cols)</cols><sheetData>\(header(columns))</sheetData><autoFilter ref="A1:P1"/></worksheet>
        """
        let byYear = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet \(ns)><dimension ref="A1:F1"/><sheetData>\(header(["year", "entries", "events", "photos", "videos", "size_gb"]))</sheetData></worksheet>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook \(ns)><bookViews><workbookView/></bookViews><sheets><sheet name="Timeline" sheetId="1" r:id="rId1"/><sheet name="By year" sheetId="2" r:id="rId2"/></sheets><calcPr calcId="124519" fullCalcOnLoad="1"/></workbook>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
        // Style 0: plain, wrapped, top-aligned. Style 1: bold header on light grey.
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFE7E6E6"/></patternFill></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs><cellXfs count="2"><xf fontId="0" fillId="0" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf><xf fontId="1" fillId="2" applyFont="1" applyFill="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """
        try ZipArchive(entries: [
            .init(name: "[Content_Types].xml", data: Data(contentTypes.utf8)),
            .init(name: "_rels/.rels", data: Data(rootRels.utf8)),
            .init(name: "xl/workbook.xml", data: Data(workbook.utf8)),
            .init(name: "xl/_rels/workbook.xml.rels", data: Data(rels.utf8)),
            .init(name: "xl/styles.xml", data: Data(styles.utf8)),
            .init(name: "xl/worksheets/sheet1.xml", data: Data(timeline.utf8)),
            .init(name: "xl/worksheets/sheet2.xml", data: Data(byYear.utf8)),
        ]).write(to: url)
    }
}
