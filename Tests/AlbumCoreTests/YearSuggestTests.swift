import Foundation
import Testing
@testable import AlbumCore

@Suite struct YearSuggestTests {
    let gb: Int64 = 1_000_000_000
    func s(_ y: Int, _ bytes: Int64, albums: Int = 1) -> YearSuggest.YearStat { .init(year: y, albums: albums, files: 10, bytes: bytes) }

    @Test func perYearSkipsEmptyYears() {
        let stats = [s(2014, gb), s(2016, gb), s(2017, gb)]
        #expect(YearSuggest.suggest(stats, style: .perYear, existing: []) == [2014...2014, 2016...2016, 2017...2017])
    }

    @Test func blocksStartAtTheEarliestYear() {
        let stats = [s(2013, gb), s(2014, gb), s(2017, gb), s(2020, gb)]
        #expect(YearSuggest.suggest(stats, style: .blocks(2), existing: []) == [2013...2014, 2017...2018, 2019...2020])
        #expect(YearSuggest.suggest(stats, style: .blocks(4), existing: []) == [2013...2016, 2017...2020])
    }

    @Test func balancedGroupsQuietYearsAndSplitsBusyOnes() {
        // Few photos in the early years, many recently.
        let stats = [s(2003, gb), s(2006, gb), s(2010, gb), s(2014, 5 * gb), s(2016, 5 * gb), s(2021, 10 * gb), s(2023, 10 * gb)]
        let r = YearSuggest.suggest(stats, style: .balanced(3), existing: [])
        #expect(r.count == 3)
        #expect(r.first?.lowerBound == 2003 && r.last?.upperBound == 2023)
        // Contiguous: every year from 2003 to 2023 has exactly one folder.
        for (a, b) in zip(r, r.dropFirst()) { #expect(a.upperBound + 1 == b.lowerBound) }
        #expect(YearFolders.problems(in: r, existing: []).isEmpty)
        // The busy recent years end up in a smaller range than the quiet early ones.
        #expect(r.last!.count < r.first!.count)
    }

    @Test func neverOverlapsExistingFolders() {
        let existing = [YearFolder(name: "2021 - 2022", startYear: 2021, endYear: 2022, isNamedYear: false)]
        let stats = [s(2019, gb), s(2021, gb), s(2024, gb), s(2025, gb)]
        for style in [YearSuggest.Style.perYear, .blocks(3), .balanced(2)] {
            let r = YearSuggest.suggest(stats, style: style, existing: existing)
            #expect(YearFolders.problems(in: r, existing: existing).isEmpty, "\(style): \(r)")
            #expect(!r.contains { $0.contains(2021) })
            #expect(r.contains { $0.contains(2019) } && r.contains { $0.contains(2024) } && r.contains { $0.contains(2025) })
        }
    }

    @Test func statsCountAlbumsByStartYear() throws {
        let sb = try Sandbox()
        try sb.photo("A/IMG_1.JPG", date: "2019:12:30 10:00:00", seed: 1)
        try sb.photo("A/IMG_2.JPG", date: "2020:01:02 10:00:00", seed: 2)  // runs into 2020, still a 2019 album
        try sb.photo("B/IMG_3.JPG", date: "2021:05:01 10:00:00", seed: 3)
        let lib = try sb.folder("Lib")
        let idx = LibraryIndex.refresh(nil, root: lib)
        let props = try ["A", "B"].map { ProposalBuilder.make(scan: try SourceScanner.scan(sb.root.appendingPathComponent($0)), index: idx, yearFolders: []) }
        let stats = YearSuggest.stats(from: props)
        #expect(stats.map(\.year) == [2019, 2021])
        #expect(stats[0].files == 2 && stats[0].albums == 1)
    }
}
