import Foundation

/// What a file is, for counting and for deciding what gets copied.
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case photo, video, audio
    /// Notes that belong to a photo or video: Google Takeout `.json`, `.xmp`, DJI `.srt` subtitles.
    case sidecar
    /// Anything else (documents, apps, caches). Not copied unless the owner asks.
    case other
}

public enum MediaTypes {
    public static let photo: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "arw", "cr2", "cr3", "nef", "dng", "raf", "orf",
        "rw2", "gif", "webp", "tif", "tiff", "bmp",
    ]
    /// `.dat` only counts inside a Video CD's `MPEGAV` folder (see `kind(of:)`).
    public static let video: Set<String> = [
        "mp4", "mov", "m4v", "avi", "mts", "m2ts", "3gp", "3gpp", "mkv", "lrv", "insv", "wmv",
        "mpg", "mpeg", "vob",
    ]
    public static let audio: Set<String> = ["aac", "m4a", "mp3", "wav", "aiff", "amr", "opus"]
    public static let sidecar: Set<String> = ["json", "xmp", "srt", "thm", "aae"]

    /// macOS and Windows litter that is never listed, counted or copied.
    public static func isJunk(_ name: String) -> Bool {
        name.hasPrefix(".") || name == "Thumbs.db" || name == "desktop.ini" || name == "Icon\r"
    }

    public static func kind(of url: URL) -> MediaKind {
        let ext = url.pathExtension.lowercased()
        if photo.contains(ext) { return .photo }
        if video.contains(ext) { return .video }
        if ext == "dat", url.deletingLastPathComponent().lastPathComponent.uppercased() == "MPEGAV" {
            return .video
        }
        if audio.contains(ext) { return .audio }
        if sidecar.contains(ext) { return .sidecar }
        return .other
    }

    /// Camera and storage folders that are dissolved when an album is imported
    /// (`DCIM/100CANON`, `DJI/100MEDIA`, `PRIVATE/M4ROOT/CLIP`, …).
    public static func isWrapperFolder(_ name: String) -> Bool {
        let upper = name.uppercased()
        let fixed: Set<String> = [
            "DCIM", "DJI", "PRIVATE", "M4ROOT", "CLIP", "AVCHD", "BDMV", "STREAM", "MISC", "CAMERA",
            "MP_ROOT", "DCIM1", "100MEDIA", "MPEGAV",
        ]
        if fixed.contains(upper) { return true }
        // DCF folder names: three digits plus five letters/digits/underscores, e.g. 100CANON, 101MSDCF, 100_FUJI.
        return upper.range(of: #"^\d{3}[A-Z0-9_]{5}$"#, options: .regularExpression) != nil
    }

    /// Folder names that are a camera or device, not an event, so they make a poor album name.
    public static func looksLikeDeviceName(_ name: String) -> Bool {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        if isWrapperFolder(name) { return true }
        let words = [
            "eos", "canon", "nikon", "sony", "fuji", "fujifilm", "gopro", "dji", "osmo", "insta360",
            "iphone", "ipad", "pixel", "oneplus", "samsung", "redmi", "xiaomi", "camera", "dcim",
            "phone", "android", "mobile", "sd card", "card", "untitled folder", "new folder", "photos",
            "videos", "images", "media", "export", "import", "backup", "dump",
        ]
        if words.contains(lower) { return true }
        // "Canon EOS 90D", "Sony A7MIII", "iPhone 16 Pro": a brand followed by a model.
        let brands = ["canon", "nikon", "sony", "fuji", "gopro", "dji", "iphone", "ipad", "pixel", "oneplus", "samsung", "eos", "osmo"]
        return brands.contains { lower.hasPrefix($0 + " ") }
    }
}
