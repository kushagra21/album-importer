import CryptoKit
import Foundation
import ImageIO

/// A CSV log written row by row, flushed to disk after every row, so it survives a crash or an
/// unplugged drive. Same columns as the toolkit's logs: step,action,status,from,to,time,note.
public final class CSVLog {
    public let url: URL
    private let handle: FileHandle

    public init(url: URL, header: [String]) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AlbumError.invalid("Can't create the log \(url.path)")
        }
        handle = try FileHandle(forWritingTo: url)
        try write(header)
    }

    /// Opens an existing log to add rows (the lock log is written before and after the copy).
    public init(appendingTo url: URL, header: [String]) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            try write(header)
        } else {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        }
    }

    deinit { try? handle.close() }

    public func write(_ fields: [String]) throws {
        let line = fields.map(Self.escape).joined(separator: ",") + "\n"
        try handle.write(contentsOf: Data(line.utf8))
        try handle.synchronize()
    }

    static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func now() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date())
    }
}

public struct StepProgress: Sendable {
    public var stepsDone: Int
    public var stepsTotal: Int
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var currentFile: String
    public var bytesPerSecond: Double
}

public struct RunResult: Sendable {
    public var logURL: URL
    public var done: [Int]
    public var skipped: [Int]
    public var failed: [(step: Int, message: String)]
    public var cancelled: Bool
    public var bytesCopied: Int64
    public var seconds: TimeInterval
}

/// Runs plan steps. It can create folders and copy files, nothing else: there is no code here to
/// delete, move or overwrite anything.
public enum Executor {
    public static let logHeader = ["step", "action", "status", "from", "to", "time", "note"]

    public static func run(_ plan: ImportPlan, steps: Set<Int>? = nil, log logURL: URL,
                           progress: (@Sendable (StepProgress) -> Void)? = nil,
                           isCancelled: (@Sendable () -> Bool)? = nil) throws -> RunResult {
        let log = try CSVLog(url: logURL, header: logHeader)
        let chosen = plan.plan.filter { steps?.contains($0.seq) ?? true }
        let total = chosen.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var result = RunResult(logURL: logURL, done: [], skipped: [], failed: [], cancelled: false, bytesCopied: 0, seconds: 0)
        let started = Date()
        for (i, s) in chosen.enumerated() {
            if isCancelled?() == true { result.cancelled = true; break }
            let name = (s.dst as NSString).lastPathComponent
            progress?(StepProgress(stepsDone: i, stepsTotal: chosen.count, bytesDone: result.bytesCopied, bytesTotal: total,
                                   currentFile: name, bytesPerSecond: rate(result.bytesCopied, since: started)))
            if s.type == "mkdir" {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: s.dst, isDirectory: &isDir), isDir.boolValue {
                    try log.write([String(s.seq), "mkdir", "skipped", "", s.dst, CSVLog.now(), "already exists"])
                    result.skipped.append(s.seq)
                    continue
                }
                try log.write([String(s.seq), "mkdir", "starting", "", s.dst, CSVLog.now(), ""])
                if mkdir(s.dst, 0o755) == 0 {
                    try log.write([String(s.seq), "mkdir", "done", "", s.dst, CSVLog.now(), ""])
                    result.done.append(s.seq)
                } else {
                    let msg = String(cString: strerror(errno))
                    try log.write([String(s.seq), "mkdir", "FAILED", "", s.dst, CSVLog.now(), msg])
                    result.failed.append((s.seq, msg))
                    break  // later steps depend on this folder
                }
            } else if let src = s.src {
                try log.write([String(s.seq), "copy", "starting", src, s.dst, CSVLog.now(), ""])
                let base = result.bytesCopied
                do {
                    try copyVerified(from: URL(fileURLWithPath: src), to: URL(fileURLWithPath: s.dst)) { n in
                        progress?(StepProgress(stepsDone: i, stepsTotal: chosen.count, bytesDone: base + n, bytesTotal: total,
                                               currentFile: name, bytesPerSecond: rate(base + n, since: started)))
                    }
                    result.bytesCopied += s.size ?? 0
                    try log.write([String(s.seq), "copy", "done", src, s.dst, CSVLog.now(), "verified SHA-256"])
                    result.done.append(s.seq)
                } catch {
                    try log.write([String(s.seq), "copy", "FAILED", src, s.dst, CSVLog.now(), error.localizedDescription])
                    result.failed.append((s.seq, error.localizedDescription))
                    // Stop on the first failure, so the owner can look before anything else happens.
                    break
                }
            }
        }
        result.seconds = Date().timeIntervalSince(started)
        progress?(StepProgress(stepsDone: result.done.count + result.skipped.count, stepsTotal: chosen.count,
                               bytesDone: result.bytesCopied, bytesTotal: total, currentFile: "", bytesPerSecond: rate(result.bytesCopied, since: started)))
        return result
    }

    private static func rate(_ bytes: Int64, since: Date) -> Double {
        let t = Date().timeIntervalSince(since)
        return t > 0.5 ? Double(bytes) / t : 0
    }

    /// Copies one file without ever replacing anything (exclusive create), keeps its dates, then
    /// reads the copy back and compares SHA-256 and size with the source.
    public static func copyVerified(from src: URL, to dst: URL, progress: ((Int64) -> Void)? = nil) throws {
        let inFD = open(src.path, O_RDONLY)
        guard inFD >= 0 else { throw AlbumError.invalid("Can't open \(src.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(inFD) }
        var st = stat()
        guard fstat(inFD, &st) == 0 else { throw AlbumError.invalid("Can't read \(src.lastPathComponent)") }
        let outFD = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard outFD >= 0 else {
            throw AlbumError.invalid(errno == EEXIST ? "Already exists, not overwritten: \(dst.path)"
                                                    : "Can't create \(dst.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        var sourceHash = SHA256()
        let bufSize = 4 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        var copied: Int64 = 0
        var lastReport: Int64 = 0
        do {
            while true {
                let n = read(inFD, buf, bufSize)
                if n < 0 { throw AlbumError.invalid("Read error in \(src.lastPathComponent): \(String(cString: strerror(errno)))") }
                if n == 0 { break }
                sourceHash.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                var off = 0
                while off < n {
                    let w = write(outFD, buf + off, n - off)
                    if w < 0 { throw AlbumError.invalid("Write error for \(dst.lastPathComponent): \(String(cString: strerror(errno)))") }
                    off += w
                }
                copied += Int64(n)
                if copied - lastReport >= 32 << 20 { progress?(copied); lastReport = copied }
            }
            guard fsync(outFD) == 0 else { throw AlbumError.invalid("Couldn't flush \(dst.lastPathComponent) to disk") }
            // Same modified/accessed dates as the source (like Python's shutil.copystat).
            var times = [st.st_atimespec, st.st_mtimespec]
            _ = futimens(outFD, &times)
            close(outFD)
        } catch {
            close(outFD)
            // The incomplete copy is left in place (this app never deletes); the log names it.
            throw error
        }
        // Finder's "Date Created" too, where the drive supports it.
        var values = URLResourceValues()
        values.creationDate = Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
        var dstURL = dst
        try? dstURL.setResourceValues(values)

        let copySize = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int64) ?? -1
        guard copySize == Int64(st.st_size), copied == Int64(st.st_size) else {
            throw AlbumError.invalid("verification failed (size): \(dst.path)")
        }
        guard try sha256(of: dst) == Data(sourceHash.finalize()) else {
            throw AlbumError.invalid("verification failed (SHA-256): \(dst.path)")
        }
        progress?(copied)
    }

    public static func sha256(of url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw AlbumError.invalid("Can't open \(url.lastPathComponent)") }
        defer { close(fd) }
        // Skip the cache so the check reads what is really on the drive, not what was just written.
        _ = fcntl(fd, F_NOCACHE, 1)
        var h = SHA256()
        let bufSize = 4 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }
        while true {
            let n = read(fd, buf, bufSize)
            if n < 0 { throw AlbumError.invalid("Read error in \(url.lastPathComponent)") }
            if n == 0 { break }
            h.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
        }
        return Data(h.finalize())
    }

    /// Extra checks on the pilot file: a photo must decode, a video must have a complete structure.
    public static func pilotCheck(_ url: URL, kind: MediaKind) -> String? {
        switch kind {
        case .photo:
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) != nil
            else { return "the copied photo doesn't open" }
            return nil
        case .video:
            let ext = url.pathExtension.lowercased()
            guard ["mp4", "mov", "m4v", "3gp", "3gpp", "lrv", "insv"].contains(ext) else { return nil }
            return Atoms.isComplete(url) ? nil : "the copied video's structure is incomplete"
        default:
            return nil
        }
    }
}

/// Unlocks folders for a run and locks them again afterwards, logging every change in `lock_log.csv`.
public final class LockKeeper {
    public static let header = ["time", "action", "folder", "flags_before", "flags_after"]
    private let log: CSVLog
    public private(set) var unlockedByUs: [URL] = []

    public init(logURL: URL) throws {
        log = try CSVLog(appendingTo: logURL, header: Self.header)
    }

    public func unlock(_ folder: URL) throws {
        let before = Locks.describe(folder)
        guard Locks.isLocked(folder) else {
            try log.write([Self.time(), "unlock (chflags nouchg) - no change: already unlocked", folder.path, before, before])
            return
        }
        try Locks.setLocked(folder, false)
        unlockedByUs.append(folder)
        try log.write([Self.time(), "unlock (chflags nouchg)", folder.path, before, Locks.describe(folder)])
    }

    public func lock(_ folder: URL, reason: String = "") throws {
        let before = Locks.describe(folder)
        try Locks.setLocked(folder, true)
        try log.write([Self.time(), "lock (chflags uchg)" + (reason.isEmpty ? "" : " - \(reason)"), folder.path, before, Locks.describe(folder)])
    }

    static func time() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
