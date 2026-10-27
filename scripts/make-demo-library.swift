// Creates a throwaway demo library for trying Album Importer safely: a fake "Photo Library"
// with year folders (some Locked), a records folder with a timeline sheet, and source folders
// shaped like a camera card, a drone dump and a phone export.
//
// Usage: swift scripts/make-demo-library.swift <empty-folder>

import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 2 else { print("usage: swift scripts/make-demo-library.swift <empty-folder>"); exit(2) }
let root = URL(fileURLWithPath: args[1])
let fm = FileManager.default
if let existing = try? fm.contentsOfDirectory(atPath: root.path), !existing.isEmpty {
    print("\(root.path) isn't empty; choose a new folder."); exit(1)
}

func dir(_ p: String) -> URL {
    let u = root.appendingPathComponent(p)
    try! fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func photo(_ p: String, _ date: String, seed: Int, model: String = "Canon EOS 90D") {
    let url = root.appendingPathComponent(p)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let w = 640, h = 480
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let hue = CGFloat(seed % 12) / 12
    ctx.setFillColor(NSColor(hue: hue, saturation: 0.5, brightness: 0.9, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(NSColor(hue: (hue + 0.4).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.6, alpha: 1).cgColor)
    for i in 0..<12 { ctx.fillEllipse(in: CGRect(x: (seed * 37 + i * 53) % w, y: (seed * 19 + i * 41) % h, width: 60, height: 60)) }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: date],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: model.split(separator: " ").first.map(String.init) ?? "", kCGImagePropertyTIFFModel: model],
    ]
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

func video(_ p: String, utc: Date, payload: Int) {
    let url = root.appendingPathComponent(p)
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var d = Data()
    func be32(_ v: UInt32) { d.append(contentsOf: [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    be32(16); d.append(contentsOf: Array("ftypisom".utf8)); be32(0)
    be32(UInt32(8 + payload)); d.append(contentsOf: Array("mdat".utf8)); d.append(Data((0..<payload).map { UInt8($0 % 251) }))
    let secs = UInt32(utc.timeIntervalSince1970 + 2_082_844_800)
    be32(116); d.append(contentsOf: Array("moov".utf8))
    be32(108); d.append(contentsOf: Array("mvhd".utf8)); be32(0); be32(secs); be32(secs); be32(1000); be32(60_000)
    d.append(Data(repeating: 0, count: 80))
    try! d.write(to: url)
}

func lock(_ p: String) {
    let u = root.appendingPathComponent(p)
    var st = stat()
    lstat(u.path, &st)
    chflags(u.path, st.st_flags | UInt32(UF_IMMUTABLE))
}

// The library.
for y in ["1990 - Wedding", "2003 - 2011", "2012 - 2016", "2017 - 2020", "2021 - 2022", "2023 - 2026"] {
    _ = dir("Photo Library/\(y)")
}
_ = dir("Photo Library/Misc Selected")
photo("Photo Library/2021 - 2022/2022-07 – Family Dinner/IMG_0101.JPG", "2022:07:18 10:00:00", seed: 1)
photo("Photo Library/2021 - 2022/2022-07 – Family Dinner/IMG_0102.JPG", "2022:07:18 10:05:00", seed: 2)
photo("Photo Library/2017 - 2020/2020-08 to 2022-07 – Garden Party/IMG_3001.JPG", "2020:08:15 18:00:00", seed: 3)
photo("Photo Library/2023 - 2026/2025-08 – Picnic/IMG_7001.JPG", "2025:08:09 11:00:00", seed: 4, model: "iPhone 16 Pro")

// Sources.
for i in 0..<12 { photo("Sources/EOS/IMG_00\(46 + i).JPG", "2020:08:02 19:\(String(format: "%02d", 10 + i)):00", seed: 10 + i) }
photo("Sources/2022 - 07 - Beach Trip/DCIM/100MEDIA/IMG_0102.JPG", "2022:07:18 10:05:00", seed: 2)  // already in the library
for i in 0..<4 { video("Sources/2022 - 07 - Beach Trip/DCIM/100MEDIA/DJI_023\(i).MP4", utc: Date(timeIntervalSince1970: 1_658_040_000 + Double(i) * 600), payload: 3_000_000 + i * 100_000) }
for i in 0..<6 { photo("Sources/Picnic 2025/IMG_70\(String(format: "%02d", i + 1)).JPG", "2025:08:09 11:\(String(format: "%02d", i * 3)):00", seed: i == 0 ? 4 : 30 + i, model: "iPhone 16 Pro") }
try! Data("not a photo".utf8).write(to: dir("Sources/Picnic 2025").appendingPathComponent("notes.txt"))

// Records.
_ = dir("Records/runs")
_ = dir("Records/sheets")
print("""
Created the demo in \(root.path).
Copy a real timeline sheet into Records/sheets/timeline.xlsx if you want the timeline updated.
Lock the year folders in Finder (or run: chflags uchg "\(root.path)/Photo Library"/*) to try the unlock flow.
""")
lock("Photo Library/2017 - 2020")
lock("Photo Library/2021 - 2022")
lock("Photo Library")
