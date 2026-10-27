import Foundation

/// Whether a source file is already somewhere in the library.
public enum DuplicateStatus: Codable, Sendable, Hashable {
    /// Not found by name and size (or by contents, if that check ran).
    case new
    /// Same name and size as a file already in the library (contents confirmed when `confirmed`).
    case duplicate([LibraryIndex.Location], confirmed: Bool)
    /// Different name, but byte-identical to a library file (found by the contents check).
    case renamedCopy([LibraryIndex.Location])
    /// Same name, different size: probably a different version (edited, resized, re-exported).
    case otherVersion([LibraryIndex.Location])

    public var isAlreadyInLibrary: Bool {
        switch self {
        case .duplicate, .renamedCopy: true
        case .new, .otherVersion: false
        }
    }

    public var locations: [LibraryIndex.Location] {
        switch self {
        case .new: []
        case .duplicate(let l, _), .renamedCopy(let l), .otherVersion(let l): l
        }
    }
}

public enum Duplicates {
    /// Name-and-size check of every media file against the index.
    public static func check(_ scan: SourceScan, index: LibraryIndex) -> [String: DuplicateStatus] {
        check(scan, indexes: [index])
    }

    /// The same check against several libraries at once: the current one plus others whose index is
    /// cached (e.g. a full drive that isn't connected), so a file is recognised wherever it is.
    public static func check(_ scan: SourceScan, indexes: [LibraryIndex]) -> [String: DuplicateStatus] {
        var out: [String: DuplicateStatus] = [:]
        for f in scan.files where f.kind != .other {
            let same = indexes.flatMap { $0.matches(name: f.name, size: f.size) }
            if !same.isEmpty {
                out[f.relativePath] = .duplicate(same, confirmed: false)
            } else {
                let named = indexes.flatMap { $0.sameName(f.name) }.filter { $0.size != f.size }
                // Common camera names (IMG_0046.JPG) repeat across cameras and years, so a name-only
                // match is only a hint when the sizes are close (within 30%).
                let close = named.filter { abs(Double($0.size - f.size)) <= 0.3 * Double(max(f.size, 1)) }
                out[f.relativePath] = close.isEmpty ? .new : .otherVersion(close)
            }
        }
        return out
    }

    public static func confirmByContents(_ scan: SourceScan, index: LibraryIndex, libraryRoot: URL,
                                         current: [String: DuplicateStatus],
                                         progress: (@Sendable (Int, Int) -> Void)? = nil,
                                         isCancelled: (@Sendable () -> Bool)? = nil) -> [String: DuplicateStatus] {
        confirmByContents(scan, indexes: [index], current: current, progress: progress, isCancelled: isCancelled)
    }

    /// Reads contents to confirm name-and-size matches and to find renamed copies (same size, any name).
    /// Library files are compared by CRC32; files inside zips use the CRC32 stored in the zip, which
    /// works even when that library's drive isn't connected. A match that can't be read stays as it was.
    public static func confirmByContents(_ scan: SourceScan, indexes: [LibraryIndex],
                                         current: [String: DuplicateStatus],
                                         progress: (@Sendable (Int, Int) -> Void)? = nil,
                                         isCancelled: (@Sendable () -> Bool)? = nil) -> [String: DuplicateStatus] {
        var out = current
        var crcCache: [String: UInt32?] = [:]
        func libraryCRC(_ loc: LibraryIndex.Location) -> UInt32? {
            if let c = loc.crc32 { return c }
            let key = loc.library + "/" + loc.path
            if let c = crcCache[key] { return c }
            let c = try? CRC32.of(file: URL(fileURLWithPath: loc.library).appendingPathComponent(loc.path))
            crcCache[key] = c
            return c
        }
        let candidates = scan.files.filter { $0.kind != .other }
        for (n, f) in candidates.enumerated() {
            if isCancelled?() == true { break }
            progress?(n, candidates.count)
            let status = current[f.relativePath] ?? .new
            let pool: [LibraryIndex.Location]
            switch status {
            case .duplicate(let locs, _): pool = locs
            case .new, .otherVersion: pool = indexes.flatMap { $0.sameSize(f.size) }
            case .renamedCopy: continue
            }
            guard !pool.isEmpty, let mine = try? CRC32.of(file: scan.folder.appendingPathComponent(f.relativePath)) else { continue }
            let readable = pool.filter { $0.size == f.size && libraryCRC($0) != nil }
            let equal = readable.filter { libraryCRC($0) == mine }
            switch status {
            case .duplicate(let locs, _):
                if !equal.isEmpty { out[f.relativePath] = .duplicate(equal, confirmed: true) }
                // Every candidate was read and none matched: a different file that happens to share name and size.
                else if readable.count == locs.count { out[f.relativePath] = .new }
            default:
                if !equal.isEmpty { out[f.relativePath] = .renamedCopy(equal) }
            }
        }
        progress?(candidates.count, candidates.count)
        return out
    }
}
