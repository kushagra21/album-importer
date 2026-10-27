import AlbumCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.items) { item in
                    SidebarRow(item: item).tag(item.id)
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.folder]) }
                            Button("Remove from List") { model.remove(item) }.disabled(item.isBusy)
                        }
                }
            }
            .overlay {
                if model.items.isEmpty {
                    Text("Drop folders here").foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) { LibraryStatus().padding(10) }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .toolbar {
                ToolbarItem {
                    Button { addFolders(model) } label: { Label("Add Folders", systemImage: "plus") }
                        .help("Add photo folders (⌘O)")
                }
            }
        } detail: {
            Group {
                if let item = model.selected {
                    ItemDetail(item: item).id(item.id)
                } else {
                    DropZone(targeted: dropTargeted)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .task { await model.refreshLibrary() }
        .sheet(isPresented: $model.showYearSetup) { YearFolderSetupView() }
    }
}

struct SidebarRow: View {
    let item: ImportItem

    var body: some View {
        HStack(spacing: 8) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .scanning, .running: ProgressView().controlSize(.small)
        case .review:
            if item.notices.contains(where: { $0.level == .blocker }) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "folder.fill").foregroundStyle(.blue)
            }
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .finished(let r):
            Image(systemName: r.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.succeeded ? .green : .orange)
        }
    }

    private var subtitle: String {
        switch item.state {
        case .scanning(let s): s
        case .review: item.proposal?.albumName ?? ""
        case .failed: "Couldn't be added"
        case .running: item.phase?.rawValue ?? "Copying"
        case .finished(let r): r.succeeded ? "Copied \(Format.count(r.copied, "file"))" : "Stopped — see details"
        }
    }
}

struct LibraryStatus: View {
    @Environment(AppModel.self) private var model
    @State private var showingHealth = false

    var body: some View {
        let health = model.health
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The drive icon shows whether the library is ready; click it for details.
                Button { showingHealth.toggle() } label: {
                    Image(systemName: icon(health.level))
                        .foregroundStyle(color(health.level))
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help(([health.summary] + health.problems.map(\.text)).joined(separator: "\n"))
                .popover(isPresented: $showingHealth, arrowEdge: .top) { HealthPopover(health: health) }

                Menu {
                    Section("Current library") {
                        Button { } label: { Label(LibraryIndex.displayName(of: model.settings.libraryRoot), systemImage: "checkmark") }
                            .disabled(true)
                    }
                    if !model.settings.otherLibraries.isEmpty {
                        Section("Switch to") {
                            ForEach(model.settings.otherLibraries, id: \.self) { path in
                                Button {
                                    model.switchLibrary(to: path)
                                } label: {
                                    let connected = FileManager.default.fileExists(atPath: path)
                                    Text(LibraryIndex.displayName(of: path) + (connected ? "" : " (not connected)"))
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Choose Another Drive or Folder…") { model.chooseLibrary() }
                    Button("Set Up Year Folders…") { model.showYearSetup = true }
                        .disabled(!model.libraryAvailable && !model.libraryParentExists)
                } label: {
                    HStack(spacing: 3) {
                        Text(LibraryIndex.displayName(of: model.settings.libraryRoot))
                            .font(.caption.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(model.isCopying)
                .help("Where albums are stored. Click to switch to another library or drive.")
            }

            Text(details(health)).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            if health.level == .warning || health.level == .unavailable {
                Button(health.level == .unavailable ? "Check Again" : "Show Problems") {
                    if health.level == .unavailable { Task { await model.checkLibrary() } } else { showingHealth = true }
                }
                .controlSize(.small)
            }
            if health.level == .unavailable, let t = model.lastChecked {
                Text("Last checked \(t.formatted(date: .omitted, time: .standard))").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func details(_ h: AppModel.LibraryHealth) -> String {
        guard model.libraryAvailable else { return h.summary }
        var parts: [String] = []
        if let free = model.freeBytes { parts.append("\(Format.bytes(free)) free") }
        parts.append(Format.count(model.yearFolders.count, "year folder"))
        var text = parts.joined(separator: " · ")
        if h.level != .ready { text += "\n" + h.summary }
        return text
    }

    private func icon(_ l: AppModel.LibraryHealth.Level) -> String {
        switch l {
        case .ready: "externaldrive.fill.badge.checkmark"
        case .busy: "externaldrive.fill.badge.timemachine"
        case .warning: "externaldrive.fill.badge.exclamationmark"
        case .unavailable: "externaldrive.badge.xmark"
        }
    }
}

func color(_ l: AppModel.LibraryHealth.Level) -> Color {
    switch l {
    case .ready: .green
    case .busy: .yellow
    case .warning: .orange
    case .unavailable: .red
    }
}

/// What's wrong with the library (if anything) and a button to fix each problem.
struct HealthPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let health: AppModel.LibraryHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(health.summary, systemImage: "circle.fill")
                .foregroundStyle(color(health.level))
                .font(.headline)
            Text(model.settings.libraryRoot).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            ForEach(health.problems) { p in
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.text).fixedSize(horizontal: false, vertical: true)
                    if let fix = p.fix {
                        Button(title(fix)) { run(fix) }.controlSize(.small)
                    }
                }
            }
            if health.problems.isEmpty && health.level == .ready {
                Text("The drive is connected, the year folders and records folder are there, and there's room to copy.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func title(_ f: AppModel.LibraryHealth.Fix) -> String {
        switch f {
        case .checkAgain: "Check Again"
        case .chooseLibrary: "Choose Another Drive or Folder…"
        case .setUpYearFolders: "Set Up Year Folders…"
        case .openSettings: "Open Settings…"
        }
    }

    private func run(_ f: AppModel.LibraryHealth.Fix) {
        dismiss()
        switch f {
        case .checkAgain: Task { await model.checkLibrary() }
        case .chooseLibrary: model.chooseLibrary()
        case .setUpYearFolders: model.showYearSetup = true
        case .openSettings: NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
}

struct DropZone: View {
    @Environment(AppModel.self) private var model
    let targeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack").font(.system(size: 54, weight: .light)).foregroundStyle(.secondary)
            Text("Drop photo folders here").font(.title2.weight(.semibold))
            Text("Each folder is checked first (dates, name, year folder, duplicates). Nothing is copied until you press Copy.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
            Button("Add Folders…") { addFolders(model) }.controlSize(.large)
            if model.libraryAvailable && model.yearFolders.isEmpty && !model.isIndexing {
                VStack(spacing: 6) {
                    Text("\(model.libraryName) has no year folders yet.").font(.callout.weight(.medium))
                    Text("Add your photo folders first. Set Up Year Folders then suggests ranges from their dates.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    Button("Set Up Year Folders…") { model.showYearSetup = true }
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(targeted ? Color.accentColor : Color.secondary.opacity(0.35))
                .padding(24)
        }
    }
}

struct ItemDetail: View {
    @Environment(AppModel.self) private var model
    let item: ImportItem

    var body: some View {
        switch item.state {
        case .scanning(let msg):
            VStack(spacing: 12) {
                ProgressView()
                Text(msg).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .review:
            ReviewView(item: item)
        case .failed(let msg):
            VStack(spacing: 12) {
                Image(systemName: "xmark.octagon").font(.system(size: 40)).foregroundStyle(.red)
                Text(item.title).font(.title3.weight(.semibold))
                Text(msg).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
                HStack {
                    Button("Try Again") { Task { await model.scan(item) } }
                    Button("Remove") { model.remove(item) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running:
            RunView(item: item)
        case .finished(let result):
            DoneView(item: item, result: result)
        }
    }
}
