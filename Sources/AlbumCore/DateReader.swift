import Foundation
import ImageIO

/// Where a file's date came from, best first.
public enum DateSource: String, Codable, Sendable, Comparable {
    /// The camera's own date in the photo (EXIF DateTimeOriginal).
    case exif
    /// The creation time stored inside an MP4/MOV (`mvhd`).
    case video
    /// Google Takeout's `.json` note (`photoTakenTime`).
    case takeout
    /// A date in the file name, e.g. `IMG_20190512_…`, `WhatsApp Image 2021-03-04 …`.
    case filename
    /// The file's modified date. Copying often resets it, so it is the least reliable.
    case modified

    var rank: Int {
        switch self {
        case .exif: 0
        case .video: 1
        case .takeout: 2
        case .filename: 3
        case .modified: 4
        }
    }

    public static func < (a: DateSource, b: DateSource) -> Bool { a.rank < b.rank }

    /// True for dates written by the camera or phone when the photo was taken.
    public var isReliable: Bool { self != .modified }
}

/// Dates are kept as *wall-clock* time ("floating"): 2 Aug 2020 19:42 means what the camera's clock
/// showed, whatever the time zone. They are stored as a `Date` read with a GMT calendar.
public enum Floating {
    public static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "GMT")!
        return c
    }()

    /// Turns a real moment (UTC) into the wall-clock time of this Mac's time zone.
    public static func fromInstant(_ d: Date, in tz: TimeZone = .current) -> Date {
        d.addingTimeInterval(TimeInterval(tz.secondsFromGMT(for: d)))
    }

    public static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, _ s: Int = 0) -> Date? {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))
    }

    public static func ym(_ d: Date) -> (year: Int, month: Int) {
        let c = calendar.dateComponents([.year, .month], from: d)
        return (c.year!, c.month!)
    }

    public static func format(_ d: Date, _ pattern: String = "yyyy-MM-dd HH:mm") -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f.string(from: d)
    }
}

public struct FileDate: Codable, Sendable, Hashable {
    public var date: Date
    public var source: DateSource
}

/// Extra facts read from a photo's metadata while looking for its date.
public struct PhotoFacts: Sendable {
    public var date: Date?
    public var camera: String?
    public var latitude: Double?
    public var longitude: Double?
    public var pixelWidth: Int?
}

public enum DateReader {
    /// Reads the best available date for one file. `modified` is used only when nothing else works.
    public static func read(_ url: URL, kind: MediaKind, modified: Date) -> (FileDate, PhotoFacts?) {
        var facts: PhotoFacts?
        if kind == .photo {
            facts = photoFacts(url)
            if let d = facts?.date, plausible(d) { return (FileDate(date: d, source: .exif), facts) }
        }
        if kind == .video, let d = videoCreationDate(url), plausible(d) {
            return (FileDate(date: d, source: .video), nil)
        }
        if let d = takeoutDate(for: url), plausible(d) { return (FileDate(date: d, source: .takeout), facts) }
        if let d = dateInName(url.deletingPathExtension().lastPathComponent), plausible(d) {
            return (FileDate(date: d, source: .filename), facts)
        }
        return (FileDate(date: Floating.fromInstant(modified), source: .modified), facts)
    }

    /// Rejects camera-clock defaults (1970, 1 Jan 2000 and similar) and dates in the future.
    public static func plausible(_ d: Date, now: Date = Date()) -> Bool {
        let c = Floating.calendar.dateComponents([.year, .month, .day], from: d)
        guard let y = c.year, y >= 1990 else { return false }
        if d > Floating.fromInstant(now).addingTimeInterval(86_400) { return false }
        if c.month == 1, c.day == 1, [2000, 2001, 2010, 2015].contains(y) { return false }
        return true
    }

    // MARK: Photos

    public static func photoFacts(_ url: URL) -> PhotoFacts? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, opts) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        var facts = PhotoFacts()
        let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        if let raw { facts.date = parseExifDate(raw) }
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        if let model {
            // "Canon" + "Canon EOS 90D" → "Canon EOS 90D"; "Apple" + "iPhone 16" → "iPhone 16".
            facts.camera = model
            if let make, !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? ""),
               !["apple", "google", "oneplus"].contains(make.lowercased()) {
                facts.camera = "\(make) \(model)"
            }
        }
        if let gps, let lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            facts.latitude = (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" ? -lat : lat
            facts.longitude = (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" ? -lon : lon
        }
        facts.pixelWidth = props[kCGImagePropertyPixelWidth] as? Int
        return facts
    }

    /// "2020:08:02 19:42:19" → wall-clock date.
    public static func parseExifDate(_ s: String) -> Date? {
        let parts = s.split(whereSeparator: { ": -T".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        return Floating.date(parts[0], parts[1], parts[2],
                             parts.count > 3 ? parts[3] : 0, parts.count > 4 ? parts[4] : 0, parts.count > 5 ? parts[5] : 0)
    }

    // MARK: Videos

    /// The `mvhd` creation time of an MP4/MOV/M4V/3GP (seconds since 1904, UTC).
    public static func videoCreationDate(_ url: URL) -> Date? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        guard let moov = Atoms.find("moov", in: h, from: 0, to: size),
              let mvhd = Atoms.find("mvhd", in: h, from: moov.body, to: moov.end)
        else { return nil }
        try? h.seek(toOffset: mvhd.body)
        guard let head = try? h.read(upToCount: 12), head.count == 12 else { return nil }
        let version = head[0]
        let seconds: UInt64
        if version == 1 {
            seconds = head[4..<12].reduce(0) { $0 << 8 | UInt64($1) }
        } else {
            seconds = head[4..<8].reduce(0) { $0 << 8 | UInt64($1) }
        }
        guard seconds > 0 else { return nil }
        let instant = Date(timeIntervalSince1970: TimeInterval(seconds) - 2_082_844_800)
        return Floating.fromInstant(instant)
    }

    // MARK: Google Takeout

    /// Takeout writes `IMG_1234.JPG.json` (older) or `IMG_1234.JPG.supplemental-metadata.json`.
    public static func takeoutDate(for url: URL) -> Date? {
        let dir = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        for candidate in ["\(name).json", "\(name).supplemental-metadata.json"] {
            let note = dir.appendingPathComponent(candidate)
            guard let data = try? Data(contentsOf: note),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let taken = obj["photoTakenTime"] as? [String: Any],
                  let ts = (taken["timestamp"] as? String).flatMap(Double.init) ?? (taken["timestamp"] as? Double)
            else { continue }
            return Floating.fromInstant(Date(timeIntervalSince1970: ts))
        }
        return nil
    }

    // MARK: File and folder names

    private static let nameDate = try! NSRegularExpression(
        pattern: #"(?<!\d)(19[9]\d|20[0-3]\d)[-_.]?(0[1-9]|1[0-2])[-_.]?(0[1-9]|[12]\d|3[01])(?:[-_ T.]?([01]\d|2[0-3])[-_.]?([0-5]\d)[-_.]?([0-5]\d))?(?!\d)"#)

    /// Finds a full date (year, month and day) in a file name.
    public static func dateInName(_ name: String) -> Date? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = nameDate.firstMatch(in: name, range: range) else { return nil }
        func g(_ i: Int) -> Int? {
            guard let r = Range(m.range(at: i), in: name) else { return nil }
            return Int(name[r])
        }
        guard let y = g(1), let mo = g(2), let d = g(3) else { return nil }
        return Floating.date(y, mo, d, g(4) ?? 12, g(5) ?? 0, g(6) ?? 0)
    }

    private static let folderYearMonth = try! NSRegularExpression(
        pattern: #"(?<!\d)(19[5-9]\d|20[0-3]\d)(?:\s*[-–_./ ]\s*(0?[1-9]|1[0-2]))?(?!\d)"#)

    /// The year (and month, when present) in a folder name such as `2022 - 07 - Beach Trip` or `Seaside 2022`.
    public static func yearMonthInFolderName(_ name: String) -> (year: Int, month: Int?)? {
        let range = NSRange(name.startIndex..., in: name)
        guard let m = folderYearMonth.firstMatch(in: name, range: range),
              let yr = Range(m.range(at: 1), in: name), let y = Int(name[yr])
        else { return nil }
        let mo = Range(m.range(at: 2), in: name).flatMap { Int(name[$0]) }
        return (y, mo)
    }
}

/// Minimal reader for the box ("atom") structure of MP4 and QuickTime files.
public enum Atoms {
    public struct Atom: Sendable {
        public var type: String
        public var start: UInt64
        public var body: UInt64
        public var end: UInt64
    }

    /// Lists the atoms between two offsets. Stops at the first malformed header.
    public static func list(in h: FileHandle, from: UInt64, to: UInt64) -> [Atom] {
        var out: [Atom] = []
        var off = from
        while off + 8 <= to {
            guard (try? h.seek(toOffset: off)) != nil, let head = try? h.read(upToCount: 16), head.count >= 8 else { break }
            var size = head[0..<4].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let type = String(decoding: head[4..<8], as: UTF8.self)
            var headerLength: UInt64 = 8
            if size == 1 {
                guard head.count == 16 else { break }
                size = head[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                headerLength = 16
            } else if size == 0 {
                size = to - off
            }
            guard size >= headerLength, off + size <= to else { break }
            out.append(Atom(type: type, start: off, body: off + headerLength, end: off + size))
            off += size
        }
        return out
    }

    public static func find(_ type: String, in h: FileHandle, from: UInt64, to: UInt64) -> Atom? {
        list(in: h, from: from, to: to).first { $0.type == type }
    }

    /// True when the top-level atoms run exactly to the end of the file and include `moov`:
    /// a cheap check that a copied video is complete and playable.
    public static func isComplete(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return false }
        let atoms = list(in: h, from: 0, to: size)
        return atoms.last?.end == size && atoms.contains { $0.type == "moov" }
    }
}
