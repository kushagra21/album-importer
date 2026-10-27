import Foundation
import Testing
@testable import AlbumCore

@Suite struct NamingTests {
    @Test func eventNameFromFolderName() {
        #expect(Naming.suggestedEvent(fromFolderName: "2022 - 07 - Beach Trip") == "Beach Trip")
        #expect(Naming.suggestedEvent(fromFolderName: "Seaside 2022") == "Seaside")
        #expect(Naming.suggestedEvent(fromFolderName: "Spring Party 2023") == "Spring Party")
        #expect(Naming.suggestedEvent(fromFolderName: "Party Dec '24") == "Party")
        #expect(Naming.suggestedEvent(fromFolderName: "Sam & Alex's party") == "Sam and Alexs party")
        #expect(Naming.suggestedEvent(fromFolderName: "2021_03_14_Hill_Trip") == "Hill Trip")
        #expect(Naming.suggestedEvent(fromFolderName: "Jan-Feb 2024") == "")
    }

    @Test func deviceFoldersGiveNoName() {
        #expect(Naming.suggestedEvent(fromFolderName: "EOS") == "")
        #expect(Naming.suggestedEvent(fromFolderName: "DCIM") == "")
        #expect(Naming.suggestedEvent(fromFolderName: "100MEDIA") == "")
        #expect(Naming.suggestedEvent(fromFolderName: "Canon EOS 90D") == "")
    }

    @Test func albumNames() {
        let a = Floating.date(2022, 7, 17)!, b = Floating.date(2022, 9, 2)!
        #expect(Naming.albumName(start: a, end: a, event: "Beach Trip") == "2022-07 – Beach Trip")
        #expect(Naming.albumName(start: a, end: b, event: "Monsoon") == "2022-07 to 2022-09 – Monsoon")
        #expect(Naming.albumName(start: nil, end: nil, yearOnly: 2003, event: "Old Video") == "2003 – Old Video")
        #expect(Naming.albumName(start: a, end: a, event: "Rock & Roll") == "2022-07 – Rock and Roll")
    }

    @Test func specialDates() {
        // Personal dates come from the owner's settings, not the code.
        let specials = Naming.defaultSpecialDates + [.init(month: 8, day: 12, name: "Friend Birthday")]
        let s = Floating.date(2025, 8, 12, 18)!, e = Floating.date(2025, 8, 13, 1)!
        #expect(Naming.specialDateName(start: s, end: e, specials: specials) == "Friend Birthday")
        #expect(Naming.specialDateName(start: s, end: e, specials: Naming.defaultSpecialDates) == nil)
        let n = Floating.date(2025, 12, 31, 22)!, m = Floating.date(2026, 1, 1, 2)!
        #expect(Naming.specialDateName(start: n, end: m, specials: Naming.defaultSpecialDates) == "New Years Event")
        #expect(Naming.specialDateName(start: Floating.date(2025, 6, 1)!, end: Floating.date(2025, 6, 2)!, specials: Naming.defaultSpecialDates) == nil)
    }

    @Test func dateInFileName() {
        #expect(DateReader.dateInName("IMG_20190512_143000").map { Floating.format($0) } == "2019-05-12 14:30")
        #expect(DateReader.dateInName("WhatsApp Image 2021-03-04 at 10.15.22").map { Floating.format($0, "yyyy-MM-dd") } == "2021-03-04")
        #expect(DateReader.dateInName("PXL_20230101_101010123") != nil)
        #expect(DateReader.dateInName("IMG_0046") == nil)
        #expect(DateReader.dateInName("DSC01234") == nil)
    }

    @Test func folderNameHints() {
        #expect(DateReader.yearMonthInFolderName("2022 - 07 - Beach Trip")?.year == 2022)
        #expect(DateReader.yearMonthInFolderName("2022 - 07 - Beach Trip")?.month == 7)
        #expect(DateReader.yearMonthInFolderName("Seaside 2022")?.month == nil)
        #expect(DateReader.yearMonthInFolderName("EOS") == nil)
    }
}
