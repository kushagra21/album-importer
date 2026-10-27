import Foundation

/// One step of a copy plan. Same shape as the `plan.json` read by `toolkit/run_copy.py`, so a run
/// made by the app can be checked or continued with the toolkit too.
public struct PlanStep: Codable, Sendable, Hashable {
    public var seq: Int
    /// "mkdir" or "copy".
    public var type: String
    public var src: String?
    public var dst: String
    public var size: Int64?

    public var isCopy: Bool { type == "copy" }
}

public struct ImportPlan: Codable, Sendable {
    public var plan: [PlanStep]
    /// The library folder (e.g. `Photo Library`).
    public var libraryRoot: String
    public var albumPath: String
    /// True when the plan creates a new year folder.
    public var createsYearFolder: String?

    public var copies: [PlanStep] { plan.filter(\.isCopy) }
    public var totalBytes: Int64 { copies.reduce(0) { $0 + ($1.size ?? 0) } }

    public static func make(for p: Proposal, libraryRoot: URL) throws -> ImportPlan {
        guard let rel = p.albumRelativePath else { throw AlbumError.invalid("Choose a year folder first.") }
        let album = libraryRoot.appendingPathComponent(rel)
        var steps: [PlanStep] = []
        func add(_ type: String, _ src: String?, _ dst: String, _ size: Int64? = nil) {
            steps.append(PlanStep(seq: steps.count + 1, type: type, src: src, dst: dst, size: size))
        }
        var createdYear: String?
        if case .newYearFolder(let name) = p.target {
            add("mkdir", nil, libraryRoot.appendingPathComponent(name).path)
            createdYear = name
        }
        add("mkdir", nil, album.path)
        let files = p.filesToCopy.sorted { $0.destinationPath.localizedStandardCompare($1.destinationPath) == .orderedAscending }
        // Subfolders kept inside the album (event subfolders like Sony/, iPhone/), parents first.
        var dirs = Set<String>()
        for f in files {
            var parts = f.destinationPath.split(separator: "/").map(String.init).dropLast()
            while !parts.isEmpty {
                dirs.insert(parts.joined(separator: "/"))
                parts = parts.dropLast()
            }
        }
        for d in dirs.sorted(by: { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }) {
            add("mkdir", nil, album.appendingPathComponent(d).path)
        }
        for f in files {
            add("copy", p.scan.folder.appendingPathComponent(f.relativePath).path, album.appendingPathComponent(f.destinationPath).path, f.size)
        }
        return ImportPlan(plan: steps, libraryRoot: libraryRoot.path, albumPath: album.path, createsYearFolder: createdYear)
    }
}

/// The result of checking a plan without changing anything (the dry run).
public struct DryRunResult: Sendable {
    public var problems: [String]
    /// Existing folders that must be unlocked for the plan to run (owner's permission needed).
    public var lockedFolders: [String]
    public var bytesToCopy: Int64
    public var freeBytes: Int64?

    public var isOK: Bool { problems.isEmpty }
}

public enum DryRun {
    /// Simulates every step in order, like `run_copy.py` without `--execute`. Nothing is written.
    public static func check(_ plan: ImportPlan, steps: Set<Int>? = nil, assumeUnlocked: Set<String> = []) -> DryRunResult {
        var problems: [String] = []
        var locked: [String] = []
        var willExist = Set<String>()
        var seenDst = Set<String>()
        var bytes: Int64 = 0
        func exists(_ p: String) -> Bool {
            var st = stat()
            return lstat(p, &st) == 0
        }
        for s in plan.plan where steps?.contains(s.seq) ?? true {
            let parent = (s.dst as NSString).deletingLastPathComponent
            if seenDst.contains(s.dst) { problems.append("step \(s.seq): two steps write \(s.dst)") }
            seenDst.insert(s.dst)
            if exists(s.dst) {
                // An mkdir whose folder already exists (e.g. from the pilot) is skipped, not a problem.
                if s.type == "mkdir" { willExist.insert(s.dst); continue }
                problems.append("step \(s.seq): already exists, nothing will be overwritten: \(s.dst)")
            }
            if !willExist.contains(parent) {
                if !exists(parent) {
                    problems.append("step \(s.seq): folder missing: \(parent)")
                } else {
                    let url = URL(fileURLWithPath: parent)
                    if Locks.isSystemLocked(url) {
                        problems.append("step \(s.seq): \(parent) is system-locked (schg); only an administrator can change it")
                    } else if Locks.isLocked(url), !assumeUnlocked.contains(parent) {
                        if !locked.contains(parent) { locked.append(parent) }
                    } else if access(parent, W_OK) != 0 {
                        problems.append("step \(s.seq): no permission to write in \(parent)")
                    }
                }
            }
            if s.isCopy, let src = s.src {
                var st = stat()
                if lstat(src, &st) != 0 {
                    problems.append("step \(s.seq): source missing: \(src)")
                } else if let size = s.size, Int64(st.st_size) != size {
                    problems.append("step \(s.seq): source changed since it was scanned: \(src)")
                }
                bytes += s.size ?? Int64(st.st_size)
            } else {
                willExist.insert(s.dst)
            }
        }
        let free = Volumes.freeBytes(at: URL(fileURLWithPath: plan.libraryRoot))
        if let cap = free, cap < bytes + Volumes.spare {
            problems.append("not enough free space: \(Format.bytes(bytes)) to copy, \(Format.bytes(cap)) free (1 GB kept spare)")
        }
        return DryRunResult(problems: problems, lockedFolders: locked, bytesToCopy: bytes, freeBytes: free)
    }
}

public enum Volumes {
    /// Always left free on the destination drive.
    public static let spare: Int64 = 1 << 30

    /// Free space on the drive holding `url` (or its nearest existing parent folder).
    public static func freeBytes(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u.deleteLastPathComponent() }
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeTotalCapacityKey]),
              let cap = v.volumeAvailableCapacity else { return nil }
        return Int64(cap)
    }

    public static func totalBytes(at url: URL) -> Int64? {
        guard let cap = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity else { return nil }
        return Int64(cap)
    }

    /// The drive's name: "/Volumes/Photos Drive/Photo Library" → "Photos Drive"; this Mac's disk → "this Mac".
    public static func name(of url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : "this Mac"
    }
}

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    /// "1 photo", "12 photos".
    public static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : plural ?? singular + "s")"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
}
