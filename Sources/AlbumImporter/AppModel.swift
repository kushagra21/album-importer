import AlbumCore
import AppKit
import Foundation
import Observation

/// One folder the owner added, from scanning through review to the finished copy.
@MainActor @Observable
final class ImportItem: Identifiable {
    enum State {
        case scanning(String)
        case review
        case failed(String)
        case running
        case finished(ImportJob.Result)
    }

    let id = UUID()
    let folder: URL
    var state: State = .scanning("Starting…")
    var proposal: Proposal?
    var notices: [Notice] = []
    var checkingContents: (done: Int, total: Int)?
    /// The scan stopped because the library wasn't connected; it runs again when it is.
    var waitingForLibrary = false

    // While copying.
    var phase: ImportJob.Phase?
    var progress: StepProgress?
    var job: ImportJob?

    init(folder: URL) { self.folder = folder }

    var title: String { folder.lastPathComponent }

    var isBusy: Bool {
        switch state {
        case .scanning, .running: true
        default: checkingContents != nil
        }
    }
}

@MainActor @Observable
final class AppModel {
    var settings = Settings.load() {
        didSet {
            settings.save()
            if settings.libraryRoot != oldValue.libraryRoot {
                // Remember the previous library (Settings' path picker changes the root directly).
                if !settings.otherLibraries.contains(oldValue.libraryRoot) {
                    settings.otherLibraries.removeAll { $0 == settings.libraryRoot }
                    settings.otherLibraries.insert(oldValue.libraryRoot, at: 0)
                }
                libraryChanged()
            }
        }
    }
    var items: [ImportItem] = []
    var selection: ImportItem.ID?
    var index: LibraryIndex?
    var indexStatus = ""
    var isIndexing = false
    var yearFolders: [YearFolder] = []
    var showYearSetup = false
    /// Whether the library folder is there right now. Updated when drives are plugged in or removed,
    /// and by Check Again.
    private(set) var libraryAvailable = false
    /// The drive or folder that holds the library is there, so a new library folder can be created in it.
    private(set) var libraryParentExists = false
    private(set) var freeBytes: Int64?
    private(set) var lastChecked: Date?
    /// Cached indexes of the other libraries, also checked for duplicates.
    private(set) var otherIndexes: [LibraryIndex] = []

    private var activity: NSObjectProtocol?
    private var observers: [NSObjectProtocol] = []

    init() {
        updateAvailability()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.checkLibrary() }
            })
        }
        Task { await loadOtherIndexes() }
    }

    var libraryRoot: URL { URL(fileURLWithPath: settings.libraryRoot) }
    /// The library folder's own name, e.g. "Photo Library".
    var libraryName: String { libraryRoot.lastPathComponent }
    var records: RecordsFolder { settings.records }
    var recordsAvailable: Bool { FileManager.default.fileExists(atPath: settings.recordsFolder) }
    /// Albums per start year among the folders waiting to be copied, for suggesting year folders.
    var yearStats: [YearSuggest.YearStat] {
        YearSuggest.stats(from: items.compactMap { item in
            if case .review = item.state { item.proposal } else { nil }
        })
    }
    var selected: ImportItem? { items.first { $0.id == selection } }
    var isCopying: Bool { items.contains { if case .running = $0.state { true } else { false } } }

    // MARK: Library

    /// Whether the library is ready for imports, and what's wrong if not. Drives the drive icon's colour.
    struct LibraryHealth {
        enum Level { case ready, busy, warning, unavailable }
        enum Fix { case checkAgain, chooseLibrary, setUpYearFolders, openSettings }
        struct Problem: Identifiable {
            var id: String { text }
            var text: String
            var fix: Fix?
        }
        var level: Level
        var summary: String
        var problems: [Problem]
    }

    var health: LibraryHealth {
        if !libraryAvailable {
            if libraryParentExists {
                return .init(level: .warning, summary: "This library folder doesn't exist yet.",
                             problems: [.init(text: "\(libraryName) isn't there yet. Create it with its year folders.", fix: .setUpYearFolders)])
            }
            return .init(level: .unavailable, summary: "Not connected.",
                         problems: [.init(text: "The drive \(Volumes.name(of: libraryRoot)) isn't connected. It's picked up automatically when it's plugged in.", fix: .checkAgain),
                                    .init(text: "Or use another drive or folder.", fix: .chooseLibrary)])
        }
        var problems: [LibraryHealth.Problem] = []
        if !isIndexing && yearFolders.isEmpty {
            problems.append(.init(text: yearStats.isEmpty
                ? "No year folders yet. Add your photo folders first: Set Up Year Folders then suggests ranges from their dates."
                : "No year folders yet. Set Up Year Folders suggests ranges from the \(Format.count(items.count, "folder")) you've added.",
                fix: .setUpYearFolders))
        }
        if !recordsAvailable {
            problems.append(.init(text: "The records folder isn't there: \(settings.recordsFolder).", fix: .openSettings))
        }
        if let free = freeBytes {
            if free < 5 * Volumes.spare {
                problems.append(.init(text: "Only \(Format.bytes(free)) free on \(Volumes.name(of: libraryRoot)).", fix: .chooseLibrary))
            } else if let total = Volumes.totalBytes(at: libraryRoot), Double(free) < 0.05 * Double(total) {
                problems.append(.init(text: "\(Volumes.name(of: libraryRoot)) is nearly full (\(Format.bytes(free)) free).", fix: .chooseLibrary))
            }
        }
        if !problems.isEmpty {
            return .init(level: .warning, summary: problems.count == 1 ? "1 thing needs attention." : "\(problems.count) things need attention.", problems: problems)
        }
        if isIndexing { return .init(level: .busy, summary: "Getting ready: \(indexStatus)", problems: []) }
        return .init(level: .ready, summary: "Ready to use.", problems: [])
    }

    private func updateAvailability() {
        libraryAvailable = FileManager.default.fileExists(atPath: settings.libraryRoot)
        libraryParentExists = FileManager.default.fileExists(atPath: libraryRoot.deletingLastPathComponent().path)
        freeBytes = libraryParentExists ? Volumes.freeBytes(at: libraryRoot) : nil
        lastChecked = Date()
    }

    /// Looks for the library again (a drive was plugged in or removed, or Check Again was pressed).
    func checkLibrary() async {
        let wasAvailable = libraryAvailable
        updateAvailability()
        if libraryAvailable && (!wasAvailable || index == nil) {
            await refreshLibrary()
            // Folders that couldn't be scanned without the library are scanned now.
            for item in items where item.waitingForLibrary { await scan(item) }
        } else if !libraryAvailable {
            yearFolders = []
        }
    }

    /// The library location changed: start over with the new one.
    private func libraryChanged() {
        index = nil
        yearFolders = []
        indexStatus = ""
        updateAvailability()
        Task {
            await loadOtherIndexes()
            await refreshLibrary()
            if libraryAvailable && yearFolders.isEmpty { showYearSetup = true }
            // Folders under review were planned for the old library.
            for item in items {
                switch item.state {
                case .review, .failed: await scan(item)
                default: break
                }
            }
        }
    }

    /// Lets the owner pick another library folder (another drive, or a new folder).
    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where albums are stored: an existing library, or a new folder on another drive."
        if panel.runModal() == .OK, let url = panel.url { switchLibrary(to: url.path) }
    }

    func switchLibrary(to path: String) {
        guard !isCopying else { return }
        settings.switchLibrary(to: path)
    }

    private func loadOtherIndexes() async {
        let paths = settings.otherLibraries.filter { $0 != settings.libraryRoot }
        otherIndexes = await Task.detached(priority: .utility) {
            paths.compactMap { LibraryIndex.load(from: Settings.indexFile(for: $0)) }
        }.value
    }

    /// Re-reads the year folders and brings the duplicate index up to date.
    func refreshLibrary(full: Bool = false) async {
        updateAvailability()
        guard libraryAvailable, !isIndexing else { return }
        isIndexing = true
        yearFolders = YearFolders.list(in: libraryRoot)
        let root = libraryRoot
        let file = Settings.indexFile(for: settings.libraryRoot)
        let old = full ? nil : (index ?? LibraryIndex.load(from: file))
        indexStatus = "Indexing the library…"
        let idx = await Task.detached(priority: .userInitiated) { () -> LibraryIndex in
            let idx = LibraryIndex.refresh(old, root: root, full: full) { msg in
                Task { @MainActor in self.indexStatus = msg }
            }
            try? idx.save(to: file)
            return idx
        }.value
        index = idx
        indexStatus = "\(idx.fileCount.formatted()) files and \(idx.zipEntryCount.formatted()) files inside zips indexed"
        isIndexing = false
    }

    /// Creates year folders (and the library folder, if needed), then re-reads the library.
    func createYearFolders(_ ranges: [ClosedRange<Int>], allowUnlock: Bool, lockNew: Bool) async -> YearFolderSetup.Result {
        let root = libraryRoot, records = records
        let result = await Task.detached(priority: .userInitiated) {
            do {
                return try YearFolderSetup.create(ranges, libraryRoot: root, records: records, allowUnlock: allowUnlock, lockNewFolders: lockNew)
            } catch {
                return YearFolderSetup.Result.failure(error.localizedDescription)
            }
        }.value
        await refreshLibrary()
        // Folders waiting for a year folder can now use the new ones.
        for item in items {
            guard case .review = item.state, let p = item.proposal, case .newYearFolder = p.target, let year = p.startYear,
                  let found = YearFolders.folder(for: year, in: yearFolders) else { continue }
            item.proposal?.target = .yearFolder(found.folder.name)
            updateNotices(item)
        }
        return result
    }

    // MARK: Adding folders

    func add(_ urls: [URL]) {
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if url.standardizedFileURL.path.hasPrefix(libraryRoot.standardizedFileURL.path + "/") || url.standardizedFileURL == libraryRoot.standardizedFileURL {
                let item = ImportItem(folder: url)
                item.state = .failed("This folder is already inside \(libraryName).")
                items.append(item)
                selection = item.id
                continue
            }
            if items.contains(where: { $0.folder.standardizedFileURL == url.standardizedFileURL }) { continue }
            let item = ImportItem(folder: url)
            items.append(item)
            selection = item.id
            Task { await scan(item) }
        }
    }

    func scan(_ item: ImportItem) async {
        item.state = .scanning("Listing files…")
        if index == nil || yearFolders.isEmpty { await refreshLibrary() }
        guard libraryAvailable, let index else {
            item.waitingForLibrary = true
            item.state = .failed("The photo library isn't available at \(settings.libraryRoot). Connect the drive and this folder is checked automatically, or choose another library.")
            return
        }
        item.waitingForLibrary = false
        let others = otherIndexes
        let folder = item.folder
        let years = yearFolders
        let specials = settings.specialDates
        do {
            let proposal = try await Task.detached(priority: .userInitiated) { () throws -> Proposal in
                let scan = try SourceScanner.scan(folder) { msg in
                    Task { @MainActor in item.state = .scanning(msg) }
                }
                return ProposalBuilder.make(scan: scan, index: index, otherLibraries: others, yearFolders: years, specials: specials)
            }.value
            item.proposal = proposal
            item.state = .review
            updateNotices(item)
        } catch {
            item.state = .failed(error.localizedDescription)
        }
    }

    func updateNotices(_ item: ImportItem) {
        guard let p = item.proposal, let index else { return }
        item.notices = ProposalBuilder.notices(for: p, index: index, yearFolders: yearFolders, libraryRoot: libraryRoot)
    }

    func remove(_ item: ImportItem) {
        guard !item.isBusy else { return }
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = items.last?.id }
    }

    func checkContents(_ item: ImportItem) async {
        guard let p = item.proposal, let index else { return }
        item.checkingContents = (0, p.scan.files.count)
        let indexes = [index] + otherIndexes
        let updated = await Task.detached(priority: .userInitiated) {
            Duplicates.confirmByContents(p.scan, indexes: indexes, current: p.duplicates) { done, total in
                Task { @MainActor in item.checkingContents = (done, total) }
            }
        }.value
        item.proposal?.duplicates = updated
        item.proposal?.contentsChecked = true
        item.checkingContents = nil
        updateNotices(item)
    }

    // MARK: Copying

    /// What the dry run says right now, for the confirmation sheet.
    func preflight(_ item: ImportItem) -> (plan: ImportPlan?, dry: DryRunResult?, error: String?) {
        guard let p = item.proposal else { return (nil, nil, "Nothing to copy.") }
        do {
            let plan = try ImportPlan.make(for: p, libraryRoot: libraryRoot)
            return (plan, DryRun.check(plan), nil)
        } catch {
            return (nil, nil, error.localizedDescription)
        }
    }

    func start(_ item: ImportItem, allowUnlock: Bool) {
        guard let p = item.proposal else { return }
        var opts = ImportJob.Options()
        opts.allowUnlock = allowUnlock
        let job = ImportJob(proposal: p, libraryRoot: libraryRoot, records: records, options: opts)
        item.job = job
        item.phase = .planning
        item.progress = nil
        item.state = .running
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                         reason: "Copying photos to \(libraryName)")
        Task {
            let outcome: Result<ImportJob.Result, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try job.run(phase: { ph in Task { @MainActor in item.phase = ph } },
                                progress: { pr in Task { @MainActor in item.progress = pr } })
                }
            }.value
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            item.job = nil
            switch outcome {
            case .success(let r): item.state = .finished(r)
            case .failure(let e): item.state = .failed(e.localizedDescription)
            }
            // The library changed: refresh the index so later folders see the new album.
            await refreshLibrary()
            updateAvailability()
        }
    }
}
