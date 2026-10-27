import Foundation

/// The library's naming rules: `YYYY-MM – Event`, `YYYY-MM to YYYY-MM – Event`, or `YYYY – Event`.
public enum Naming {
    public static let dash = " – "  // en dash with spaces

    /// A special date that names an album when its folder has no proper name.
    public struct SpecialDate: Codable, Sendable, Hashable {
        public var month: Int
        public var day: Int
        public var name: String

        public init(month: Int, day: Int, name: String) {
            self.month = month
            self.day = day
            self.name = name
        }
    }

    /// Birthdays and other personal dates are added by the owner in Settings.
    public static let defaultSpecialDates: [SpecialDate] = [
        .init(month: 12, day: 31, name: "New Years Event"),
    ]

    /// The album folder name for a date range and an event name.
    public static func albumName(start: Date?, end: Date?, yearOnly: Int? = nil, event: String) -> String {
        let event = clean(event)
        let datePart: String
        if let start {
            let a = Floating.ym(start)
            let b = Floating.ym(end ?? start)
            let first = String(format: "%04d-%02d", a.year, a.month)
            let last = String(format: "%04d-%02d", b.year, b.month)
            datePart = first == last ? first : "\(first) to \(last)"
        } else if let yearOnly {
            datePart = String(yearOnly)
        } else {
            datePart = "Undated"
        }
        return event.isEmpty ? datePart : datePart + dash + event
    }

    private static let months = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec",
    ]

    /// Suggests an event name from the source folder's name: date words removed, `&` → "and",
    /// apostrophes dropped. Returns "" when the folder name is a camera or device name (`EOS`, `DCIM`).
    public static func suggestedEvent(fromFolderName name: String) -> String {
        if MediaTypes.looksLikeDeviceName(name) { return "" }
        var s = name.replacingOccurrences(of: "_", with: " ")
        let patterns = [
            #"(?<!\d)(19|20)\d{2}\s*[-–./\s]\s*(0?[1-9]|1[0-2])\s*[-–./\s]\s*(0?[1-9]|[12]\d|3[01])(?!\d)"#,  // 2022-07-17
            #"(?<!\d)(19|20)\d{2}\s*[-–./]\s*(0?[1-9]|1[0-2])(?!\d)"#,  // 2022 - 07
            #"(?<!\d)(0?[1-9]|[12]\d|3[01])\s*[-–./]\s*(0?[1-9]|1[0-2])\s*[-–./]\s*(19|20)\d{2}(?!\d)"#,  // 17-07-2022
            #"(?<!\d)(19|20)\d{2}(?!\d)"#,  // 2022
            #"['’‘]\d{2}(?!\d)"#,  // '24
            #"(?i)(?<![a-z])\d{1,2}(st|nd|rd|th)(?![a-z])"#,  // 21st
            #"(?i)(?<![a-z])(\#(months.joined(separator: "|")))(?![a-z])\.?"#,
        ]
        for p in patterns {
            s = s.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        s = clean(s)
        // What's left of "Jan-Feb" or "12 - " after removing dates is only separators.
        if s.range(of: #"[\p{L}\p{N}]"#, options: .regularExpression) == nil { return "" }
        return s
    }

    /// Tidies an event name typed by the owner or suggested: `&` → "and", no apostrophes or slashes,
    /// single spaces, no separators at the ends.
    public static func clean(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "&", with: " and ")
        s = s.replacingOccurrences(of: #"['’‘`]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[/:\\]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\(\s*\)"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        // Collapse runs of separators left behind ("Beach -  - Trip" → "Beach - Trip").
        s = s.replacingOccurrences(of: #"(\s*[-–,.]\s*){2,}"#, with: " - ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–_.,").union(.whitespacesAndNewlines))
        return s
    }

    /// The special-date name when all the album's dates fall within 3 days of one special date.
    public static func specialDateName(start: Date?, end: Date?, specials: [SpecialDate]) -> String? {
        guard let start, let end, end.timeIntervalSince(start) <= 7 * 86_400 else { return nil }
        let y = Floating.ym(start).year
        for sp in specials {
            for year in [y - 1, y, y + 1] {
                guard let day = Floating.date(year, sp.month, sp.day, 12) else { continue }
                let limit: TimeInterval = 3 * 86_400 + 12 * 3600
                if abs(start.timeIntervalSince(day)) <= limit, abs(end.timeIntervalSince(day)) <= limit { return sp.name }
            }
        }
        return nil
    }

    /// A short, safe folder-name slug for a run folder: "Beach Trip" → "beach_trip".
    public static func slug(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
        let trimmed = lowered.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return String(trimmed.prefix(40)).isEmpty ? "import" : String(trimmed.prefix(40))
    }
}
