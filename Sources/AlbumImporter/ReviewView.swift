import AlbumCore
import SwiftUI

/// The dry-run screen for one folder: what's in it, where it will go and under what name, what is
/// already in the library, and anything that needs a decision. Nothing is written from here.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @Bindable var item: ImportItem
    @State private var confirming = false
    @State private var newYearName = ""
    @State private var showDuplicates = false

    var body: some View {
        if let p = item.proposal {
            VStack(spacing: 0) {
                let content = VStack(alignment: .leading, spacing: 20) {
                    header(p)
                    summary(p)
                    nameAndPlace(p)
                    duplicates(p)
                    if !item.notices.isEmpty { notices }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
                if Snapshot.isActive {
                    // Offscreen snapshots can't draw scroll views; lay the content out directly.
                    content.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView { content }
                }
                Divider()
                footer(p)
            }
            .sheet(isPresented: $confirming) {
                ConfirmSheet(item: item)
            }
            .onChange(of: item.proposal?.eventName) { model.updateNotices(item) }
            .onChange(of: item.proposal?.target) { model.updateNotices(item) }
            .onChange(of: item.proposal?.insideAlbum) { model.updateNotices(item) }
            .onChange(of: item.proposal?.copyDuplicates) { model.updateNotices(item) }
            .onChange(of: item.proposal?.copyOtherFiles) { model.updateNotices(item) }
            .onAppear {
                if case .newYearFolder(let n) = p.target { newYearName = n }
            }
        }
    }

    // MARK: Sections

    private func header(_ p: Proposal) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.title2.weight(.semibold))
                Text(p.scan.folder.path).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([p.scan.folder]) }
            Button("Scan Again") { Task { await model.scan(item) } }
        }
    }

    private func summary(_ p: Proposal) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                label("Files")
                Text(fileCounts(p))
            }
            GridRow {
                label("Dates")
                HStack(spacing: 8) {
                    Text(dateRange(p.dates))
                    ConfidenceBadge(confidence: p.dates.confidence)
                    if let s = p.dates.mainSource { Text("from \(ImportJob.sourceName(s))").foregroundStyle(.secondary) }
                }
            }
            if !p.scan.cameras.isEmpty {
                GridRow {
                    label("Camera")
                    Text(p.scan.cameras.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key) (\($0.value))" }.joined(separator: ", "))
                }
            }
            if !p.scan.dissolvedFolders.isEmpty {
                GridRow {
                    label("Camera folders")
                    Text(p.scan.dissolvedFolders.joined(separator: ", ") + " — dropped; files go straight into the album")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func nameAndPlace(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Name and place").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    label("Event")
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("e.g. Beach Trip", text: binding(\.eventName))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 380)
                        Text(p.eventNameOrigin).font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    label("Year folder")
                    HStack {
                        Picker("", selection: yearSelection) {
                            ForEach(model.yearFolders) { f in Text(f.name).tag(f.name) }
                            Divider()
                            Text("New year folder…").tag(Self.newTag)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 260)
                        if case .newYearFolder = p.target {
                            TextField("YYYY - YYYY", text: $newYearName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                                .onChange(of: newYearName) { item.proposal?.target = .newYearFolder(newYearName.trimmingCharacters(in: .whitespaces)) }
                        }
                    }
                }
                GridRow {
                    label("Inside album")
                    HStack {
                        Toggle("Put it inside an existing album", isOn: insideToggle)
                        if p.insideAlbum != nil, let year = p.yearFolderName {
                            Picker("", selection: binding(\.insideAlbum)) {
                                ForEach(model.index?.albums(in: year) ?? [], id: \.self) { Text($0).tag(Optional($0)) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 320)
                        }
                    }
                    .disabled({ if case .yearFolder = p.target { false } else { true } }())
                }
                GridRow {
                    label("New album")
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus").foregroundStyle(.blue)
                        Text(model.libraryName + "/" + (p.albumRelativePath ?? "—"))
                            .fontWeight(.medium)
                            .textSelection(.enabled)
                        if let y = p.yearFolderName, Locks.isLocked(model.libraryRoot.appendingPathComponent(y)) {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary).help("\(y) is Locked; you'll be asked before it's unlocked.")
                        }
                    }
                }
            }
        }
    }

    private func duplicates(_ p: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Already in the library?").font(.headline)
                Spacer()
                if let c = item.checkingContents {
                    ProgressView(value: Double(c.done), total: Double(max(c.total, 1))).frame(width: 140)
                    Text("Checking contents…").font(.caption).foregroundStyle(.secondary)
                } else if !p.contentsChecked {
                    Button("Check Contents Too") { Task { await model.checkContents(item) } }
                        .help("Reads the files to confirm matches and to find copies saved under another name.")
                } else {
                    Label("Contents checked", systemImage: "checkmark.seal").foregroundStyle(.green).font(.callout)
                }
            }
            let dupes = p.alreadyInLibrary
            if dupes.isEmpty {
                Label("None of these files are in \(model.libraryName) yet" + (p.contentsChecked ? "." : " (matched by name and size)."),
                      systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Text("\(dupes.count) of \(Format.count(p.scan.media.count, "file")) are already in the library.")
                Toggle("Copy them anyway", isOn: binding(\.copyDuplicates))
                DisclosureGroup("Show where", isExpanded: $showDuplicates) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(dupes.prefix(200)) { f in
                            HStack(alignment: .firstTextBaseline) {
                                Text(f.name).frame(width: 180, alignment: .leading)
                                Text(locationText(p.duplicates[f.relativePath]?.locations.first))
                                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .font(.callout)
                        }
                        if dupes.count > 200 { Text("…and \(dupes.count - 200) more").foregroundStyle(.secondary) }
                    }
                    .padding(.top, 4)
                }
            }
            if p.scan.count(.other) > 0 {
                Toggle("Also copy \(Format.count(p.scan.count(.other), "other file")) (documents etc.)", isOn: binding(\.copyOtherFiles))
            }
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check before copying").font(.headline)
            ForEach(item.notices) { n in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    switch n.level {
                    case .blocker: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    case .info: Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(n.text).fixedSize(horizontal: false, vertical: true)
                        switch n.action {
                        case .chooseLibrary: Button("Choose Another Library…") { model.chooseLibrary() }.controlSize(.small)
                        case .setUpYearFolders: Button("Set Up Year Folders…") { model.showYearSetup = true }.controlSize(.small)
                        case nil: EmptyView()
                        }
                    }
                }
            }
        }
    }

    private func footer(_ p: Proposal) -> some View {
        let files = p.filesToCopy
        let bytes = files.reduce(Int64(0)) { $0 + $1.size }
        let blocked = item.notices.contains { $0.level == .blocker } || item.checkingContents != nil || !model.recordsAvailable
        return HStack {
            if !model.recordsAvailable {
                Label("Records folder not found — set it in Settings", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Text("Copies are checked byte for byte. Nothing is moved, overwritten or deleted.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove") { model.remove(item) }
            Button("Copy \(files.count == 1 ? "1 File" : "\(files.count) Files") (\(Format.bytes(bytes)))…") { confirming = true }
                .keyboardShortcut(.defaultAction)
                .disabled(blocked || files.isEmpty || model.isCopying)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: Helpers

    private static let newTag = "\u{0}new"

    private var yearSelection: Binding<String> {
        Binding {
            switch item.proposal?.target {
            case .yearFolder(let n): n
            case .newYearFolder: Self.newTag
            case nil: ""
            }
        } set: { v in
            if v == Self.newTag {
                let year = item.proposal?.startYear ?? Calendar.current.component(.year, from: Date())
                if newYearName.isEmpty { newYearName = YearFolders.suggestedNewFolder(for: year, existing: model.yearFolders) }
                item.proposal?.target = .newYearFolder(newYearName)
                item.proposal?.insideAlbum = nil
            } else {
                item.proposal?.target = .yearFolder(v)
                item.proposal?.insideAlbum = nil
            }
        }
    }

    private var insideToggle: Binding<Bool> {
        Binding {
            item.proposal?.insideAlbum != nil
        } set: { on in
            if on, let year = item.proposal?.yearFolderName {
                let albums = model.index?.albums(in: year) ?? []
                // Start with the nearest album by date, if there is one.
                let near = item.proposal?.dates.start.flatMap { model.index?.albums(near: $0).first { $0.hasPrefix(year + "/") } }
                item.proposal?.insideAlbum = near.map { ($0 as NSString).lastPathComponent } ?? albums.first
            } else {
                item.proposal?.insideAlbum = nil
            }
        }
    }

    private func binding<T>(_ kp: WritableKeyPath<Proposal, T>) -> Binding<T> {
        Binding { item.proposal![keyPath: kp] } set: { item.proposal?[keyPath: kp] = $0 }
    }

    /// Where a match is; the drive is named when it's in another library.
    private func locationText(_ loc: LibraryIndex.Location?) -> String {
        guard let loc else { return "" }
        return loc.library == model.settings.libraryRoot ? loc.display : "\(loc.libraryDisplay) ▸ \(loc.display)"
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    private func fileCounts(_ p: Proposal) -> String {
        var parts: [String] = []
        for (k, one, many) in [(MediaKind.photo, "photo", "photos"), (.video, "video", "videos"), (.audio, "audio file", "audio files"),
                               (.sidecar, "note", "notes"), (.other, "other file", "other files")] {
            let c = p.scan.count(k)
            if c > 0 { parts.append(Format.count(c, one, many)) }
        }
        return parts.joined(separator: " · ") + " — " + Format.bytes(p.scan.size(of: Set(MediaKind.allCases)))
    }

    private func dateRange(_ d: DateSummary) -> String {
        guard let s = d.start, let e = d.end else { return "No dates found" }
        let a = Floating.format(s, "d MMM yyyy"), b = Floating.format(e, "d MMM yyyy")
        return a == b ? a : "\(a) – \(b)"
    }

}

struct ConfidenceBadge: View {
    let confidence: DateSummary.Confidence

    var body: some View {
        let color: Color = switch confidence {
        case .high: .green
        case .medium: .orange
        case .low: .red
        }
        Text(confidence.rawValue.capitalized + " confidence")
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// The last check before copying: the dry run's result and, if needed, permission to unlock.
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: ImportItem
    @State private var allowUnlock = false

    var body: some View {
        let check = model.preflight(item)
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy to \(model.libraryName)?").font(.title3.weight(.semibold))
            if let plan = check.plan, let dry = check.dry {
                Text(model.libraryName + "/" + (item.proposal?.albumRelativePath ?? "")).fontWeight(.medium)
                Text("\(Format.count(plan.copies.count, "file")), \(Format.bytes(plan.totalBytes))" + (dry.freeBytes.map { " · \(Format.bytes($0)) free on the drive" } ?? ""))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("What happens").font(.headline)
                    Text("1. One file is copied first and checked (the pilot).")
                    Text("2. The rest are copied; each copy is compared with its original (SHA-256).")
                    Text("3. The timeline sheet and today's history file are updated, and everything is logged in a new run folder.")
                }
                .font(.callout)
                if !dry.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The dry run found problems").font(.headline).foregroundStyle(.red)
                        ForEach(dry.problems.prefix(8), id: \.self) { Text("• " + $0).font(.callout) }
                    }
                }
                if !dry.lockedFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Locked", systemImage: "lock.fill").font(.headline)
                        ForEach(dry.lockedFolders, id: \.self) { Text(($0 as NSString).lastPathComponent).fontWeight(.medium) }
                        Toggle("Unlock \(dry.lockedFolders.count == 1 ? "this folder" : "these folders") for the copy and lock again afterwards (logged)", isOn: $allowUnlock)
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Start Copy") {
                        model.start(item, allowUnlock: allowUnlock)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!dry.problems.isEmpty || (!dry.lockedFolders.isEmpty && !allowUnlock))
                }
            } else {
                Text(check.error ?? "Can't make a plan.").foregroundStyle(.red)
                HStack { Spacer(); Button("Close") { dismiss() } }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
