import AlbumCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Locations") {
                PathRow(title: "Photo library", detail: "Where albums are stored: the folder that holds the year folders (e.g. Photo Library). Choose an empty folder to start a new library.", path: $model.settings.libraryRoot)
                PathRow(title: "Records folder", detail: "Run folders, the timeline sheet and history files.", path: $model.settings.recordsFolder)
                LabeledContent("Timeline sheet") {
                    TextField("sheets/timeline.xlsx", text: $model.settings.timelineSheet)
                        .textFieldStyle(.roundedBorder).frame(width: 260)
                }
                Text("Inside the records folder. Created with the first import if it isn't there.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Other libraries") {
                Text("Libraries used before. Their files are still checked for duplicates (from the saved index), even when the drive isn't connected.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.settings.otherLibraries.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                ForEach(model.settings.otherLibraries, id: \.self) { path in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(LibraryIndex.displayName(of: path))
                            Text(path).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Use") { model.switchLibrary(to: path) }.disabled(model.isCopying)
                        Button("Forget") { model.settings.otherLibraries.removeAll { $0 == path } }
                            .help("Removes it from this list only. Nothing on the drive is touched.")
                    }
                }
                Button("Choose Another Drive or Folder…") { model.chooseLibrary() }.disabled(model.isCopying)
            }
            Section("Year folders") {
                Text(model.yearFolders.isEmpty ? "None yet." : model.yearFolders.map(\.name).joined(separator: " · ")).font(.callout)
                Button("Set Up Year Folders…") { model.showYearSetup = true }
            }
            Section("Special dates") {
                Text("Used to name an album when its folder has no proper name and all its photos fall within 3 days of one of these dates.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach($model.settings.specialDates, id: \.self) { $sp in
                    HStack {
                        Stepper("Day \(sp.day)", value: $sp.day, in: 1...31).frame(width: 120)
                        Picker("", selection: $sp.month) {
                            ForEach(1...12, id: \.self) { Text(Calendar.current.monthSymbols[$0 - 1]).tag($0) }
                        }
                        .labelsHidden().frame(width: 120)
                        TextField("Name", text: $sp.name)
                        Button(role: .destructive) {
                            model.settings.specialDates.removeAll { $0 == sp }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Date") { model.settings.specialDates.append(.init(month: 1, day: 1, name: "")) }
            }
            Section("Duplicate index") {
                Text(model.indexStatus.isEmpty ? "Not built yet." : model.indexStatus).font(.callout)
                HStack {
                    Button("Refresh") { Task { await model.refreshLibrary() } }
                    Button("Rebuild From Scratch") { Task { await model.refreshLibrary(full: true) } }
                }
                .disabled(model.isIndexing)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }
}

private struct PathRow: View {
    let title: String
    let detail: String
    @Binding var path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.directoryURL = URL(fileURLWithPath: path)
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
            Text(path).font(.caption.monospaced()).foregroundStyle(FileManager.default.fileExists(atPath: path) ? Color.secondary : Color.red)
                .textSelection(.enabled)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}
