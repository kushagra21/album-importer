import AlbumCore
import AppKit
import SwiftUI

/// Developer aid: draws the app's screens into PNG files without needing Screen Recording
/// permission, for checking layouts. Driven by environment variables, off by default:
///
///   ALBUM_IMPORTER_SNAPSHOT=<out dir>   turn it on; the app quits when done
///   ALBUM_IMPORTER_ADD=<folder>[:<folder>…]
///   ALBUM_IMPORTER_EVENT=<name>          event name for the first folder, after the first snapshot
///   ALBUM_IMPORTER_COPY=1                then copy the first folder (with unlock permission)
@MainActor
enum Snapshot {
    static let isActive = ProcessInfo.processInfo.environment["ALBUM_IMPORTER_SNAPSHOT"] != nil

    static func runIfRequested(_ model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        guard let outPath = env["ALBUM_IMPORTER_SNAPSHOT"] else { return }
        let out = URL(fileURLWithPath: outPath)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let folders = (env["ALBUM_IMPORTER_ADD"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        Task {
            await model.refreshLibrary()
            await waitWhile { model.isIndexing }
            render(model, to: out.appendingPathComponent("0-empty.png"))
            renderView(LibraryStatus().padding(10).environment(model), size: CGSize(width: 270, height: 150),
                       to: out.appendingPathComponent("0-library-status.png"))
            renderView(HealthPopover(health: model.health).environment(model), size: CGSize(width: 320, height: 260),
                       to: out.appendingPathComponent("0-library-health.png"))
            model.add(folders)
            await waitWhile { model.items.contains { if case .scanning = $0.state { true } else { false } } }
            for (i, item) in model.items.enumerated() {
                model.selection = item.id
                try? await Task.sleep(for: .milliseconds(300))
                render(model, to: out.appendingPathComponent("1-review-\(i)-\(Naming.slug(item.title)).png"))
            }
            if let first = model.items.first, let event = env["ALBUM_IMPORTER_EVENT"] {
                model.selection = first.id
                first.proposal?.eventName = event
                model.updateNotices(first)
                try? await Task.sleep(for: .milliseconds(300))
                render(model, to: out.appendingPathComponent("2-review-named.png"))
                renderView(ConfirmSheet(item: first).environment(model), size: CGSize(width: 520, height: 420),
                           to: out.appendingPathComponent("3-confirm.png"))
                if env["ALBUM_IMPORTER_COPY"] == "1" {
                    model.start(first, allowUnlock: true)
                    try? await Task.sleep(for: .milliseconds(150))
                    render(model, to: out.appendingPathComponent("4-running.png"))
                    await waitWhile { if case .running = first.state { true } else { false } }
                    try? await Task.sleep(for: .milliseconds(300))
                    render(model, to: out.appendingPathComponent("5-done.png"))
                }
            }
            renderView(YearFolderSetupView().environment(model), size: CGSize(width: 640, height: 860),
                       to: out.appendingPathComponent("7-year-folders.png"))
            renderView(SettingsView().environment(model), size: CGSize(width: 560, height: 520), to: out.appendingPathComponent("6-settings.png"))
            NSApp.terminate(nil)
        }
    }

    private static func waitWhile(_ condition: () -> Bool) async {
        var n = 0
        while condition(), n < 600 {
            try? await Task.sleep(for: .milliseconds(200))
            n += 1
        }
    }

    /// The detail panel of the selected folder (the split view and lists don't draw offscreen).
    private static func render(_ model: AppModel, to url: URL) {
        let view = Group {
            if let item = model.selected { ItemDetail(item: item) } else { DropZone(targeted: false) }
        }
        renderView(view.environment(model), size: CGSize(width: 860, height: 980), to: url)
    }

    static func renderView<V: View>(_ view: V, size: CGSize, to url: URL) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
