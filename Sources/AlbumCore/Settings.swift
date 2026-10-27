import CryptoKit
import Foundation

/// The app's settings, shared with `albumctl` (both read the app's defaults domain).
public struct Settings: Codable, Sendable, Equatable {
    public static let domain = "app.albumimporter.AlbumImporter"

    /// The library root: the folder that holds the year folders. Chosen in Settings; this is only a
    /// starting point (the app offers to create it, or to choose another folder or drive).
    public var libraryRoot = NSHomeDirectory() + "/Pictures/Albums"
    /// Where run folders, the timeline sheet and the history files live.
    public var recordsFolder = NSHomeDirectory() + "/Documents/Album Importer"
    /// The timeline workbook, relative to the records folder.
    public var timelineSheet = RecordsFolder.defaultTimelineSheet
    /// Dates that name an album on their own (birthdays, anniversaries). Personal, so they're kept
    /// only in the settings on this Mac; the app starts with New Year's Eve only.
    public var specialDates = Naming.defaultSpecialDates
    /// Libraries used before, newest first (not including the current one). Their cached indexes are
    /// also checked for duplicates, so a full drive that's been set aside is still taken into account.
    public var otherLibraries: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case libraryRoot, recordsFolder, timelineSheet, specialDates, otherLibraries }

    /// The records folder, with this library's timeline sheet.
    public var records: RecordsFolder { RecordsFolder(root: URL(fileURLWithPath: recordsFolder), timelineSheet: timelineSheet) }

    /// Missing keys keep their defaults, so settings saved by an older version still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        libraryRoot = try c.decodeIfPresent(String.self, forKey: .libraryRoot) ?? d.libraryRoot
        recordsFolder = try c.decodeIfPresent(String.self, forKey: .recordsFolder) ?? d.recordsFolder
        timelineSheet = try c.decodeIfPresent(String.self, forKey: .timelineSheet) ?? d.timelineSheet
        specialDates = try c.decodeIfPresent([Naming.SpecialDate].self, forKey: .specialDates) ?? d.specialDates
        otherLibraries = try c.decodeIfPresent([String].self, forKey: .otherLibraries) ?? []
    }

    /// Makes `path` the current library, remembering the previous one.
    public mutating func switchLibrary(to path: String) {
        guard path != libraryRoot else { return }
        otherLibraries.removeAll { $0 == path || $0 == libraryRoot }
        otherLibraries.insert(libraryRoot, at: 0)
        otherLibraries = Array(otherLibraries.prefix(8))
        libraryRoot = path
    }

    /// The app's own defaults. Inside the app bundle (the app, or `albumctl` in Contents/MacOS) that's
    /// `.standard`, since macOS refuses a suite named after the running bundle; elsewhere it's the suite.
    static var store: UserDefaults? {
        Bundle.main.bundleIdentifier == domain ? .standard : UserDefaults(suiteName: domain)
    }

    public static func load() -> Settings {
        guard let d = store?.data(forKey: "settings"),
              let s = try? JSONDecoder().decode(Settings.self, from: d) else { return Settings() }
        return s
    }

    public func save() {
        if let d = try? JSONEncoder().encode(self) { Self.store?.set(d, forKey: "settings") }
    }

    /// The duplicate index is a cache, so it lives in Application Support, not in the records folder.
    /// One file per library, so trying the demo library doesn't throw away the real library's index.
    public static func indexFile(for libraryRoot: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let digest = SHA256.hash(data: Data(libraryRoot.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("Album Importer/library_index-\(digest).json")
    }
}
