import AlbumCore
import AppKit
import SwiftUI

@main
struct AlbumImporterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Album Importer", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    delegate.model = model
                    Snapshot.runIfRequested(model)
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Folders…") { addFolders(model) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Button("Refresh Library Index") { Task { await model.refreshLibrary() } }
                    .keyboardShortcut("r")
                Button("Rebuild Library Index From Scratch") { Task { await model.refreshLibrary(full: true) } }
                Divider()
                Button("Choose Library…") { model.chooseLibrary() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.isCopying)
                Button("Set Up Year Folders…") { model.showYearSetup = true }
                    .keyboardShortcut("y", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
func addFolders(_ model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = true
    panel.prompt = "Add"
    panel.message = "Choose the photo folders to add to \(model.libraryName)."
    if panel.runModal() == .OK { model.add(panel.urls) }
}

/// Asks before quitting while a copy is running: quitting would stop it between files.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard MainActor.assumeIsolated({ model?.isCopying }) == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A copy is still running"
        alert.informativeText = "Quitting now stops it partway, and a locked year folder may stay unlocked. Wait for it to finish, or press Cancel in the window first."
        alert.addButton(withTitle: "Keep Copying")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
