import Foundation

/// Suggests year-folder ranges from the albums waiting to be copied, for a library that doesn't have
/// year folders for them yet. Albums are counted in the year they start, as that decides their folder.
public enum YearSuggest {
    public struct YearStat: Sendable, Hashable, Identifiable {
        public var id: Int { year }
        public var year: Int
        public var albums: Int
        public var files: Int
        public var bytes: Int64

        public init(year: Int, albums: Int, files: Int, bytes: Int64) {
            self.year = year
            self.albums = albums
            self.files = files
            self.bytes = bytes
        }
    }

    public enum Style: Sendable, Hashable {
        /// One folder for each year that has albums: `2014`, `2016`, …
        case perYear
        /// Blocks of `n` years from the earliest year: `2013 - 2014`, `2015 - 2016`, …
        case blocks(Int)
        /// About `n` folders holding similar amounts, neighbouring years grouped (e.g. 2003 - 2011 next to 2021 - 2022).
        case balanced(Int)
    }

    /// Adds up albums per start year.
    public static func stats(from proposals: [Proposal]) -> [YearStat] {
        var by: [Int: YearStat] = [:]
        for p in proposals {
            guard let y = p.startYear else { continue }
            let files = p.filesToCopy
            var s = by[y] ?? YearStat(year: y, albums: 0, files: 0, bytes: 0)
            s.albums += 1
            s.files += files.count
            s.bytes += files.reduce(0) { $0 + $1.size }
            by[y] = s
        }
        return by.values.sorted { $0.year < $1.year }
    }

    /// Ranges for the years not already covered by a year folder. They never overlap an existing folder.
    public static func suggest(_ stats: [YearStat], style: Style, existing: [YearFolder]) -> [ClosedRange<Int>] {
        let covered = { (y: Int) in existing.contains { !$0.isNamedYear && $0.contains(y) } }
        let years = stats.filter { !covered($0.year) && ($0.albums > 0) }.sorted { $0.year < $1.year }
        guard let first = years.first?.year, let last = years.last?.year else { return [] }

        // Existing folders split the years into separate stretches; no suggested range crosses one.
        let segment = { (y: Int) in existing.filter { !$0.isNamedYear && $0.endYear < y }.count }
        var groups: [ClosedRange<Int>] = []
        switch style {
        case .perYear:
            return years.map { $0.year...$0.year }
        case .blocks(let n):
            let n = max(1, n)
            for seg in Set(years.map { segment($0.year) }).sorted() {
                let segYears = years.map(\.year).filter { segment($0) == seg }
                for start in stride(from: segYears.first!, through: segYears.last!, by: n) {
                    let block = start...(start + n - 1)
                    if segYears.contains(where: { block.contains($0) }) { groups.append(block) }
                }
            }
        case .balanced(let n):
            let count = max(1, min(n, years.count))
            let total = max(years.reduce(Int64(0)) { $0 + max($1.bytes, 1) }, 1)
            let target = Double(total) / Double(count)
            var current: [Int] = []
            var acc: Int64 = 0
            for (i, y) in years.enumerated() {
                current.append(y.year)
                acc += max(y.bytes, 1)
                let remainingYears = years.count - i - 1
                let groupsLeft = count - groups.count - 1
                let crossesFolder = i + 1 < years.count && segment(years[i + 1].year) != segment(y.year)
                // Close the group once it's big enough (keeping a year for each group still to come),
                // or when an existing folder comes next.
                if crossesFolder || (groupsLeft > 0 && (Double(acc) >= target || remainingYears == groupsLeft)) {
                    groups.append(current.first!...current.last!)
                    current = []
                    acc = 0
                }
            }
            if !current.isEmpty { groups.append(current.first!...current.last!) }
            // Stretch each group to the next one in the same stretch, so the empty years in between have a home.
            for i in groups.indices.dropLast() where segment(groups[i].lowerBound) == segment(groups[i + 1].lowerBound) {
                groups[i] = groups[i].lowerBound...(groups[i + 1].lowerBound - 1)
            }
        }
        // Keep clear of existing folders: trim each range to the gap around its years.
        return groups.compactMap { r in
            let inside = years.map(\.year).filter { r.contains($0) }
            guard let lo = inside.first, let hi = inside.last else { return nil }
            let below = existing.filter { !$0.isNamedYear && $0.endYear < lo }.map(\.endYear).max().map { $0 + 1 } ?? Int.min
            let above = existing.filter { !$0.isNamedYear && $0.startYear > hi }.map(\.startYear).min().map { $0 - 1 } ?? Int.max
            return max(r.lowerBound, below)...min(r.upperBound, above)
        }
    }

    /// A sensible number of folders for "balanced": about one per three years with photos.
    public static func defaultBalancedCount(_ stats: [YearStat]) -> Int {
        max(1, Int((Double(stats.filter { $0.albums > 0 }.count) / 3).rounded()))
    }
}
