import Compression
import Foundation

/// Reads and writes the zip container of an .xlsx file. Only what the timeline update needs:
/// every entry is read into memory and written back in the same order.
public struct ZipArchive {
    public struct Entry {
        public var name: String
        public var data: Data
    }

    public var entries: [Entry]

    public subscript(name: String) -> Data? {
        get { entries.first { $0.name == name }?.data }
        set {
            if let i = entries.firstIndex(where: { $0.name == name }) {
                if let newValue { entries[i].data = newValue } else { entries.remove(at: i) }
            } else if let newValue {
                entries.append(Entry(name: name, data: newValue))
            }
        }
    }

    public static func read(_ url: URL) throws -> ZipArchive {
        let all = try Data(contentsOf: url)
        guard let eocd = all.lastRange(of: Data([0x50, 0x4B, 0x05, 0x06]))?.lowerBound else {
            throw AlbumError.invalid("\(url.lastPathComponent) is not a valid .xlsx (zip) file")
        }
        let e = eocd - all.startIndex
        let count = Int(all.u16(e + 10))
        var p = Int(all.u32(e + 16))
        var out: [Entry] = []
        for _ in 0..<count {
            guard all.u32(p) == 0x0201_4B50 else { throw AlbumError.invalid("Bad zip directory in \(url.lastPathComponent)") }
            let method = all.u16(p + 10)
            let compressed = Int(all.u32(p + 20)), size = Int(all.u32(p + 24))
            let nameLength = Int(all.u16(p + 28)), extra = Int(all.u16(p + 30)), comment = Int(all.u16(p + 32))
            let local = Int(all.u32(p + 42))
            let name = String(decoding: all.subdata(in: (all.startIndex + p + 46)..<(all.startIndex + p + 46 + nameLength)), as: UTF8.self)
            let lNameLength = Int(all.u16(local + 26)), lExtra = Int(all.u16(local + 28))
            let start = all.startIndex + local + 30 + lNameLength + lExtra
            let raw = all.subdata(in: start..<(start + compressed))
            let data: Data
            switch method {
            case 0: data = raw
            case 8: data = try inflate(raw, size: size)
            default: throw AlbumError.invalid("Unsupported compression in \(url.lastPathComponent)")
            }
            out.append(Entry(name: name, data: data))
            p += 46 + nameLength + extra + comment
        }
        return ZipArchive(entries: out)
    }

    public func write(to url: URL) throws {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = Self.dosNow()
        for e in entries {
            let deflated = try Self.deflate(e.data)
            let useDeflate = deflated.count < e.data.count
            let body = useDeflate ? deflated : e.data
            var crc = CRC32()
            crc.update(e.data)
            let name = Data(e.name.utf8)
            let offset = UInt32(out.count)
            var local = Data()
            local.le32(0x0403_4B50); local.le16(20); local.le16(0x0800); local.le16(useDeflate ? 8 : 0)
            local.le16(dosTime); local.le16(dosDate); local.le32(crc.value)
            local.le32(UInt32(body.count)); local.le32(UInt32(e.data.count)); local.le16(UInt16(name.count)); local.le16(0)
            out.append(local); out.append(name); out.append(body)
            var c = Data()
            c.le32(0x0201_4B50); c.le16(20); c.le16(20); c.le16(0x0800); c.le16(useDeflate ? 8 : 0)
            c.le16(dosTime); c.le16(dosDate); c.le32(crc.value)
            c.le32(UInt32(body.count)); c.le32(UInt32(e.data.count)); c.le16(UInt16(name.count))
            c.le16(0); c.le16(0); c.le16(0); c.le16(0); c.le32(0); c.le32(offset)
            central.append(c); central.append(name)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.le32(0x0605_4B50); end.le16(0); end.le16(0)
        end.le16(UInt16(entries.count)); end.le16(UInt16(entries.count))
        end.le32(UInt32(central.count)); end.le32(cdOffset); end.le16(0)
        out.append(end)
        try out.write(to: url, options: .atomic)
    }

    static func inflate(_ data: Data, size: Int) throws -> Data {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n == size else { throw AlbumError.invalid("Couldn't decompress part of the .xlsx file") }
        return out
    }

    static func deflate(_ data: Data) throws -> Data {
        if data.isEmpty { return Data() }
        let capacity = data.count + 1024
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { return data }
        return out.prefix(n)
    }

    static func dosNow() -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let time = UInt16(c.hour! << 11 | c.minute! << 5 | c.second! / 2)
        let date = UInt16((c.year! - 1980) << 9 | c.month! << 5 | c.day!)
        return (time, date)
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}
