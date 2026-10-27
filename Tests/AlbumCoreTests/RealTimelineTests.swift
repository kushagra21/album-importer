import Foundation
import Testing
@testable import AlbumCore

/// Runs the timeline update on a *copy* of a real timeline sheet. Set ALBUM_TIMELINE_XLSX to the
/// sheet and ALBUM_TIMELINE_OUT to where the updated copy should be written; skipped otherwise.
@Suite struct RealTimelineTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ALBUM_TIMELINE_XLSX"] != nil))
    func updatesACopyOfTheRealSheet() throws {
        let env = ProcessInfo.processInfo.environment
        let source = URL(fileURLWithPath: env["ALBUM_TIMELINE_XLSX"]!)
        let out = URL(fileURLWithPath: env["ALBUM_TIMELINE_OUT"]!)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.copyItem(at: source, to: out)
        let sourceDate = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        let before = try TimelineSheet.readRows(out)
        let outcome = try TimelineSheet.addEntry(to: out, values: [
            "start": .text("2022-07"), "end": .text("2022-07"), "months": .number(1), "year": .number(2022),
            "entry_name": .text("Test Entry"), "kind": .text("event"), "new_path": .text("Photo Library/2021 - 2022/2022-07 – Test Entry"),
            "old_path": .text("Camera Card/Test"), "album_folders": .number(1), "photos": .number(3), "videos": .number(0),
            "size_gb": .number(0.01), "date_confidence": .text("high"), "notes": .text("test row, R&D <ok>"),
        ], year: 2022)
        let after = try TimelineSheet.readRows(out)
        #expect(after.count == before.count + 1)
        #expect(outcome.totalEntries == before.count)
        #expect(after[outcome.order][5] == "Test Entry")
        #expect(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date == sourceDate)
    }
}
