import Foundation
import Testing
@testable import AlbumCore

@Suite(.serialized) struct MultiLibraryTests {
    @Test func duplicatesFoundInAnotherLibraryEvenWhenItsDriveIsGone() throws {
        let sb = try Sandbox()
        // The old, full library: one loose photo and one inside a zip.
        let old = try sb.folder("OldDrive/Photo Library")
        try sb.folder("OldDrive/Photo Library/2021 - 2022")
        let loose = try sb.photo("OldDrive/Photo Library/2021 - 2022/2022-04 – Seaside/IMG_1.JPG", date: "2022:04:28 10:00:00", seed: 41)
        let zipped = try sb.photo("tmp/IMG_2.JPG", date: "2022:04:28 11:00:00", seed: 42)
        try ZipArchive(entries: [.init(name: "IMG_2.JPG", data: Data(contentsOf: zipped))])
            .write(to: old.appendingPathComponent("2021 - 2022/2022-04 – Seaside.zip"))
        let oldIndex = LibraryIndex.refresh(nil, root: old)

        // The new library on another drive, empty apart from its year folders.
        let new = try sb.folder("NewDrive/Photo Library")
        try sb.folder("NewDrive/Photo Library/2021 - 2022")
        let newIndex = LibraryIndex.refresh(nil, root: new)

        // A source folder holding copies of both, plus one new photo.
        let src = try sb.folder("Source/Seaside extra")
        try FileManager.default.copyItem(at: loose, to: src.appendingPathComponent("IMG_1.JPG"))
        try FileManager.default.copyItem(at: zipped, to: src.appendingPathComponent("IMG_2.JPG"))
        try sb.photo("Source/Seaside extra/IMG_3.JPG", date: "2022:04:29 10:00:00", seed: 43)
        let scan = try SourceScanner.scan(src)

        let alone = ProposalBuilder.make(scan: scan, index: newIndex, yearFolders: YearFolders.list(in: new))
        #expect(alone.alreadyInLibrary.isEmpty)
        let p = ProposalBuilder.make(scan: scan, index: newIndex, otherLibraries: [oldIndex], yearFolders: YearFolders.list(in: new))
        #expect(p.alreadyInLibrary.map(\.name).sorted() == ["IMG_1.JPG", "IMG_2.JPG"])
        #expect(p.filesToCopy.map(\.name) == ["IMG_3.JPG"])
        #expect(p.duplicates["IMG_1.JPG"]?.locations.first?.libraryDisplay == "Photo Library")
        let notes = ProposalBuilder.notices(for: p, index: newIndex, yearFolders: YearFolders.list(in: new), libraryRoot: new)
        #expect(notes.contains { $0.text.contains("already in another library") })

        // The old drive is unplugged: the zip entry is still confirmed by its stored CRC; the loose
        // file can't be read, so it stays a (name and size) duplicate instead of becoming "new".
        try FileManager.default.moveItem(at: sb.root.appendingPathComponent("OldDrive"), to: sb.root.appendingPathComponent("Unplugged"))
        let c = Duplicates.confirmByContents(scan, indexes: [newIndex, oldIndex], current: p.duplicates)
        #expect(c["IMG_2.JPG"] == p.duplicates["IMG_2.JPG"].map { _ in .duplicate(oldIndex.matches(name: "IMG_2.JPG", size: scan.files[1].size), confirmed: true) })
        #expect(c["IMG_1.JPG"]?.isAlreadyInLibrary == true)
        if case .duplicate(_, let confirmed) = c["IMG_1.JPG"] { #expect(!confirmed) }
    }

    @Test func settingsRememberLibrariesAndLoadOldFormat() throws {
        var s = Settings()
        s.libraryRoot = "/Volumes/Photos Drive/Photo Library"
        s.switchLibrary(to: "/Volumes/New Drive/Photo Library")
        #expect(s.libraryRoot == "/Volumes/New Drive/Photo Library")
        #expect(s.otherLibraries == ["/Volumes/Photos Drive/Photo Library"])
        s.switchLibrary(to: "/Volumes/Photos Drive/Photo Library")
        #expect(s.otherLibraries == ["/Volumes/New Drive/Photo Library"])
        // Settings saved before `otherLibraries` existed still load, keeping their paths.
        let old = #"{"libraryRoot":"/x/lib","recordsFolder":"/x/rec","specialDates":[]}"#
        let loaded = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(loaded.libraryRoot == "/x/lib" && loaded.recordsFolder == "/x/rec" && loaded.otherLibraries.isEmpty)
        #expect(LibraryIndex.displayName(of: "/Volumes/Photos Drive/Photo Library") == "Photos Drive ▸ Photo Library")
        #expect(Volumes.name(of: URL(fileURLWithPath: "/Volumes/Photos Drive/Photo Library")) == "Photos Drive")
    }
}
