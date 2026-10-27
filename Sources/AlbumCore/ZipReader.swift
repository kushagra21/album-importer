import Foundation

/// Reads the list of files inside a zip (names, sizes, CRC32) from its central directory, without
/// extracting anything. Handles ZIP64, which Google Takeout's large zips use.
public enum ZipReader {
    public struct Entry: Codable, Sendable, Hashable {
        public var path: String
        public var size: Int64
        public var crc32: UInt32
    }

    public static func entries(of url: URL) throws -> [Entry] {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let fileSize = try h.seekToEnd()
        // The end-of-central-directory record is in the last 22 + 65535 bytes.
        let tailLength = min(fileSize, 22 + 65_535 + 20)
        try h.seek(toOffset: fileSize - tailLength)
        let tail = try h.read(upToCount: Int(tailLength)) ?? Data()
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: tail) else {
            throw AlbumError.invalid("Not a zip file: \(url.lastPathComponent)")
        }
        var count = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))
        // ZIP64: a locator just before the EOCD points at the ZIP64 EOCD record.
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocd >= 20,
           tail.u32(eocd - 20) == 0x0706_4B50 {
            let recordOffset = tail.u64(eocd - 20 + 8)
            try h.seek(toOffset: recordOffset)
            let rec = try h.read(upToCount: 56) ?? Data()
            guard rec.count == 56, rec.u32(0) == 0x0606_4B50 else { throw AlbumError.invalid("Bad ZIP64 record in \(url.lastPathComponent)") }
            count = rec.u64(32)
            cdSize = rec.u64(40)
            cdOffset = rec.u64(48)
        }
        guard cdOffset + cdSize <= fileSize, cdSize < 512 * 1024 * 1024 else {
            throw AlbumError.invalid("Bad central directory in \(url.lastPathComponent)")
        }
        try h.seek(toOffset: cdOffset)
        let cd = try h.read(upToCount: Int(cdSize)) ?? Data()
        var out: [Entry] = []
        out.reserveCapacity(Int(min(count, 1_000_000)))
        var p = 0
        while p + 46 <= cd.count, cd.u32(p) == 0x0201_4B50 {
            let crc = cd.u32(p + 16)
            var size = UInt64(cd.u32(p + 24))
            var compressed = UInt64(cd.u32(p + 20))
            let nameLength = Int(cd.u16(p + 28)), extraLength = Int(cd.u16(p + 30)), commentLength = Int(cd.u16(p + 32))
            let nameStart = p + 46
            guard nameStart + nameLength + extraLength <= cd.count else { break }
            let nameData = cd.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            // ZIP64 extra field (0x0001) holds the real sizes when they are 0xFFFFFFFF.
            if size == 0xFFFF_FFFF || compressed == 0xFFFF_FFFF {
                var x = nameStart + nameLength
                let xEnd = x + extraLength
                while x + 4 <= xEnd {
                    let id = cd.u16(x), len = Int(cd.u16(x + 2))
                    if id == 0x0001 {
                        var q = x + 4
                        if size == 0xFFFF_FFFF, q + 8 <= x + 4 + len { size = cd.u64(q); q += 8 }
                        if compressed == 0xFFFF_FFFF, q + 8 <= x + 4 + len { compressed = cd.u64(q); q += 8 }
                        break
                    }
                    x += 4 + len
                }
            }
            if !name.hasSuffix("/") {
                out.append(Entry(path: name, size: Int64(size), crc32: crc))
            }
            p = nameStart + nameLength + extraLength + commentLength
        }
        return out
    }

    private static func lastIndex(of sig: [UInt8], in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var i = data.count - 22
        while i >= 0 {
            if data[data.startIndex + i] == sig[0], data[data.startIndex + i + 1] == sig[1],
               data[data.startIndex + i + 2] == sig[2], data[data.startIndex + i + 3] == sig[3] { return i }
            i -= 1
        }
        return nil
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }

    func u32(_ i: Int) -> UInt32 {
        let b = startIndex + i
        return UInt32(self[b]) | UInt32(self[b + 1]) << 8 | UInt32(self[b + 2]) << 16 | UInt32(self[b + 3]) << 24
    }

    func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i + 4)) << 32 }
}

/// CRC-32 (the zip/PNG polynomial), used to compare a file with an entry inside a zip.
public struct CRC32: Sendable {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public private(set) var value: UInt32 = 0
    private var state: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update(_ data: Data) {
        var c = state
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            Self.table.withUnsafeBufferPointer { t in
                for byte in buf { c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
            }
        }
        state = c
        value = c ^ 0xFFFF_FFFF
    }

    public static func of(file url: URL) throws -> UInt32 {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var crc = CRC32()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { crc.update(chunk) }
        return crc.value
    }
}
