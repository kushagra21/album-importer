import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import AlbumCore

/// Builds throwaway folders, photos and videos for tests, inside a fresh temporary folder.
final class Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("album-importer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        // Unlock anything a test locked, so the temporary folder can be cleaned up by the system.
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e where Locks.isLocked(url) { try? Locks.setLocked(url, false) }
        }
        if Locks.isLocked(root) { try? Locks.setLocked(root, false) }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small JPEG with an EXIF date and camera model. `seed` changes the pixels (and so the bytes).
    @discardableResult
    func photo(_ path: String, date: String?, model: String? = "Canon EOS 90D", seed: Int = 0) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let w = 32, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8((i * 7 + seed * 31) & 0xFF)
            pixels[i * 4 + 1] = UInt8((i * 3 + seed * 17) & 0xFF)
            pixels[i * 4 + 2] = UInt8((seed * 53) & 0xFF)
            pixels[i * 4 + 3] = 255
        }
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let date { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date] }
        if let model { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: model] }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AlbumError.invalid("couldn't write test JPEG") }
        return url
    }

    /// A minimal MP4: ftyp + mdat + moov/mvhd with the given creation time (UTC).
    @discardableResult
    func video(_ path: String, utc: Date, payload: Int = 4096) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = Data()
        func be32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
        be32(16); d.append(contentsOf: Array("ftypisom".utf8)); be32(0)
        be32(UInt32(8 + payload)); d.append(contentsOf: Array("mdat".utf8)); d.append(Data(repeating: 0xAB, count: payload))
        let secs = UInt32(utc.timeIntervalSince1970 + 2_082_844_800)
        be32(8 + 8 + 100); d.append(contentsOf: Array("moov".utf8))
        be32(108); d.append(contentsOf: Array("mvhd".utf8))
        be32(0)  // version 0, flags
        be32(secs); be32(secs); be32(1000); be32(60_000)
        d.append(Data(repeating: 0, count: 80))
        try d.write(to: url)
        return url
    }

    func file(_ path: String, bytes: Int = 100) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// A timeline workbook shaped like the one openpyxl wrote: shared strings, styles, a header row,
    /// an autofilter, and a "By year" sheet with COUNTIF formulas over the Timeline rows.
    func timelineWorkbook(_ path: String, entries: [(start: String, name: String, year: Int)]) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let headers = ["order", "start", "end", "months", "year", "entry_name", "kind", "period", "new_path",
                       "old_path (before phase 2)", "album_folders", "photos", "videos", "size_gb", "date_confidence", "notes"]
        var strings: [String] = []
        func s(_ t: String) -> Int { if let i = strings.firstIndex(of: t) { return i }; strings.append(t); return strings.count - 1 }
        let letters = (0..<16).map { String(UnicodeScalar(65 + $0)!) }
        var rows = "<row r=\"1\">" + headers.enumerated().map { "<c r=\"\(letters[$0])1\" s=\"1\" t=\"s\"><v>\(s($1))</v></c>" }.joined() + "</row>"
        for (i, e) in entries.enumerated() {
            let r = i + 2
            rows += "<row r=\"\(r)\" ht=\"30\" customHeight=\"1\">"
            rows += "<c r=\"A\(r)\" s=\"2\"><v>\(i + 1)</v></c>"
            rows += "<c r=\"B\(r)\" s=\"2\" t=\"s\"><v>\(s(e.start))</v></c>"
            rows += "<c r=\"E\(r)\" s=\"2\"><v>\(e.year)</v></c>"
            rows += "<c r=\"F\(r)\" s=\"3\" t=\"s\"><v>\(s(e.name))</v></c>"
            rows += "<c r=\"G\(r)\" s=\"2\" t=\"s\"><v>\(s("event"))</v></c>"
            rows += "</row>"
        }
        let last = entries.count + 1
        let sheet1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:P\(last)"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><sheetFormatPr baseColWidth="8" defaultRowHeight="15"/><cols><col min="1" max="1" width="7" customWidth="1"/></cols><sheetData>\(rows)</sheetData><autoFilter ref="A1:P\(last)"/><pageMargins left="0.75" right="0.75" top="1" bottom="1" header="0.5" footer="0.5"/></worksheet>
        """
        let years = Array(Set(entries.map(\.year))).sorted()
        var yrows = "<row r=\"1\"><c r=\"A1\" t=\"s\"><v>\(s("year"))</v></c><c r=\"B1\" t=\"s\"><v>\(s("entries"))</v></c></row>"
        for (i, y) in years.enumerated() {
            let r = i + 2
            yrows += "<row r=\"\(r)\"><c r=\"A\(r)\"><v>\(y)</v></c><c r=\"B\(r)\"><f>COUNTIF(Timeline!$E$2:$E$\(last),A\(r))</f><v>1</v></c></row>"
        }
        let sheet2 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:B\(years.count + 1)"/><sheetData>\(yrows)</sheetData></worksheet>
        """
        let shared = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" uniqueCount=\"\(strings.count)\">"
            + strings.map { "<si><t>\(TimelineSheet.escape($0))</t></si>" }.joined() + "</sst>"
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets><sheet name="Timeline" sheetId="1" r:id="rId1"/><sheet name="By year" sheetId="2" r:id="rId2"/></sheets><calcPr calcId="124519" fullCalcOnLoad="1"/></workbook>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>
        """
        let zip = ZipArchive(entries: [
            .init(name: "xl/workbook.xml", data: Data(workbook.utf8)),
            .init(name: "xl/_rels/workbook.xml.rels", data: Data(rels.utf8)),
            .init(name: "xl/worksheets/sheet1.xml", data: Data(sheet1.utf8)),
            .init(name: "xl/worksheets/sheet2.xml", data: Data(sheet2.utf8)),
            .init(name: "xl/sharedStrings.xml", data: Data(shared.utf8)),
        ])
        try zip.write(to: url)
        return url
    }
}
