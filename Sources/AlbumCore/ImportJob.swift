import Foundation

/// Runs one import carefully: plan → dry run → unlock (with
/// permission) → pilot one file and check it → copy the rest → verify → lock again → update records.
public final class ImportJob: @unchecked Sendable {
    public enum Phase: String, Sendable {
        case planning = "Writing the plan"
        case dryRun = "Checking the plan (dry run)"
        case unlocking = "Unlocking"
        case pilot = "Copying one file first (pilot)"
        case copying = "Copying"
        case verifying = "Verifying"
        case locking = "Locking again"
        case records = "Updating the timeline and history"
        case finished = "Done"
    }

    public struct Options: Sendable {
        /// The owner allowed unlocking the folders the dry run found locked.
        public var allowUnlock = false
        /// Lock a newly created year folder after the run, like the others.
        public var lockNewYearFolder = true
        public var updateTimeline = true
        public var appendHistory = true

        public init() {}
    }

    public struct Result: Sendable {
        public var runFolder: URL
        public var albumPath: String
        public var copied: Int
        public var bytes: Int64
        public var seconds: TimeInterval
        public var failures: [String]
        public var cancelled: Bool
        public var lockChanges: [String]
        public var timelineOrder: Int?
        public var notes: [String]
        public var report: String

        public var succeeded: Bool { failures.isEmpty && !cancelled }
    }

    public let proposal: Proposal
    public let libraryRoot: URL
    public let records: RecordsFolder
    public let options: Options
    private let cancelFlag = Flag()

    public init(proposal: Proposal, libraryRoot: URL, records: RecordsFolder, options: Options) {
        self.proposal = proposal
        self.libraryRoot = libraryRoot
        self.records = records
        self.options = options
    }

    /// Stops after the file being copied now (a file is never left half-copied by a cancel).
    public func cancel() { cancelFlag.set() }

    public func run(phase: @escaping @Sendable (Phase) -> Void, progress: @escaping @Sendable (StepProgress) -> Void) throws -> Result {
        phase(.planning)
        let plan = try ImportPlan.make(for: proposal, libraryRoot: libraryRoot)
        let runFolder = try records.makeRunFolder(slug: "import_" + Naming.slug(proposal.eventName))
        try RecordsFolder.writePlan(plan, to: runFolder)
        var result = Result(runFolder: runFolder, albumPath: plan.albumPath, copied: 0, bytes: 0, seconds: 0, failures: [],
                            cancelled: false, lockChanges: [], timelineOrder: nil, notes: [], report: "")
        let started = Date()

        phase(.dryRun)
        var dry = DryRun.check(plan)
        guard dry.isOK else {
            result.failures = dry.problems
            result.report = report(result, plan: plan, pilot: nil, dry: dry)
            try? Data(result.report.utf8).write(to: runFolder.appendingPathComponent("run_report.md"))
            return result
        }

        // Unlock only what the dry run named, and only with the owner's permission.
        let lockLog = runFolder.appendingPathComponent("lock_log.csv")
        var keeper: LockKeeper?
        if !dry.lockedFolders.isEmpty {
            guard options.allowUnlock else {
                result.failures = dry.lockedFolders.map { "Locked: \($0) (permission to unlock wasn't given)" }
                result.report = report(result, plan: plan, pilot: nil, dry: dry)
                try? Data(result.report.utf8).write(to: runFolder.appendingPathComponent("run_report.md"))
                return result
            }
            phase(.unlocking)
            keeper = try LockKeeper(logURL: lockLog)
            do {
                for folder in dry.lockedFolders {
                    try keeper!.unlock(URL(fileURLWithPath: folder))
                    result.lockChanges.append("Unlocked \((folder as NSString).lastPathComponent)")
                }
            } catch {
                // Put back any lock already removed before giving up.
                result.failures = [error.localizedDescription]
                relock(keeper, plan: plan, result: &result)
                result.report = report(result, plan: plan, pilot: nil, dry: dry)
                try? Data(result.report.utf8).write(to: runFolder.appendingPathComponent("run_report.md"))
                return result
            }
            dry = DryRun.check(plan)
            guard dry.isOK else {
                result.failures = dry.problems
                relock(keeper, plan: plan, result: &result)
                result.report = report(result, plan: plan, pilot: nil, dry: dry)
                try? Data(result.report.utf8).write(to: runFolder.appendingPathComponent("run_report.md"))
                return result
            }
        }

        // Pilot: every folder, plus the smallest file.
        phase(.pilot)
        let copies = plan.copies
        let pilotCopy = copies.min { ($0.size ?? 0, $0.seq) < ($1.size ?? 0, $1.seq) }
        let pilotSteps = Set(plan.plan.filter { !$0.isCopy }.map(\.seq) + (pilotCopy.map { [$0.seq] } ?? []))
        let pilotRun = try Executor.run(plan, steps: pilotSteps, log: newLogURL(in: runFolder), progress: progress,
                                        isCancelled: { [cancelFlag] in cancelFlag.isSet })
        var pilotNote: String?
        result.copied += pilotRun.done.filter { s in copies.contains { $0.seq == s } }.count
        result.bytes += pilotRun.bytesCopied
        if !pilotRun.failed.isEmpty {
            result.failures = pilotRun.failed.map { "step \($0.step): \($0.message)" }
        } else if let p = pilotCopy {
            let kind = proposal.scan.files.first { proposal.scan.folder.appendingPathComponent($0.relativePath).path == p.src }?.kind ?? .other
            if let problem = Executor.pilotCheck(URL(fileURLWithPath: p.dst), kind: kind) {
                result.failures = ["Pilot \((p.dst as NSString).lastPathComponent): \(problem)"]
            } else {
                pilotNote = "`\((p.dst as NSString).lastPathComponent)` (\(Format.bytes(p.size ?? 0))): byte-identical (SHA-256), date kept"
                    + (kind == .photo ? ", opens as a photo" : kind == .video ? ", complete video structure" : "")
                    + ". Log: `\(pilotRun.logURL.lastPathComponent)`."
            }
        }
        result.cancelled = pilotRun.cancelled

        // The rest.
        if result.failures.isEmpty, !result.cancelled {
            let rest = Set(copies.map(\.seq)).subtracting(pilotSteps)
            if !rest.isEmpty {
                phase(.copying)
                let run = try Executor.run(plan, steps: rest, log: newLogURL(in: runFolder), progress: progress,
                                           isCancelled: { [cancelFlag] in cancelFlag.isSet })
                result.copied += run.done.count
                result.bytes += run.bytesCopied
                result.failures += run.failed.map { "step \($0.step): \($0.message)" }
                result.cancelled = run.cancelled
                result.notes.append("Full run log: `\(run.logURL.lastPathComponent)`.")
            }
        }

        // Final check: every copied file is there with the source's size and date.
        phase(.verifying)
        var verified = 0
        for s in copies {
            guard let src = s.src else { continue }
            var a = stat(), b = stat()
            guard lstat(s.dst, &b) == 0 else { continue }  // not copied (cancelled or failed)
            if lstat(src, &a) == 0, a.st_size == b.st_size, a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec {
                verified += 1
            } else {
                result.failures.append("After the run, \((s.dst as NSString).lastPathComponent) doesn't match its source (size or date).")
            }
        }
        result.notes.append("\(verified) of \(Format.count(copies.count, "file")) are in place with the same size and date as the originals.")

        phase(.locking)
        relock(keeper, plan: plan, result: &result, lockLog: lockLog)
        result.seconds = Date().timeIntervalSince(started)

        if result.copied > 0 {
            phase(.records)
            if options.updateTimeline, result.succeeded {
                do { try updateTimeline(runFolder: runFolder, result: &result) } catch {
                    result.notes.append("The timeline sheet wasn't updated: \(error.localizedDescription)")
                }
            }
        }
        result.report = report(result, plan: plan, pilot: pilotNote, dry: dry)
        try? Data(result.report.utf8).write(to: runFolder.appendingPathComponent("run_report.md"))
        if options.appendHistory, result.copied > 0 || !result.lockChanges.isEmpty {
            try? records.appendHistory(result.report)
        }
        phase(.finished)
        return result
    }

    private func relock(_ keeper: LockKeeper?, plan: ImportPlan, result: inout Result, lockLog: URL? = nil) {
        if let keeper {
            for folder in keeper.unlockedByUs.reversed() {
                do {
                    try keeper.lock(folder)
                    result.lockChanges.append("Locked \(folder.lastPathComponent) again")
                } catch {
                    result.failures.append("Couldn't lock \(folder.lastPathComponent) again: \(error.localizedDescription). Lock it in Finder (Get Info > Locked).")
                }
            }
        }
        if let created = plan.createsYearFolder, options.lockNewYearFolder, let lockLog {
            let url = libraryRoot.appendingPathComponent(created)
            if FileManager.default.fileExists(atPath: url.path), !Locks.isLocked(url) {
                do {
                    let k = try keeper ?? LockKeeper(logURL: lockLog)
                    try k.lock(url, reason: "new year folder")
                    result.lockChanges.append("Locked the new year folder \(created)")
                } catch {
                    result.notes.append("The new year folder \(created) couldn't be locked: \(error.localizedDescription)")
                }
            }
        }
    }

    private func updateTimeline(runFolder: URL, result: inout Result) throws {
        let sheet = records.timelineSheet
        if FileManager.default.fileExists(atPath: sheet.path) {
            try FileManager.default.copyItem(at: sheet, to: runFolder.appendingPathComponent("timeline_before_this_run.xlsx"))
        } else {
            // A new library: start its timeline sheet.
            try TimelineSheet.createEmpty(at: sheet)
            result.notes.append("A new timeline sheet was created at `\(sheet.path)`.")
        }
        let p = proposal
        let start = p.dates.start.map { Floating.format($0, "yyyy-MM") } ?? p.dates.folderYear.map(String.init) ?? ""
        let end = p.dates.end.map { Floating.format($0, "yyyy-MM") } ?? start
        var months: TimelineSheet.Value = .empty
        if let s = p.dates.start, let e = p.dates.end {
            let a = Floating.ym(s), b = Floating.ym(e)
            months = .number(Double((b.year - a.year) * 12 + b.month - a.month + 1))
        }
        let copied = p.filesToCopy
        let photos = copied.filter { $0.kind == .photo }.count, videos = copied.filter { $0.kind == .video }.count
        let gb = Double(copied.reduce(0) { $0 + $1.size }) / 1e9
        let subfolders = Set(copied.compactMap { f -> String? in
            let d = (f.destinationPath as NSString).deletingLastPathComponent
            return d.isEmpty ? nil : d
        }).count
        var note = "Copied with Album Importer on \(Floating.format(Floating.fromInstant(Date()), "yyyy-MM-dd")) to \(Volumes.name(of: libraryRoot)) (SHA-256 verified; source unchanged)"
        if !p.alreadyInLibrary.isEmpty, !p.copyDuplicates { note += "; \(p.alreadyInLibrary.count) files already in the library were skipped" }
        if let cam = p.scan.cameras.max(by: { $0.value < $1.value })?.key { note += "; camera: \(cam)" }
        let values: [String: TimelineSheet.Value] = [
            "start": .text(start), "end": .text(end), "months": months,
            "year": p.startYear.map { .number(Double($0)) } ?? .empty,
            "entry_name": .text(p.eventName), "kind": .text("event"), "period": .empty,
            "new_path": .text(libraryRoot.lastPathComponent + "/" + (p.albumRelativePath ?? "")),
            "old_path": .text(Self.shortSourcePath(p.scan.folder)),
            "album_folders": .number(Double(1 + subfolders)), "photos": .number(Double(photos)), "videos": .number(Double(videos)),
            "size_gb": .number((gb * 100).rounded() / 100), "date_confidence": .text(p.dates.confidence.rawValue),
            "notes": .text(note),
        ]
        let outcome = try TimelineSheet.addEntry(to: sheet, values: values, year: p.startYear)
        result.timelineOrder = outcome.order
        result.notes.append("Timeline sheet: now \(Format.count(outcome.totalEntries, "entry", "entries")); this album is entry \(outcome.order)."
            + (FileManager.default.fileExists(atPath: runFolder.appendingPathComponent("timeline_before_this_run.xlsx").path)
               ? " The sheet from before this run is saved as `timeline_before_this_run.xlsx`." : ""))
        result.notes += outcome.notes
    }

    public static func sourceName(_ s: DateSource) -> String {
        switch s {
        case .exif: "camera data (EXIF)"
        case .video: "video metadata"
        case .takeout: "Google Takeout notes"
        case .filename: "file names"
        case .modified: "modified dates only"
        }
    }

    /// `/Volumes/Camera Card/EOS` → `Camera Card/EOS`, as the timeline's old_path column writes it.
    static func shortSourcePath(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p.hasPrefix("/Volumes/") ? String(p.dropFirst("/Volumes/".count)) : p
    }

    private func newLogURL(in folder: URL) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        var url = folder.appendingPathComponent("log_\(stamp).csv")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("log_\(stamp)-\(n).csv")
            n += 1
        }
        return url
    }

    private func report(_ r: Result, plan: ImportPlan, pilot: String?, dry: DryRunResult) -> String {
        let p = proposal
        let time = Floating.format(Floating.fromInstant(Date()), "HH:mm")
        var lines: [String] = []
        lines.append("## Import: \(p.eventName) (\(time)) — `runs/\(r.runFolder.lastPathComponent)`")
        let media = p.scan.media
        let range: String = {
            guard let s = p.dates.start, let e = p.dates.end else { return "no dates found" }
            let a = Floating.format(s, "d MMM yyyy"), b = Floating.format(e, "d MMM yyyy")
            return a == b ? "all from \(a)" : "\(a) to \(b)"
        }()
        lines.append("- **Source:** `\(p.scan.folder.path)`, \(Format.count(media.count, "file")) (\(Format.count(p.scan.count(.photo), "photo")), \(Format.count(p.scan.count(.video), "video")), \(p.scan.count(.audio)) audio), \(Format.bytes(p.scan.size(of: [.photo, .video, .audio]))), \(range). Dates from \(p.dates.mainSource.map(Self.sourceName) ?? "—"), confidence \(p.dates.confidence.rawValue).")
        lines.append("- **Copied** (not moved, so the source is unchanged) to `\(libraryRoot.lastPathComponent)/\(p.albumRelativePath ?? "?")/`: \(r.copied) of \(plan.copies.count) files, \(Format.bytes(r.bytes)), in \(Format.duration(r.seconds)).")
        if !p.scan.dissolvedFolders.isEmpty {
            lines.append("  - Camera folders dropped: \(p.scan.dissolvedFolders.map { "`\($0)`" }.joined(separator: ", ")).")
        }
        if plan.createsYearFolder != nil { lines.append("  - New year folder created: `\(plan.createsYearFolder!)`.") }
        if !p.alreadyInLibrary.isEmpty {
            let what = p.copyDuplicates ? "copied anyway (owner's choice)" : "skipped"
            lines.append("- **Already in the library:** \(Format.count(p.alreadyInLibrary.count, "file")), \(what)" + (p.contentsChecked ? " (contents checked)." : " (matched by name and size)."))
        }
        if !p.otherVersions.isEmpty { lines.append("- **Other versions:** \(Format.count(p.otherVersions.count, "file")) share a name with a library file but differ in size; copied.") }
        if !r.lockChanges.isEmpty { lines.append("- **Locks:** " + r.lockChanges.joined(separator: "; ") + ". Logged in `lock_log.csv`.") }
        if let pilot { lines.append("- **Pilot:** " + pilot) }
        for n in r.notes { lines.append("- " + n) }
        if !dry.problems.isEmpty { lines.append("- **Dry run found problems, so nothing was copied:** " + dry.problems.prefix(5).joined(separator: "; ")) }
        if !r.failures.isEmpty { lines.append("- **Failures:** " + r.failures.prefix(10).joined(separator: "; ")) }
        if r.cancelled { lines.append("- **Cancelled** by the owner after \(r.copied) files. The files already copied are complete and verified.") }
        lines.append("- Made with Album Importer.")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A thread-safe one-way switch, used for Cancel.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
