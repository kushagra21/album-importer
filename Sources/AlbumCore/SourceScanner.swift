import Foundation

/// One file in a folder being imported.
public struct SourceFile: Codable, Sendable, Hashable, Identifiable {
    public var id: String { relativePath }
    /// Path inside the source folder, e.g. `DJI/100MEDIA/DJI_0221.JPG`.
    public var relativePath: String
    /// Where it goes inside the new album, after camera folders are dissolved, e.g. `DJI_0221.JPG`.
    public var destinationPath: String
    public var size: Int64
    public var modified: Date
    public var kind: MediaKind
    /// Filled in for the files whose dates were read (all of them, unless the folder is very large).
    public var date: FileDate?

    public var name: String { (relativePath as NSString).lastPathComponent }
}

/// Everything learned about a source folder, read-only.
public struct SourceScan: Codable, Sendable {
    public var folder: URL
    public var files: [SourceFile]
    /// Junk that is never copied (`.DS_Store`, `._*`, `Thumbs.db`), counted for the record.
    public var junkCount: Int
    public var cameras: [String: Int]
    /// One GPS position per photo that has one (at most 200), for a place-name suggestion.
    public var gpsSamples: [Coordinate]
    /// Camera folders that were dissolved, e.g. `DJI/100MEDIA`.
    public var dissolvedFolders: [String]
    /// True when dissolving camera folders would make two files share a name, so the original layout is kept.
    public var keptLayoutBecauseOfClash: Bool
    public var datesReadFor: Int

    public var media: [SourceFile] { files.filter { $0.kind == .photo || $0.kind == .video || $0.kind == .audio } }
    public func count(_ kind: MediaKind) -> Int { files.lazy.filter { $0.kind == kind }.count }
    public func size(of kinds: Set<MediaKind>) -> Int64 { files.lazy.filter { kinds.contains($0.kind) }.reduce(0) { $0 + $1.size } }
}

public struct Coordinate: Codable, Sendable, Hashable {
    public var latitude: Double
    public var longitude: Double
}

public enum SourceScanner {
    /// Folders with more media than this have an even sample of their files' dates read.
    public static let maxDatesRead = 600

    public static func scan(_ folder: URL, progress: (@Sendable (String) -> Void)? = nil) throws -> SourceScan {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw AlbumError.notAFolder(folder.path)
        }
        progress?("Listing files…")
        var files: [SourceFile] = []
        var junk = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            throw AlbumError.notAFolder(folder.path)
        }
        let basePath = folder.standardizedFileURL.path
        for case let url as URL in e {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if name.hasPrefix(".") { e.skipDescendants() }
                continue
            }
            if MediaTypes.isJunk(name) { junk += 1; continue }
            guard v?.isRegularFile == true, v?.isSymbolicLink != true else { continue }
            var rel = url.standardizedFileURL.path
            if rel.hasPrefix(basePath + "/") { rel.removeFirst(basePath.count + 1) }
            files.append(SourceFile(relativePath: rel, destinationPath: rel, size: Int64(v?.fileSize ?? 0),
                                    modified: v?.contentModificationDate ?? .distantPast, kind: MediaTypes.kind(of: url)))
        }
        files.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }

        // Dissolve camera folders (DCIM/100CANON, DJI/100MEDIA, …) unless that makes names clash.
        var dissolved = Set<String>()
        var flattened = files
        for i in flattened.indices {
            let comps = flattened[i].relativePath.split(separator: "/").map(String.init)
            let dirs = comps.dropLast()
            let kept = dirs.filter { !MediaTypes.isWrapperFolder($0) }
            if kept.count != dirs.count {
                dissolved.insert(dirs.joined(separator: "/"))
            }
            flattened[i].destinationPath = (kept + [comps.last!]).joined(separator: "/")
        }
        let destinations = flattened.map { $0.destinationPath.lowercased() }
        let clash = Set(destinations).count != destinations.count
        if !clash { files = flattened } else { dissolved.removeAll() }

        // Read dates: every file, or an even sample of a very large folder (always the first and last).
        let dated = files.indices.filter { files[$0].kind == .photo || files[$0].kind == .video }
        var chosen = dated
        if dated.count > maxDatesRead {
            let step = Double(dated.count - 1) / Double(maxDatesRead - 1)
            chosen = Array(Set((0..<maxDatesRead).map { dated[Int((Double($0) * step).rounded())] })).sorted()
        }
        var cameras: [String: Int] = [:]
        var gps: [Coordinate] = []
        for (n, i) in chosen.enumerated() {
            if n % 25 == 0 { progress?("Reading dates… \(n) of \(chosen.count)") }
            let url = folder.appendingPathComponent(files[i].relativePath)
            let (date, facts) = DateReader.read(url, kind: files[i].kind, modified: files[i].modified)
            files[i].date = date
            if let cam = facts?.camera { cameras[cam, default: 0] += 1 }
            if let lat = facts?.latitude, let lon = facts?.longitude, gps.count < 200, !(lat == 0 && lon == 0) {
                gps.append(Coordinate(latitude: lat, longitude: lon))
            }
        }
        // Audio and sidecars take their own name/modified date; they don't decide the album's dates.
        for i in files.indices where files[i].date == nil && (files[i].kind == .audio) {
            files[i].date = DateReader.read(folder.appendingPathComponent(files[i].relativePath), kind: .audio, modified: files[i].modified).0
        }
        return SourceScan(folder: folder, files: files, junkCount: junk, cameras: cameras, gpsSamples: gps,
                          dissolvedFolders: dissolved.sorted(), keptLayoutBecauseOfClash: clash, datesReadFor: chosen.count)
    }
}

/// The date range of an album, worked out from its files' dates.
public struct DateSummary: Codable, Sendable {
    public var start: Date?
    public var end: Date?
    /// Most common source among the dates used.
    public var mainSource: DateSource?
    public var confidence: Confidence
    /// Files whose dates were far from the rest (camera clock not set, edited copies) and were ignored.
    public var outliers: [String]
    /// Photos and videos dated only by their modified date.
    public var undatedCount: Int
    /// From the folder name, e.g. `2022 - 07 - …` → 2022-07.
    public var folderNameHint: (year: Int, month: Int?)? {
        get { folderYear.map { ($0, folderMonth) } }
        set { folderYear = newValue?.year; folderMonth = newValue?.month }
    }
    public var folderYear: Int?
    public var folderMonth: Int?

    public enum Confidence: String, Codable, Sendable { case high, medium, low }

    public static func from(_ scan: SourceScan) -> DateSummary {
        let hint = DateReader.yearMonthInFolderName(scan.folder.lastPathComponent)
        let all = scan.files.compactMap { f in f.date.map { (f, $0) } }.filter { $0.0.kind == .photo || $0.0.kind == .video }
        let reliable = all.filter { $0.1.source.isReliable }
        let undated = all.count - reliable.count
        // Use reliable dates when most files have them; otherwise fall back to everything.
        var used = reliable.count >= max(1, all.count / 5) ? reliable : all
        var outliers: [String] = []
        if used.count >= 5 {
            let sorted = used.map(\.1.date).sorted()
            let median = sorted[sorted.count / 2]
            let twoYears: TimeInterval = 2 * 365 * 86_400
            let far = used.filter { abs($0.1.date.timeIntervalSince(median)) > twoYears }
            if !far.isEmpty, far.count * 10 <= used.count {
                outliers = far.map(\.0.relativePath)
                used.removeAll { abs($0.1.date.timeIntervalSince(median)) > twoYears }
            }
        }
        let dates = used.map(\.1.date)
        let sources = Dictionary(grouping: used, by: { $0.1.source }).mapValues(\.count)
        let main = sources.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key
        let reliableShare = all.isEmpty ? 0 : Double(reliable.count) / Double(all.count)
        let confidence: Confidence
        if dates.isEmpty { confidence = .low }
        else if reliableShare >= 0.8, main == .exif || main == .video || main == .takeout { confidence = .high }
        else if reliableShare >= 0.5 { confidence = .medium }
        else { confidence = .low }
        var s = DateSummary(start: dates.min(), end: dates.max(), mainSource: main, confidence: confidence,
                            outliers: outliers, undatedCount: undated)
        s.folderNameHint = hint
        return s
    }

    /// True when the folder name's year (and month) disagree with the files' dates.
    public var folderNameDisagrees: Bool {
        guard let y = folderYear, let start, let end else { return false }
        let a = Floating.ym(start), b = Floating.ym(end)
        if y < a.year || y > b.year { return true }
        if let m = folderMonth, a.year == b.year, a.year == y, m < a.month || m > b.month { return true }
        return false
    }
}

public enum AlbumError: LocalizedError, Sendable {
    case notAFolder(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .notAFolder(let p): "Not a folder: \(p)"
        case .invalid(let s): s
        }
    }
}
