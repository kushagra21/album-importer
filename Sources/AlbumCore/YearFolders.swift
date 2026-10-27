import Foundation

/// A year folder directly inside the library folder (e.g. `Photo Library`): a range such as `2023 - 2026`, or a named single
/// year such as `1990 - Wedding`. Read from the drive every time, never hard-coded.
public struct YearFolder: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var startYear: Int
    public var endYear: Int
    /// `1990 - Wedding`: one year with a label. Only used when no range fits, with a warning.
    public var isNamedYear: Bool

    public func contains(_ year: Int) -> Bool { (startYear...endYear).contains(year) }
}

public enum YearFolders {
    /// Parses a folder name; returns nil for folders that aren't year folders (e.g. `Misc Selected`).
    public static func parse(_ name: String) -> YearFolder? {
        let ns = name as NSString
        let full = NSRange(location: 0, length: ns.length)
        let range = try! NSRegularExpression(pattern: #"^\s*((?:19|20)\d{2})\s*[-–]\s*((?:19|20)\d{2})\s*$"#)
        if let m = range.firstMatch(in: name, range: full) {
            let a = Int(ns.substring(with: m.range(at: 1)))!, b = Int(ns.substring(with: m.range(at: 2)))!
            guard a <= b else { return nil }
            return YearFolder(name: name, startYear: a, endYear: b, isNamedYear: false)
        }
        let single = try! NSRegularExpression(pattern: #"^\s*((?:19|20)\d{2})\s*$"#)
        if let m = single.firstMatch(in: name, range: full) {
            let a = Int(ns.substring(with: m.range(at: 1)))!
            return YearFolder(name: name, startYear: a, endYear: a, isNamedYear: false)
        }
        let named = try! NSRegularExpression(pattern: #"^\s*((?:19|20)\d{2})\s*[-–]\s*\D.*$"#)
        if let m = named.firstMatch(in: name, range: full) {
            let a = Int(ns.substring(with: m.range(at: 1)))!
            return YearFolder(name: name, startYear: a, endYear: a, isNamedYear: true)
        }
        return nil
    }

    public static func list(in root: URL) -> [YearFolder] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.compactMap { name -> YearFolder? in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            return parse(name)
        }
        .sorted { ($0.startYear, $0.name) < ($1.startYear, $1.name) }
    }

    /// The folder an album starting in `year` belongs in: a range that contains it, else a named
    /// year folder for that year (flagged), else nil (a new folder is needed).
    public static func folder(for year: Int, in folders: [YearFolder]) -> (folder: YearFolder, isNamed: Bool)? {
        if let r = folders.first(where: { !$0.isNamedYear && $0.contains(year) }) { return (r, false) }
        if let n = folders.first(where: { $0.isNamedYear && $0.contains(year) }) { return (n, true) }
        return nil
    }

    /// Ranges that overlap each other, e.g. `2023 - 2026` and `2026 - 2027`.
    public static func overlaps(_ folders: [YearFolder]) -> [(YearFolder, YearFolder)] {
        let ranges = folders.filter { !$0.isNamedYear }
        var out: [(YearFolder, YearFolder)] = []
        for i in ranges.indices {
            for j in ranges.indices where j > i {
                if ranges[i].startYear <= ranges[j].endYear, ranges[j].startYear <= ranges[i].endYear {
                    out.append((ranges[i], ranges[j]))
                }
            }
        }
        return out
    }

    /// A name for a new year folder that would hold `year`, in the same `YYYY - YYYY` style and
    /// filling the gap next to the existing ranges. After `2023 - 2026`, 2027 → `2027 - 2028`.
    public static func suggestedNewFolder(for year: Int, existing: [YearFolder]) -> String {
        let ranges = existing.filter { !$0.isNamedYear }.sorted { $0.startYear < $1.startYear }
        guard let first = ranges.first, let last = ranges.last else { return "\(year) - \(year + 1)" }
        if year > last.endYear {
            let start = last.endYear + 1
            return year - start <= 1 ? "\(start) - \(start + 1)" : "\(year) - \(year + 1)"
        }
        if year < first.startYear {
            let end = first.startYear - 1
            return end - year <= 1 ? "\(max(year, end - 1)) - \(end)" : "\(year - 1) - \(year)"
        }
        // In a gap between two ranges: fill the gap.
        for (a, b) in zip(ranges, ranges.dropFirst()) where year > a.endYear && year < b.startYear {
            return "\(a.endYear + 1) - \(b.startYear - 1)"
        }
        return "\(year) - \(year + 1)"
    }

    /// The folder name for a range: "2027 - 2028", or "2027" for a single year.
    public static func name(_ start: Int, _ end: Int) -> String {
        start == end ? String(start) : "\(start) - \(end)"
    }

    /// Consecutive ranges of `span` years covering `from`…`to`, e.g. 2003–2026 by 2 → 2003 - 2004, 2005 - 2006, ….
    public static func evenRanges(from: Int, to: Int, span: Int) -> [ClosedRange<Int>] {
        guard from <= to, span >= 1 else { return [] }
        return stride(from: from, through: to, by: span).map { $0...min($0 + span - 1, to) }
    }

    /// Problems with a set of new ranges, checked against each other and the folders already there.
    public static func problems(in ranges: [ClosedRange<Int>], existing: [YearFolder]) -> [String] {
        var out: [String] = []
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for r in sorted where r.lowerBound < 1900 || r.upperBound > 2100 {
            out.append("\(name(r.lowerBound, r.upperBound)): use years between 1900 and 2100.")
        }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.overlaps(b) {
            out.append("\(name(a.lowerBound, a.upperBound)) and \(name(b.lowerBound, b.upperBound)) overlap.")
        }
        for r in sorted {
            if let f = existing.first(where: { !$0.isNamedYear && $0.startYear <= r.upperBound && r.lowerBound <= $0.endYear }) {
                out.append("\(name(r.lowerBound, r.upperBound)) overlaps the existing folder \(f.name).")
            }
        }
        return out
    }

    /// Checks a folder name typed for a new year folder.
    public static func validateNewName(_ name: String, for year: Int, existing: [YearFolder]) -> String? {
        guard let f = parse(name), !f.isNamedYear else { return "Use the form “YYYY - YYYY”, e.g. 2027 - 2028." }
        if !f.contains(year) { return "\(name) doesn't include \(year)." }
        if existing.contains(where: { $0.name == name }) { return "\(name) already exists." }
        if let clash = existing.first(where: { !$0.isNamedYear && $0.startYear <= f.endYear && f.startYear <= $0.endYear }) {
            return "Overlaps \(clash.name)."
        }
        return nil
    }
}

/// The macOS "Locked" flag (Finder > Get Info > Locked, `uchg`). A locked folder blocks adding,
/// renaming or removing anything directly inside it.
public enum Locks {
    public static func flags(_ url: URL) -> UInt32? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return st.st_flags
    }

    public static func isLocked(_ url: URL) -> Bool {
        guard let f = flags(url) else { return false }
        return f & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0
    }

    /// System-locked (`schg`) folders can only be changed by root; the app can't unlock them.
    public static func isSystemLocked(_ url: URL) -> Bool {
        guard let f = flags(url) else { return false }
        return f & UInt32(SF_IMMUTABLE) != 0
    }

    /// "uchg", "-" and so on, as `ls -lO` prints them.
    public static func describe(_ url: URL) -> String {
        guard let f = flags(url) else { return "?" }
        var parts: [String] = []
        if f & UInt32(UF_IMMUTABLE) != 0 { parts.append("uchg") }
        if f & UInt32(SF_IMMUTABLE) != 0 { parts.append("schg") }
        if f & UInt32(UF_HIDDEN) != 0 { parts.append("hidden") }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    public static func setLocked(_ url: URL, _ locked: Bool) throws {
        guard let f = flags(url) else { throw AlbumError.invalid("Can't read the flags of \(url.path)") }
        let new = locked ? f | UInt32(UF_IMMUTABLE) : f & ~UInt32(UF_IMMUTABLE)
        guard chflags(url.path, new) == 0 else {
            throw AlbumError.invalid("Couldn't \(locked ? "lock" : "unlock") \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }
}
