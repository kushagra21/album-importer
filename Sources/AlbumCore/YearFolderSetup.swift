import Foundation

/// Creates year folders in a library (and the library folder itself, if it doesn't exist yet), the
/// same careful way as an import: a plan, a dry run, unlocking only with permission, a log, and a
/// history entry. Only creates folders; never renames or removes one.
public enum YearFolderSetup {
    public struct Result: Sendable {
        public var created: [String]
        public var skipped: [String]
        public var failures: [String]
        public var lockChanges: [String]
        public var runFolder: URL?
        public var report: String

        public var succeeded: Bool { failures.isEmpty }

        public static func failure(_ message: String) -> Result {
            Result(created: [], skipped: [], failures: [message], lockChanges: [], runFolder: nil, report: "")
        }
    }

    public static func plan(_ ranges: [ClosedRange<Int>], libraryRoot: URL) -> ImportPlan {
        var steps: [PlanStep] = []
        if !FileManager.default.fileExists(atPath: libraryRoot.path) {
            steps.append(PlanStep(seq: 1, type: "mkdir", src: nil, dst: libraryRoot.path, size: nil))
        }
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let dst = libraryRoot.appendingPathComponent(YearFolders.name(r.lowerBound, r.upperBound)).path
            steps.append(PlanStep(seq: steps.count + 1, type: "mkdir", src: nil, dst: dst, size: nil))
        }
        return ImportPlan(plan: steps, libraryRoot: libraryRoot.path, albumPath: libraryRoot.path, createsYearFolder: nil)
    }

    /// `allowUnlock`: the owner allowed unlocking the library folder if it's Locked (locked again after).
    /// `lockNewFolders`: lock each new year folder, as the owner keeps them.
    public static func create(_ ranges: [ClosedRange<Int>], libraryRoot: URL, records: RecordsFolder?,
                              allowUnlock: Bool, lockNewFolders: Bool) throws -> Result {
        let existing = YearFolders.list(in: libraryRoot)
        var result = Result(created: [], skipped: [], failures: [], lockChanges: [], runFolder: nil, report: "")
        let problems = YearFolders.problems(in: ranges, existing: existing)
        guard problems.isEmpty, !ranges.isEmpty else {
            result.failures = ranges.isEmpty ? ["No year folders to create."] : problems
            return result
        }
        let plan = plan(ranges, libraryRoot: libraryRoot)
        let runFolder = try records.map { try $0.makeRunFolder(slug: "year_folders") }
        result.runFolder = runFolder
        if let runFolder { try RecordsFolder.writePlan(plan, to: runFolder) }

        let dry = DryRun.check(plan)
        guard dry.problems.isEmpty else {
            result.failures = dry.problems
            return finish(result, libraryRoot: libraryRoot, records: records)
        }
        var keeper: LockKeeper?
        if !dry.lockedFolders.isEmpty {
            guard allowUnlock, let runFolder else {
                result.failures = dry.lockedFolders.map { "Locked: \($0) (permission to unlock wasn't given)" }
                return finish(result, libraryRoot: libraryRoot, records: records)
            }
            keeper = try LockKeeper(logURL: runFolder.appendingPathComponent("lock_log.csv"))
            for f in dry.lockedFolders {
                try keeper!.unlock(URL(fileURLWithPath: f))
                result.lockChanges.append("Unlocked \((f as NSString).lastPathComponent)")
            }
        }
        let log = (runFolder ?? FileManager.default.temporaryDirectory).appendingPathComponent("log_year_folders.csv")
        let run = try Executor.run(plan, log: log)
        for s in plan.plan {
            let name = (s.dst as NSString).lastPathComponent
            if run.done.contains(s.seq) { result.created.append(name) }
            if run.skipped.contains(s.seq) { result.skipped.append(name) }
        }
        result.failures += run.failed.map { "step \($0.step): \($0.message)" }

        if lockNewFolders, let runFolder {
            let k = try keeper ?? LockKeeper(logURL: runFolder.appendingPathComponent("lock_log.csv"))
            keeper = k
            for s in plan.plan where run.done.contains(s.seq) && s.dst != libraryRoot.path {
                do {
                    try k.lock(URL(fileURLWithPath: s.dst), reason: "new year folder")
                    result.lockChanges.append("Locked \((s.dst as NSString).lastPathComponent)")
                } catch { result.failures.append(error.localizedDescription) }
            }
        }
        for f in keeper?.unlockedByUs.reversed() ?? [] {
            do {
                try keeper!.lock(f)
                result.lockChanges.append("Locked \(f.lastPathComponent) again")
            } catch {
                result.failures.append("Couldn't lock \(f.lastPathComponent) again: \(error.localizedDescription). Lock it in Finder.")
            }
        }
        return finish(result, libraryRoot: libraryRoot, records: records)
    }

    private static func finish(_ r: Result, libraryRoot: URL, records: RecordsFolder?) -> Result {
        var r = r
        let time = Floating.format(Floating.fromInstant(Date()), "HH:mm")
        var lines = ["## Year folders (\(time))" + (r.runFolder.map { " — `runs/\($0.lastPathComponent)`" } ?? "")]
        lines.append("- **Library:** `\(libraryRoot.path)`.")
        if !r.created.isEmpty { lines.append("- **Created:** " + r.created.map { "`\($0)`" }.joined(separator: ", ") + ".") }
        if !r.skipped.isEmpty { lines.append("- **Already there:** " + r.skipped.map { "`\($0)`" }.joined(separator: ", ") + ".") }
        if !r.lockChanges.isEmpty { lines.append("- **Locks:** " + r.lockChanges.joined(separator: "; ") + ". Logged in `lock_log.csv`.") }
        if !r.failures.isEmpty { lines.append("- **Problems:** " + r.failures.joined(separator: "; ")) }
        lines.append("- Made with Album Importer.")
        r.report = lines.joined(separator: "\n") + "\n"
        if let folder = r.runFolder { try? Data(r.report.utf8).write(to: folder.appendingPathComponent("run_report.md")) }
        if !r.created.isEmpty { try? records?.appendHistory(r.report) }
        return r
    }
}
