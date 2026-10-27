import Foundation

/// A list of every file in the library (name and size), including the files inside zips, used to
/// find duplicates. Cached on disk; a refresh only re-lists folders whose modified date changed.
public struct LibraryIndex: Codable, Sendable {
    public struct Dir: Codable, Sendable {
        public var mtime: Double
        public var files: [FileEntry]
        public var subdirs: [String]
        /// Zip name → its contents, kept with the zip's size and date so a changed zip is re-read.
        public var zips: [String: ZipListing]
    }

    public struct FileEntry: Codable, Sendable, Hashable {
        public var name: String
        public var size: Int64
    }

    public struct ZipListing: Codable, Sendable {
        public var size: Int64
        public var mtime: Double
        public var entries: [ZipReader.Entry]
    }

    /// Where a matching file was found, relative to the library root.
    public struct Location: Codable, Sendable, Hashable {
        /// e.g. `2021 - 2022/2022-04 – Seaside/DJI_0221.JPG`.
        public var path: String
        /// For a file inside a zip: the zip's path; `path` is then the path inside the zip.
        public var zip: String?
        public var size: Int64
        public var crc32: UInt32?
        /// The library root this file is in (several libraries can be checked at once).
        public var library: String = ""

        public var display: String { zip.map { "\($0) ▸ \(path)" } ?? path }

        /// "Photos Drive ▸ Photo Library": the drive and folder of a library, for showing where a match is.
        public var libraryDisplay: String { LibraryIndex.displayName(of: library) }
    }

    /// "/Volumes/Photos Drive/Photo Library" → "Photos Drive ▸ Photo Library".
    public static func displayName(of root: String) -> String {
        let parts = root.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" {
            return parts.count == 2 ? parts[1] : "\(parts[1]) ▸ \(parts.last!)"
        }
        return parts.last ?? root
    }

    public static let version = 1
    public var formatVersion = LibraryIndex.version
    public var root: String
    public var builtAt: Date
    /// Directory path relative to the root ("" is the root itself).
    public var dirs: [String: Dir]

    // Lookup tables, rebuilt after loading.
    private var byNameSize: [String: [Location]] = [:]
    private var byName: [String: [Location]] = [:]
    private var bySize: [Int64: [Location]] = [:]

    enum CodingKeys: String, CodingKey { case formatVersion, root, builtAt, dirs }

    public init(root: String) {
        self.root = root
        self.builtAt = .distantPast
        self.dirs = [:]
    }

    public var fileCount: Int { dirs.values.reduce(0) { $0 + $1.files.count } }
    public var zipEntryCount: Int { dirs.values.reduce(0) { $0 + $1.zips.values.reduce(0) { $0 + $1.entries.count } } }

    // MARK: Building

    /// Brings the index up to date with the drive. Unchanged folders are not re-listed.
    public static func refresh(_ old: LibraryIndex?, root: URL, full: Bool = false,
                               progress: (@Sendable (String) -> Void)? = nil) -> LibraryIndex {
        var idx = LibraryIndex(root: root.path)
        let previous = (full || old?.root != root.path || old?.formatVersion != version) ? [:] : (old?.dirs ?? [:])
        var listed = 0, reused = 0
        var queue = [""]
        while let rel = queue.popLast() {
            let url = rel.isEmpty ? root : root.appendingPathComponent(rel)
            guard let mtime = modified(url) else { continue }
            if let cached = previous[rel], cached.mtime == mtime {
                idx.dirs[rel] = cached
                queue.append(contentsOf: cached.subdirs.map { rel.isEmpty ? $0 : rel + "/" + $0 })
                reused += 1
            } else {
                let dir = list(url, previous: previous[rel], mtime: mtime)
                idx.dirs[rel] = dir
                queue.append(contentsOf: dir.subdirs.map { rel.isEmpty ? $0 : rel + "/" + $0 })
                listed += 1
            }
            if (listed + reused) % 200 == 0 { progress?("Indexing the library… \(listed + reused) folders") }
        }
        idx.builtAt = Date()
        idx.rebuildLookups()
        return idx
    }

    private static func modified(_ url: URL) -> Double? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
    }

    private static func list(_ url: URL, previous: Dir?, mtime: Double) -> Dir {
        var dir = Dir(mtime: mtime, files: [], subdirs: [], zips: [:])
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        for name in names where !MediaTypes.isJunk(name) {
            let p = url.appendingPathComponent(name)
            var st = stat()
            guard lstat(p.path, &st) == 0 else { continue }
            if st.st_mode & S_IFMT == S_IFDIR {
                dir.subdirs.append(name)
            } else if st.st_mode & S_IFMT == S_IFREG {
                let size = Int64(st.st_size)
                dir.files.append(FileEntry(name: name, size: size))
                if name.lowercased().hasSuffix(".zip") {
                    let zmtime = Double(st.st_mtimespec.tv_sec)
                    if let old = previous?.zips[name], old.size == size, old.mtime == zmtime {
                        dir.zips[name] = old
                    } else if let entries = try? ZipReader.entries(of: p) {
                        dir.zips[name] = ZipListing(size: size, mtime: zmtime, entries: entries)
                    }
                }
            }
        }
        return dir
    }

    private mutating func rebuildLookups() {
        byNameSize = [:]; byName = [:]; bySize = [:]
        for (rel, dir) in dirs {
            for f in dir.files {
                let path = rel.isEmpty ? f.name : rel + "/" + f.name
                add(Location(path: path, zip: nil, size: f.size, crc32: nil, library: root), name: f.name)
            }
            for (zipName, z) in dir.zips {
                let zipPath = rel.isEmpty ? zipName : rel + "/" + zipName
                for e in z.entries {
                    let name = (e.path as NSString).lastPathComponent
                    add(Location(path: e.path, zip: zipPath, size: e.size, crc32: e.crc32, library: root), name: name)
                }
            }
        }
    }

    private mutating func add(_ loc: Location, name: String) {
        let key = name.lowercased()
        byNameSize["\(key)\u{0}\(loc.size)", default: []].append(loc)
        byName[key, default: []].append(loc)
        if loc.size >= 50_000 { bySize[loc.size, default: []].append(loc) }
    }

    // MARK: Lookups

    public func matches(name: String, size: Int64) -> [Location] { byNameSize["\(name.lowercased())\u{0}\(size)"] ?? [] }
    public func sameName(_ name: String) -> [Location] { byName[name.lowercased()] ?? [] }
    /// Files of exactly this size (50 KB or more), whatever their name: candidates for renamed copies.
    public func sameSize(_ size: Int64) -> [Location] { bySize[size] ?? [] }

    /// Album folders (second level) whose names start with a month within `months` of `date`, for
    /// "a nearby album might be the same event" hints. Returns paths like `2021 - 2022/2022-07 – Family Dinner`.
    public func albums(near date: Date, months: Int = 1) -> [String] {
        let (y, m) = Floating.ym(date)
        let target = y * 12 + m
        var out: [String] = []
        for yearFolder in dirs[""]?.subdirs ?? [] {
            for album in dirs[yearFolder]?.subdirs ?? [] {
                guard let ym = Self.albumStart(album) else { continue }
                if abs(ym - target) <= months { out.append(yearFolder + "/" + album) }
            }
            for file in dirs[yearFolder]?.files ?? [] where file.name.lowercased().hasSuffix(".zip") {
                guard let ym = Self.albumStart(file.name) else { continue }
                if abs(ym - target) <= months { out.append(yearFolder + "/" + file.name) }
            }
        }
        return out.sorted()
    }

    /// Album folders inside one year folder, for "put it inside an existing album".
    public func albums(in yearFolder: String) -> [String] {
        (dirs[yearFolder]?.subdirs ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func albumStart(_ name: String) -> Int? {
        guard name.count >= 7 else { return nil }
        let p = name.prefix(7)
        let parts = p.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), parts[0].count == 4, (1...12).contains(m) else { return nil }
        return y * 12 + m
    }

    // MARK: Saving

    public static func load(from url: URL) -> LibraryIndex? {
        guard let data = try? Data(contentsOf: url), var idx = try? JSONDecoder().decode(LibraryIndex.self, from: data) else { return nil }
        idx.rebuildLookups()
        return idx
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
