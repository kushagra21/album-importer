import Foundation

/// The records folder: one `runs/NN_<name>/` folder per import, the timeline sheet and the day's
/// `HISTORY_<date>.md`.
public struct RecordsFolder: Sendable {
    public static let defaultTimelineSheet = "sheets/timeline.xlsx"

    public var root: URL
    /// The timeline workbook's path inside the records folder.
    public var timelineSheetPath: String

    public init(root: URL, timelineSheet: String = RecordsFolder.defaultTimelineSheet) {
        self.root = root
        self.timelineSheetPath = timelineSheet
    }

    public var runsFolder: URL { root.appendingPathComponent("runs") }
    public var timelineSheet: URL { root.appendingPathComponent(timelineSheetPath) }

    public func historyFile(for date: Date = Date()) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return root.appendingPathComponent("HISTORY_\(f.string(from: date)).md")
    }

    /// Creates `runs/NN_<slug>` with the next free number (after `10_import_beach_trip` → `11_…`).
    public func makeRunFolder(slug: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: runsFolder, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: runsFolder.path)) ?? []
        let highest = existing.compactMap { name -> Int? in
            let digits = name.prefix { $0.isNumber }
            return digits.isEmpty ? nil : Int(digits)
        }.max() ?? 0
        var n = highest + 1
        while true {
            let url = runsFolder.appendingPathComponent(String(format: "%02d_%@", n, slug))
            if !fm.fileExists(atPath: url.path) {
                try fm.createDirectory(at: url, withIntermediateDirectories: false)
                return url
            }
            n += 1
        }
    }

    public static func writePlan(_ plan: ImportPlan, to folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(plan).write(to: folder.appendingPathComponent("plan.json"))
        var csv = "\u{FEFF}step,action,from,to\n"
        for s in plan.plan {
            csv += [String(s.seq), s.type, s.src ?? "", s.dst].map(CSVLog.escape).joined(separator: ",") + "\n"
        }
        try Data(csv.utf8).write(to: folder.appendingPathComponent("plan.csv"))
    }

    /// Adds a section to the day's history file (created with a title if it's the first run that day).
    public func appendHistory(_ markdown: String, date: Date = Date()) throws {
        let url = historyFile(for: date)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_GB")
            f.dateFormat = "d MMM yyyy"
            try Data("# History — \(f.string(from: date))\n".utf8).write(to: url)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: Data(("\n" + markdown).utf8))
    }
}
