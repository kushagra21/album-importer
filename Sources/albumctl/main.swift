import AlbumCore
import Foundation

// albumctl: the app's engine from the command line, for checking a folder or testing.
//
//   albumctl scan <folder> [--library <library folder>]       review a folder (read-only)
//   albumctl import <folder> --event "Name" [--library …] [--records …] [--allow-unlock] [--execute]
//   albumctl index [--library …] [--full]                         refresh the duplicate index
//   albumctl year-folders 2027-2028 2029 … [--library …] [--allow-unlock] [--no-lock] [--execute]
//
// Without --execute, `import` only prints the plan and the dry-run result.

let defaults = Settings.load()
var args = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

@MainActor func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard let command = args.first else {
    print("usage: albumctl scan|import|index …  (see the comment at the top of main.swift)")
    exit(2)
}
args.removeFirst()
let library = URL(fileURLWithPath: option("--library") ?? defaults.libraryRoot)
let records = RecordsFolder(root: URL(fileURLWithPath: option("--records") ?? defaults.recordsFolder),
                            timelineSheet: option("--timeline") ?? defaults.timelineSheet)
let indexFile = URL(fileURLWithPath: option("--index") ?? Settings.indexFile(for: library.path).path)

@MainActor func loadIndex(full: Bool = false) -> LibraryIndex {
    let old = LibraryIndex.load(from: indexFile)
    let idx = LibraryIndex.refresh(old, root: library, full: full) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    try? idx.save(to: indexFile)
    return idx
}

switch command {
case "year-folders":
    let execute = flag("--execute"), allowUnlock = flag("--allow-unlock"), noLock = flag("--no-lock")
    var ranges: [ClosedRange<Int>] = []
    for a in args {
        let parts = a.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count) else { fail("Write ranges as 2027-2028 or 2029.") }
        ranges.append(min(parts[0], parts.last!)...max(parts[0], parts.last!))
    }
    let existing = YearFolders.list(in: library)
    print("Library: \(library.path)\(FileManager.default.fileExists(atPath: library.path) ? "" : " (will be created)")")
    print("Existing: " + (existing.isEmpty ? "none" : existing.map(\.name).joined(separator: ", ")))
    print("New:      " + ranges.map { YearFolders.name($0.lowerBound, $0.upperBound) }.joined(separator: ", "))
    for prob in YearFolders.problems(in: ranges, existing: existing) { print("  ✖ \(prob)") }
    guard execute else { print("Dry run only; add --execute to create them."); break }
    do {
        let r = try YearFolderSetup.create(ranges, libraryRoot: library, records: records, allowUnlock: allowUnlock, lockNewFolders: !noLock)
        print(r.report)
        exit(r.succeeded ? 0 : 1)
    } catch { fail(error.localizedDescription) }

case "index":
    let idx = loadIndex(full: flag("--full"))
    print("\(idx.fileCount) files and \(idx.zipEntryCount) files inside zips in \(idx.dirs.count) folders.")

case "scan", "import":
    let execute = flag("--execute"), allowUnlock = flag("--allow-unlock"), checkContents = flag("--contents")
    let event = option("--event")
    let yearFolderOverride = option("--year-folder")
    guard let folderPath = args.first else { fail("Give the folder to import.") }
    let scan: SourceScan
    do { scan = try SourceScanner.scan(URL(fileURLWithPath: folderPath)) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) } }
    catch { fail(error.localizedDescription) }
    let index = loadIndex()
    let years = YearFolders.list(in: library)
    var p = ProposalBuilder.make(scan: scan, index: index, yearFolders: years, specials: defaults.specialDates)
    if let event { p.eventName = Naming.clean(event) }
    if let y = yearFolderOverride {
        p.target = years.contains { $0.name == y } ? .yearFolder(y) : .newYearFolder(y)
    }
    if checkContents {
        p.duplicates = Duplicates.confirmByContents(scan, index: index, libraryRoot: library, current: p.duplicates)
        p.contentsChecked = true
    }
    let d = p.dates
    print("Folder:      \(scan.folder.path)")
    print("Files:       \(scan.count(.photo)) photos, \(scan.count(.video)) videos, \(scan.count(.audio)) audio, \(scan.count(.sidecar)) notes, \(scan.count(.other)) other (\(Format.bytes(scan.size(of: Set(MediaKind.allCases)))))")
    if let s = d.start, let e = d.end { print("Dates:       \(Floating.format(s)) to \(Floating.format(e)) (\(d.mainSource?.rawValue ?? "?"), \(d.confidence.rawValue))") }
    if !scan.cameras.isEmpty { print("Cameras:     " + scan.cameras.sorted { $0.value > $1.value }.map { "\($0.key) (\($0.value))" }.joined(separator: ", ")) }
    print("Event name:  \(p.eventName.isEmpty ? "—" : p.eventName)  [\(p.eventNameOrigin)]")
    print("Album:       \(p.albumRelativePath.map { library.lastPathComponent + "/" + $0 } ?? "—")")
    print("To copy:     \(p.filesToCopy.count) files; \(p.alreadyInLibrary.count) already in the library")
    for n in ProposalBuilder.notices(for: p, index: index, yearFolders: years, libraryRoot: library) {
        let mark = switch n.level { case .blocker: "✖"; case .warning: "!"; case .info: "·" }
        print("  \(mark) \(n.text)")
    }
    guard command == "import" else { break }
    let plan: ImportPlan
    do { plan = try ImportPlan.make(for: p, libraryRoot: library) } catch { fail(error.localizedDescription) }
    let dry = DryRun.check(plan)
    print("\nPlan: \(plan.plan.count) steps, \(Format.bytes(plan.totalBytes)) to copy.")
    for prob in dry.problems { print("  ✖ \(prob)") }
    for l in dry.lockedFolders { print("  ! Locked: \(l)\(allowUnlock ? " (will be unlocked and locked again)" : " (add --allow-unlock)")") }
    guard execute else { print("Dry run only; nothing was changed. Add --execute to copy."); break }
    if ProposalBuilder.notices(for: p, index: index, yearFolders: years, libraryRoot: library).contains(where: { $0.level == .blocker }) {
        fail("Fix the ✖ items first.")
    }
    var opts = ImportJob.Options()
    opts.allowUnlock = allowUnlock
    let job = ImportJob(proposal: p, libraryRoot: library, records: records, options: opts)
    do {
        let r = try job.run(phase: { print("→ \($0.rawValue)") }, progress: { pr in
            if pr.stepsTotal > 0 { FileHandle.standardError.write(Data("\r  \(pr.stepsDone)/\(pr.stepsTotal)  \(Format.bytes(pr.bytesDone))   ".utf8)) }
        })
        print("\n" + r.report)
        exit(r.succeeded ? 0 : 1)
    } catch { fail(error.localizedDescription) }

default:
    fail("Unknown command \(command).")
}
