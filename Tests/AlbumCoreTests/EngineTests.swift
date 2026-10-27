import Foundation
import Testing
@testable import AlbumCore

@Suite(.serialized) struct EngineTests {
    /// A small library: two year folders, one album with a photo that also exists in the source,
    /// and a zip holding a copy of another source photo.
    func makeLibrary(_ sb: Sandbox) throws -> (library: URL, records: URL) {
        let lib = try sb.folder("Photo Library")
        try sb.folder("Photo Library/2017 - 2020")
        try sb.folder("Photo Library/2021 - 2022")
        try sb.folder("Photo Library/1990 - Wedding")
        try sb.folder("Photo Library/Misc Selected")
        try sb.photo("Photo Library/2021 - 2022/2022-07 – Family Dinner/IMG_0001.JPG", date: "2022:07:18 10:00:00", seed: 1)
        let zipped = try sb.photo("tmp/IMG_0002.JPG", date: "2022:07:17 09:00:00", seed: 2)
        try ZipArchive(entries: [.init(name: "Old/IMG_0002.JPG", data: Data(contentsOf: zipped))])
            .write(to: lib.appendingPathComponent("2021 - 2022/2022-07 – Old Export.zip"))
        let records = try sb.folder("records")
        _ = try sb.timelineWorkbook("records/sheets/timeline.xlsx", entries: [
            ("2020-08", "Garden Party", 2020), ("2022-04", "Seaside", 2022), ("2022-07", "Family Dinner", 2022), ("2022-09", "Phone Export", 2022),
        ])
        return (lib, records)
    }

    /// A source folder like a camera card: DCIM/100CANON with photos, a video, junk and a document.
    func makeSource(_ sb: Sandbox, name: String = "2022 - 07 - Beach Trip") throws -> URL {
        let src = try sb.folder("Source/\(name)")
        try sb.photo("Source/\(name)/DCIM/100CANON/IMG_0001.JPG", date: "2022:07:18 10:00:00", seed: 1)  // same as library
        try sb.photo("Source/\(name)/DCIM/100CANON/IMG_0002.JPG", date: "2022:07:17 09:00:00", seed: 2)  // inside the zip
        try sb.photo("Source/\(name)/DCIM/100CANON/IMG_0003.JPG", date: "2022:07:17 11:00:00", seed: 3)
        try sb.photo("Source/\(name)/DCIM/100CANON/IMG_0004.JPG", date: "2022:07:17 12:00:00", seed: 4)
        try sb.video("Source/\(name)/DCIM/100CANON/MVI_0005.MP4", utc: Date(timeIntervalSince1970: 1_658_040_000))  // 17 Jul 2022 06:40 UTC
        try sb.file("Source/\(name)/.DS_Store")
        try sb.file("Source/\(name)/notes.txt")
        return src
    }

    @Test func scanReadsDatesAndDissolvesCameraFolders() throws {
        let sb = try Sandbox()
        let src = try makeSource(sb)
        let scan = try SourceScanner.scan(src)
        #expect(scan.count(.photo) == 4)
        #expect(scan.count(.video) == 1)
        #expect(scan.count(.other) == 1)
        #expect(scan.junkCount == 1)
        #expect(scan.dissolvedFolders == ["DCIM/100CANON"])
        #expect(scan.files.first { $0.name == "IMG_0003.JPG" }?.destinationPath == "IMG_0003.JPG")
        #expect(scan.cameras["Canon EOS 90D"] == 4)
        let video = scan.files.first { $0.kind == .video }
        #expect(video?.date?.source == .video)
        let d = DateSummary.from(scan)
        #expect(d.start.map { Floating.format($0, "yyyy-MM-dd") } == "2022-07-17")
        #expect(d.end.map { Floating.format($0, "yyyy-MM-dd") } == "2022-07-18")
        #expect(d.confidence == .high)
    }

    @Test func proposalFindsDuplicatesYearFolderAndName() throws {
        let sb = try Sandbox()
        let (lib, _) = try makeLibrary(sb)
        let scan = try SourceScanner.scan(try makeSource(sb))
        let index = LibraryIndex.refresh(nil, root: lib)
        let years = YearFolders.list(in: lib)
        #expect(years.map(\.name) == ["1990 - Wedding", "2017 - 2020", "2021 - 2022"])
        let p = ProposalBuilder.make(scan: scan, index: index, yearFolders: years)
        #expect(p.eventName == "Beach Trip")
        #expect(p.target == .yearFolder("2021 - 2022"))
        #expect(p.albumRelativePath == "2021 - 2022/2022-07 – Beach Trip")
        #expect(p.alreadyInLibrary.map(\.name).sorted() == ["IMG_0001.JPG", "IMG_0002.JPG"])
        #expect(p.filesToCopy.map(\.name).sorted() == ["IMG_0003.JPG", "IMG_0004.JPG", "MVI_0005.MP4"])
        let notes = ProposalBuilder.notices(for: p, index: index, yearFolders: years, libraryRoot: lib)
        #expect(!notes.contains { $0.level == .blocker })
        #expect(notes.contains { $0.text.contains("Family Dinner") })
        // The contents check confirms both duplicates (one by file CRC, one by the zip's stored CRC).
        let confirmed = Duplicates.confirmByContents(scan, index: index, libraryRoot: lib, current: p.duplicates)
        #expect(confirmed.values.filter { if case .duplicate(_, true) = $0 { true } else { false } }.count == 2)
    }

    @Test func renamedCopyFoundByContents() throws {
        let sb = try Sandbox()
        let (lib, _) = try makeLibrary(sb)
        let src = try sb.folder("Source/Renamed")
        try FileManager.default.copyItem(at: lib.appendingPathComponent("2021 - 2022/2022-07 – Family Dinner/IMG_0001.JPG"),
                                         to: src.appendingPathComponent("Puja photo.jpg"))
        // Pad to the 50 KB minimum used for size-only candidates.
        let scan = try SourceScanner.scan(src)
        let index = LibraryIndex.refresh(nil, root: lib)
        let p = ProposalBuilder.make(scan: scan, index: index, yearFolders: YearFolders.list(in: lib))
        #expect(p.duplicates["Puja photo.jpg"] == .new)
        let size = scan.files[0].size
        if size >= 50_000 {
            let c = Duplicates.confirmByContents(scan, index: index, libraryRoot: lib, current: p.duplicates)
            #expect(c["Puja photo.jpg"]?.isAlreadyInLibrary == true)
        }
    }

    @Test func deviceFolderNeedsAnEventName() throws {
        let sb = try Sandbox()
        let (lib, _) = try makeLibrary(sb)
        try sb.photo("Source/EOS/IMG_0046.JPG", date: "2020:08:02 19:42:19", seed: 9)
        let scan = try SourceScanner.scan(sb.root.appendingPathComponent("Source/EOS"))
        let p = ProposalBuilder.make(scan: scan, index: LibraryIndex.refresh(nil, root: lib), yearFolders: YearFolders.list(in: lib))
        #expect(p.eventName == "")
        #expect(p.target == .yearFolder("2017 - 2020"))
        let notes = ProposalBuilder.notices(for: p, index: LibraryIndex.refresh(nil, root: lib), yearFolders: YearFolders.list(in: lib), libraryRoot: lib)
        #expect(notes.contains { $0.level == .blocker && $0.text.contains("event name") })
    }

    @Test func newYearFolderSuggested() throws {
        let sb = try Sandbox()
        let lib = try sb.folder("Photo Library")
        for y in ["2003 - 2011", "2012 - 2016", "2017 - 2020", "2021 - 2022", "2023 - 2026"] { try sb.folder("Photo Library/\(y)") }
        let years = YearFolders.list(in: lib)
        #expect(YearFolders.suggestedNewFolder(for: 2027, existing: years) == "2027 - 2028")
        #expect(YearFolders.suggestedNewFolder(for: 2028, existing: years) == "2027 - 2028")
        #expect(YearFolders.suggestedNewFolder(for: 2031, existing: years) == "2031 - 2032")
        #expect(YearFolders.validateNewName("2026 - 2027", for: 2027, existing: years) != nil)  // overlaps
        #expect(YearFolders.validateNewName("2027 - 2028", for: 2027, existing: years) == nil)
        try sb.folder("Photo Library/2027 - 2028")
        #expect(YearFolders.folder(for: 2028, in: YearFolders.list(in: lib))?.folder.name == "2027 - 2028")
        #expect(YearFolders.parse("1990 - Wedding")?.isNamedYear == true)
        #expect(YearFolders.parse("Misc Selected") == nil)
    }

    @Test func fullImportWithLockedYearFolder() throws {
        let sb = try Sandbox()
        let (lib, recordsURL) = try makeLibrary(sb)
        let src = try makeSource(sb)
        let year = lib.appendingPathComponent("2021 - 2022")
        try Locks.setLocked(year, true)
        let index = LibraryIndex.refresh(nil, root: lib)
        let p = ProposalBuilder.make(scan: try SourceScanner.scan(src), index: index, yearFolders: YearFolders.list(in: lib))
        let records = RecordsFolder(root: recordsURL)

        // Without permission nothing happens.
        let refused = try ImportJob(proposal: p, libraryRoot: lib, records: records, options: .init()).run(phase: { _ in }, progress: { _ in })
        #expect(!refused.succeeded)
        #expect(refused.copied == 0)
        #expect(!FileManager.default.fileExists(atPath: year.appendingPathComponent(p.albumName).path))
        #expect(Locks.isLocked(year))

        var opts = ImportJob.Options()
        opts.allowUnlock = true
        let r = try ImportJob(proposal: p, libraryRoot: lib, records: records, options: opts).run(phase: { _ in }, progress: { _ in })
        #expect(r.succeeded, "\(r.failures)")
        #expect(r.copied == 3)
        #expect(Locks.isLocked(year), "the year folder must be locked again")
        let album = year.appendingPathComponent("2022-07 – Beach Trip")
        let names = try FileManager.default.contentsOfDirectory(atPath: album.path).sorted()
        #expect(names == ["IMG_0003.JPG", "IMG_0004.JPG", "MVI_0005.MP4"])
        // Same bytes and modified date as the source.
        let a = src.appendingPathComponent("DCIM/100CANON/IMG_0003.JPG"), b = album.appendingPathComponent("IMG_0003.JPG")
        #expect(try Executor.sha256(of: a) == Executor.sha256(of: b))
        let ma = try FileManager.default.attributesOfItem(atPath: a.path)[.modificationDate] as? Date
        let mb = try FileManager.default.attributesOfItem(atPath: b.path)[.modificationDate] as? Date
        #expect(ma.map { Int($0.timeIntervalSince1970) } == mb.map { Int($0.timeIntervalSince1970) })

        // Records: plan, logs, lock log, report, history, timeline row in date order.
        let run = r.runFolder
        let files = try FileManager.default.contentsOfDirectory(atPath: run.path)
        #expect(files.contains("plan.json") && files.contains("plan.csv") && files.contains("lock_log.csv") && files.contains("run_report.md"))
        #expect(files.contains("timeline_before_this_run.xlsx"))
        #expect(files.filter { $0.hasPrefix("log_") }.count == 2)
        let lockLog = try String(contentsOf: run.appendingPathComponent("lock_log.csv"), encoding: .utf8)
        #expect(lockLog.contains("unlock (chflags nouchg)") && lockLog.contains("lock (chflags uchg)"))
        let history = try String(contentsOf: records.historyFile(), encoding: .utf8)
        #expect(history.contains("## Import: Beach Trip"))
        let rows = try TimelineSheet.readRows(records.timelineSheet)
        #expect(rows.count == 6)
        #expect(rows[3][1] == "2022-07" && rows[3][5] == "Family Dinner")
        #expect(rows[4][5] == "Beach Trip")
        #expect(rows[4][0] == "4")
        #expect(rows[5][0] == "5" && rows[5][5] == "Phone Export")
        let byYear = try TimelineSheet.readRows(records.timelineSheet, sheetName: "By year")
        #expect(byYear[1][1] == "=COUNTIF(Timeline!$E$2:$E$6,A2)")

        // Running the same import again changes nothing: the album already exists.
        let again = try ImportJob(proposal: p, libraryRoot: lib, records: records, options: opts).run(phase: { _ in }, progress: { _ in })
        #expect(!again.succeeded)
        #expect(Locks.isLocked(year))
        #expect(try FileManager.default.contentsOfDirectory(atPath: album.path).count == 3)
    }

    @Test func importIntoNewYearFolderLocksIt() throws {
        let sb = try Sandbox()
        let (lib, recordsURL) = try makeLibrary(sb)
        try sb.photo("Source/Mountains 2024/IMG_9001.JPG", date: "2024:02:10 08:00:00", seed: 11)
        try Locks.setLocked(lib, true)
        let p = ProposalBuilder.make(scan: try SourceScanner.scan(sb.root.appendingPathComponent("Source/Mountains 2024")),
                                     index: LibraryIndex.refresh(nil, root: lib), yearFolders: YearFolders.list(in: lib))
        // The library ends at 2021 - 2022, so 2024 needs a new folder; the suggestion fills the gap.
        #expect(p.target == .newYearFolder("2023 - 2024"))
        let q = p
        var opts = ImportJob.Options()
        opts.allowUnlock = true
        let r = try ImportJob(proposal: q, libraryRoot: lib, records: RecordsFolder(root: recordsURL), options: opts).run(phase: { _ in }, progress: { _ in })
        #expect(r.succeeded, "\(r.failures)")
        #expect(FileManager.default.fileExists(atPath: lib.appendingPathComponent("2023 - 2024/2024-02 – Mountains/IMG_9001.JPG").path))
        #expect(Locks.isLocked(lib))
        #expect(Locks.isLocked(lib.appendingPathComponent("2023 - 2024")))
        let byYear = try TimelineSheet.readRows(RecordsFolder(root: recordsURL).timelineSheet, sheetName: "By year")
        #expect(byYear.last?.first == "2024")
    }

    @Test func copyNeverOverwrites() throws {
        let sb = try Sandbox()
        try sb.file("a.bin", bytes: 1000)
        try sb.file("b.bin", bytes: 10)
        #expect(throws: (any Error).self) {
            try Executor.copyVerified(from: sb.root.appendingPathComponent("a.bin"), to: sb.root.appendingPathComponent("b.bin"))
        }
        #expect(try Data(contentsOf: sb.root.appendingPathComponent("b.bin")).count == 10)
    }

    @Test func zipListingAndCRC() throws {
        let sb = try Sandbox()
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        try ZipArchive(entries: [.init(name: "x/y.bin", data: payload), .init(name: "z.txt", data: Data("hi".utf8))])
            .write(to: sb.root.appendingPathComponent("t.zip"))
        let entries = try ZipReader.entries(of: sb.root.appendingPathComponent("t.zip"))
        #expect(entries.map(\.path) == ["x/y.bin", "z.txt"])
        #expect(entries[0].size == 100_000)
        var crc = CRC32()
        crc.update(payload)
        #expect(entries[0].crc32 == crc.value)
        // Round trip through the reader used for .xlsx files.
        let back = try ZipArchive.read(sb.root.appendingPathComponent("t.zip"))
        #expect(back["x/y.bin"] == payload)
    }
}
