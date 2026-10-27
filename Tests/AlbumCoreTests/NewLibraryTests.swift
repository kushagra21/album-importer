import Foundation
import Testing
@testable import AlbumCore

@Suite(.serialized) struct NewLibraryTests {
    @Test func rangeHelpers() {
        #expect(YearFolders.evenRanges(from: 2003, to: 2008, span: 2) == [2003...2004, 2005...2006, 2007...2008])
        #expect(YearFolders.evenRanges(from: 2020, to: 2024, span: 3) == [2020...2022, 2023...2024])
        #expect(YearFolders.name(2027, 2027) == "2027")
        #expect(YearFolders.name(2027, 2028) == "2027 - 2028")
        #expect(YearFolders.parse("2027")?.isNamedYear == false)
        #expect(YearFolders.parse("2027")?.contains(2027) == true)
        let existing = [YearFolder(name: "2023 - 2026", startYear: 2023, endYear: 2026, isNamedYear: false)]
        #expect(YearFolders.problems(in: [2027...2028, 2029...2030], existing: existing).isEmpty)
        #expect(YearFolders.problems(in: [2026...2027], existing: existing).count == 1)
        #expect(YearFolders.problems(in: [2027...2029, 2029...2030], existing: existing).count == 1)
    }

    @Test func createLibraryAndYearFoldersThenImport() throws {
        let sb = try Sandbox()
        try sb.folder("NewDrive")
        let lib = sb.root.appendingPathComponent("NewDrive/Family Photos")  // doesn't exist yet
        let records = RecordsFolder(root: sb.root.appendingPathComponent("NewRecords"))  // doesn't exist yet

        let r = try YearFolderSetup.create([2019...2020, 2021...2022, 2023...2023], libraryRoot: lib, records: records,
                                           allowUnlock: false, lockNewFolders: true)
        #expect(r.succeeded, "\(r.failures)")
        #expect(r.created == ["Family Photos", "2019 - 2020", "2021 - 2022", "2023"])
        #expect(YearFolders.list(in: lib).map(\.name) == ["2019 - 2020", "2021 - 2022", "2023"])
        #expect(YearFolders.list(in: lib).allSatisfy { Locks.isLocked(lib.appendingPathComponent($0.name)) })
        #expect(!Locks.isLocked(lib))
        #expect(try String(contentsOf: records.historyFile(), encoding: .utf8).contains("## Year folders"))

        // Running it again for an overlapping range is refused and changes nothing.
        let again = try YearFolderSetup.create([2022...2023], libraryRoot: lib, records: records, allowUnlock: false, lockNewFolders: true)
        #expect(!again.succeeded)
        #expect(YearFolders.list(in: lib).count == 3)

        // Import into the new library: the timeline sheet is created on the way.
        try sb.photo("Source/Seaside 2022/IMG_1.JPG", date: "2022:04:28 10:00:00", seed: 21)
        try sb.photo("Source/Seaside 2022/IMG_2.JPG", date: "2022:04:29 10:00:00", seed: 22)
        let p = ProposalBuilder.make(scan: try SourceScanner.scan(sb.root.appendingPathComponent("Source/Seaside 2022")),
                                     index: LibraryIndex.refresh(nil, root: lib), yearFolders: YearFolders.list(in: lib))
        #expect(p.albumRelativePath == "2021 - 2022/2022-04 – Seaside")
        var opts = ImportJob.Options()
        opts.allowUnlock = true
        let job = try ImportJob(proposal: p, libraryRoot: lib, records: records, options: opts).run(phase: { _ in }, progress: { _ in })
        #expect(job.succeeded, "\(job.failures)")
        #expect(Locks.isLocked(lib.appendingPathComponent("2021 - 2022")))
        let rows = try TimelineSheet.readRows(records.timelineSheet)
        #expect(rows.count == 2)
        #expect(rows[1][0] == "1" && rows[1][1] == "2022-04" && rows[1][5] == "Seaside")
        #expect(rows[1][8] == "Family Photos/2021 - 2022/2022-04 – Seaside")
        let byYear = try TimelineSheet.readRows(records.timelineSheet, sheetName: "By year")
        #expect(byYear.count == 2 && byYear[1][0] == "2022")
        #expect(byYear[1][1] == "=COUNTIF(Timeline!$E$2:$E$2,A2)")

        // A second import extends the timeline and the formulas.
        try sb.photo("Source/Spring Party 2023/IMG_3.JPG", date: "2023:03:08 10:00:00", seed: 23)
        let q = ProposalBuilder.make(scan: try SourceScanner.scan(sb.root.appendingPathComponent("Source/Spring Party 2023")),
                                     index: LibraryIndex.refresh(nil, root: lib), yearFolders: YearFolders.list(in: lib))
        #expect(q.target == .yearFolder("2023"))
        let job2 = try ImportJob(proposal: q, libraryRoot: lib, records: records, options: opts).run(phase: { _ in }, progress: { _ in })
        #expect(job2.succeeded, "\(job2.failures)")
        let rows2 = try TimelineSheet.readRows(records.timelineSheet)
        #expect(rows2.count == 3 && rows2[2][5] == "Spring Party")
        let byYear2 = try TimelineSheet.readRows(records.timelineSheet, sheetName: "By year")
        #expect(byYear2.count == 3 && byYear2[2][0] == "2023")
        #expect(byYear2[1][1] == "=COUNTIF(Timeline!$E$2:$E$3,A2)")
        #expect(byYear2[2][1] == "=COUNTIF(Timeline!$E$2:$E$3,A3)")
    }
}
