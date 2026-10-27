import Foundation

/// The owner's choices for one folder, starting from the app's suggestions. Everything the Review
/// screen shows and edits.
public struct Proposal: Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public var scan: SourceScan
    public var dates: DateSummary
    public var duplicates: [String: DuplicateStatus]
    public var contentsChecked = false

    /// The event part of the name, e.g. "Beach Trip". Editable.
    public var eventName: String
    /// Where the suggested event name came from, shown next to the field.
    public var eventNameOrigin: String

    public enum Target: Codable, Sendable, Hashable {
        /// An existing year folder, by name.
        case yearFolder(String)
        /// A year folder to create first, e.g. "2027 - 2028".
        case newYearFolder(String)
    }
    public var target: Target?
    /// When set, the album goes inside this existing album (as a subfolder) instead of the year folder.
    public var insideAlbum: String?

    public var copyDuplicates = false
    public var copyOtherFiles = false

    public var albumName: String {
        let yearOnly = dates.start == nil ? dates.folderYear : nil
        return Naming.albumName(start: dates.start, end: dates.end, yearOnly: yearOnly, event: eventName)
    }

    public var yearFolderName: String? {
        switch target {
        case .yearFolder(let n), .newYearFolder(let n): n
        case nil: nil
        }
    }

    /// Path of the new album relative to the library root.
    public var albumRelativePath: String? {
        guard let y = yearFolderName else { return nil }
        if let inside = insideAlbum { return "\(y)/\(inside)/\(albumName)" }
        return "\(y)/\(albumName)"
    }

    /// The files that will be copied, given the owner's choices.
    public var filesToCopy: [SourceFile] {
        scan.files.filter { f in
            switch f.kind {
            case .other: return copyOtherFiles
            case .sidecar:
                // A sidecar follows its photo: skip it when its photo is a skipped duplicate.
                guard !copyDuplicates else { return true }
                let owner = (f.relativePath as NSString).deletingPathExtension
                let base = owner.hasSuffix(".supplemental-metadata") ? (owner as NSString).deletingPathExtension : owner
                if let status = duplicates[base], status.isAlreadyInLibrary { return false }
                return duplicates[f.relativePath]?.isAlreadyInLibrary != true
            default:
                return copyDuplicates || duplicates[f.relativePath]?.isAlreadyInLibrary != true
            }
        }
    }

    public var alreadyInLibrary: [SourceFile] { scan.files.filter { duplicates[$0.relativePath]?.isAlreadyInLibrary == true && $0.kind != .sidecar } }
    public var otherVersions: [SourceFile] {
        scan.files.filter { if case .otherVersion = duplicates[$0.relativePath] { true } else { false } }
    }

    /// Year the album starts in (decides the year folder).
    public var startYear: Int? { dates.start.map { Floating.ym($0).year } ?? dates.folderYear }
}

/// A warning or question shown on the Review card.
public struct Notice: Sendable, Hashable, Identifiable {
    public var id: String { text }
    public enum Level: Sendable, Hashable { case info, warning, blocker }
    /// Something the Review screen can offer a button for.
    public enum Action: Sendable, Hashable { case chooseLibrary, setUpYearFolders }
    public var level: Level
    public var text: String
    public var action: Action?

    public init(level: Level, text: String, action: Action? = nil) {
        self.level = level
        self.text = text
        self.action = action
    }
}

public enum ProposalBuilder {
    /// `otherLibraries`: cached indexes of other libraries (e.g. a full drive) also checked for duplicates.
    public static func make(scan: SourceScan, index: LibraryIndex, otherLibraries: [LibraryIndex] = [], yearFolders: [YearFolder],
                            specials: [Naming.SpecialDate] = Naming.defaultSpecialDates) -> Proposal {
        let dates = DateSummary.from(scan)
        var event = Naming.suggestedEvent(fromFolderName: scan.folder.lastPathComponent)
        var origin = "from the folder name"
        if event.isEmpty, let special = Naming.specialDateName(start: dates.start, end: dates.end, specials: specials) {
            event = special
            origin = "from the date (special dates list)"
        } else if event.isEmpty {
            origin = MediaTypes.looksLikeDeviceName(scan.folder.lastPathComponent)
                ? "“\(scan.folder.lastPathComponent)” looks like a camera name; type the event"
                : "type the event name"
        }
        var p = Proposal(scan: scan, dates: dates, duplicates: Duplicates.check(scan, indexes: [index] + otherLibraries),
                         eventName: event, eventNameOrigin: origin)
        if let year = p.startYear {
            if let found = YearFolders.folder(for: year, in: yearFolders) {
                p.target = .yearFolder(found.folder.name)
            } else {
                p.target = .newYearFolder(YearFolders.suggestedNewFolder(for: year, existing: yearFolders))
            }
        }
        return p
    }

    /// Everything worth telling the owner before the copy, most serious first.
    public static func notices(for p: Proposal, index: LibraryIndex, yearFolders: [YearFolder], libraryRoot: URL) -> [Notice] {
        var out: [Notice] = []
        let d = p.dates
        if p.scan.media.isEmpty { out.append(.init(level: .blocker, text: "No photos, videos or audio in this folder.")) }
        if p.eventName.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(.init(level: .blocker, text: "Type an event name for the album."))
        }
        if p.target == nil { out.append(.init(level: .blocker, text: "No date found; choose a year folder.")) }
        if case .newYearFolder(let name) = p.target, let year = p.startYear {
            if let problem = YearFolders.validateNewName(name, for: year, existing: yearFolders) {
                out.append(.init(level: .blocker, text: "New year folder: \(problem)"))
            } else {
                out.append(.init(level: .warning, text: "No year folder covers \(year). A new folder, “\(name)”, will be created in \(libraryRoot.lastPathComponent). To choose the ranges yourself, set up year folders first.", action: .setUpYearFolders))
            }
        }
        if let rel = p.albumRelativePath, FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent(rel).path) {
            out.append(.init(level: .blocker, text: "“\(rel)” already exists. Change the name, or put it inside that album."))
        }
        if case .yearFolder(let name) = p.target, let f = yearFolders.first(where: { $0.name == name }), f.isNamedYear, p.insideAlbum == nil {
            out.append(.init(level: .warning, text: "“\(name)” is a named folder, not a year range. Check this is where it belongs."))
        }
        if let s = d.start, let e = d.end, let target = p.yearFolderName, let f = yearFolders.first(where: { $0.name == target }) {
            let endYear = Floating.ym(e).year, startYear = Floating.ym(s).year
            if endYear > f.endYear {
                out.append(.init(level: .warning, text: "The album runs \(startYear)–\(endYear), past \(target). It goes where it starts unless you choose otherwise."))
            }
        }
        for (a, b) in YearFolders.overlaps(yearFolders) {
            out.append(.init(level: .warning, text: "Year folders “\(a.name)” and “\(b.name)” overlap."))
        }
        if let s = d.start {
            let near = index.albums(near: s).filter { !$0.hasSuffix(p.albumName) }
            if !near.isEmpty {
                let list = near.prefix(4).map { "“\(($0 as NSString).lastPathComponent)”" }.joined(separator: ", ")
                out.append(.init(level: .info, text: "Nearby albums: \(list). If it's the same event, you can put it inside."))
            }
        }
        if d.folderNameDisagrees, let y = d.folderYear {
            let named = d.folderMonth.map { String(format: "%04d-%02d", y, $0) } ?? String(y)
            out.append(.init(level: .warning, text: "The folder name says \(named), but the files' dates say otherwise. The files' dates are used."))
        }
        if !d.outliers.isEmpty {
            out.append(.init(level: .info, text: "\(Format.count(d.outliers.count, "file")) with dates far from the rest were ignored for the date range (camera clock not set?)."))
        }
        if d.undatedCount > 0 {
            out.append(.init(level: d.confidence == .low ? .warning : .info,
                             text: "\(Format.count(d.undatedCount, "photo or video", "photos or videos")) with no date of their own; only their modified date, which copying can reset."))
        }
        // Room on the drive for this album.
        let bytes = p.filesToCopy.reduce(Int64(0)) { $0 + $1.size }
        if let free = Volumes.freeBytes(at: libraryRoot) {
            let drive = Volumes.name(of: libraryRoot)
            if free < bytes + Volumes.spare {
                out.append(.init(level: .blocker, text: "Not enough space on \(drive): \(Format.bytes(bytes)) to copy, \(Format.bytes(free)) free. Free up space, or choose another library (another drive or folder).", action: .chooseLibrary))
            } else if let total = Volumes.totalBytes(at: libraryRoot), Double(free - bytes) < 0.05 * Double(total) {
                out.append(.init(level: .warning, text: "\(drive) will be nearly full after this copy (\(Format.bytes(free - bytes)) left). Consider starting a library on another drive.", action: .chooseLibrary))
            }
        }
        let elsewhere = p.alreadyInLibrary.filter { f in
            p.duplicates[f.relativePath]?.locations.allSatisfy { $0.library != libraryRoot.path } == true
        }
        if !elsewhere.isEmpty {
            let where_ = Set(elsewhere.compactMap { p.duplicates[$0.relativePath]?.locations.first?.libraryDisplay }).sorted().joined(separator: ", ")
            out.append(.init(level: .info, text: "\(Format.count(elsewhere.count, "file")) already in another library: \(where_)."))
        }
        let dupes = p.alreadyInLibrary.count
        if dupes > 0 {
            out.append(.init(level: .info, text: (dupes == 1 ? "1 file is" : "\(dupes) files are") + " already in the library" + (p.copyDuplicates ? "; copied again (your choice)." : " and will be skipped.")))
        }
        if !p.otherVersions.isEmpty {
            out.append(.init(level: .warning, text: "\(Format.count(p.otherVersions.count, "file")) with the same name as a library file but a different size (another version?). They will be copied."))
        }
        let others = p.scan.count(.other)
        if others > 0 && !p.copyOtherFiles {
            out.append(.init(level: .info, text: "\(Format.count(others, "other file")) (documents etc.) will be left out."))
        }
        if p.scan.keptLayoutBecauseOfClash {
            out.append(.init(level: .info, text: "Camera folders were kept, because removing them would give two files the same name."))
        }
        if p.filesToCopy.isEmpty && !p.scan.media.isEmpty {
            out.append(.init(level: .blocker, text: "Nothing to copy: every file is already in the library."))
        }
        return out.sorted { rank($0.level) < rank($1.level) }
    }

    private static func rank(_ l: Notice.Level) -> Int {
        switch l {
        case .blocker: 0
        case .warning: 1
        case .info: 2
        }
    }
}
