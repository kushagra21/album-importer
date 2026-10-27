import AlbumCore
import SwiftUI

/// Lets the owner choose the year ranges for a library's year folders and creates them: for a new,
/// empty library, or to add ranges (e.g. 2027 - 2028) to an existing one.
struct YearFolderSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    struct Range: Identifiable, Equatable {
        let id = UUID()
        var start: Int
        var end: Int
        var closed: ClosedRange<Int> { min(start, end)...max(start, end) }
    }

    @State private var ranges: [Range] = []
    @State private var fillFrom = 2003
    @State private var fillTo = Calendar.current.component(.year, from: Date())
    @State private var fillSpan = 2
    @State private var lockNew = true
    @State private var allowUnlock = false
    @State private var working = false
    @State private var result: YearFolderSetup.Result?
    @State private var style = StyleChoice.perYear
    @State private var blockYears = 2
    @State private var balancedFolders = 3

    enum StyleChoice: String, CaseIterable, Identifiable {
        case perYear = "One per year"
        case blocks = "Blocks of years"
        case balanced = "Balanced by size"
        var id: String { rawValue }
    }


    var body: some View {
        let existing = model.libraryAvailable ? YearFolders.list(in: model.libraryRoot) : []
        let problems = YearFolders.problems(in: ranges.map(\.closed), existing: existing)
        let rootLocked = model.libraryAvailable && Locks.isLocked(model.libraryRoot)
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Year folders").font(.title3.weight(.semibold))
                Text(model.settings.libraryRoot).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if !model.libraryAvailable {
                    Label("This folder doesn't exist yet; it will be created.", systemImage: "folder.badge.plus").font(.callout)
                }
            }

            if let result {
                resultView(result)
            } else {
                if !existing.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Already there").font(.headline)
                        Text(existing.map(\.name).joined(separator: " · ")).foregroundStyle(.secondary)
                    }
                }

                let stats = model.yearStats
                if !stats.isEmpty {
                    suggestions(stats, existing: existing)
                } else if existing.isEmpty {
                    Label("Not sure which years you need? Add your photo folders first (drop them on the window), then open this again: it suggests ranges from their dates.",
                          systemImage: "lightbulb").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(stats.isEmpty ? "Quick fill" : "Or fill by hand").font(.headline)
                    HStack(spacing: 8) {
                        Text("From")
                        yearField($fillFrom)
                        Text("to")
                        yearField($fillTo)
                        Text("in blocks of")
                        Picker("", selection: $fillSpan) {
                            ForEach(1...10, id: \.self) { Text($0 == 1 ? "1 year" : "\($0) years").tag($0) }
                        }
                        .labelsHidden().frame(width: 100)
                        Button("Fill") {
                            ranges = YearFolders.evenRanges(from: fillFrom, to: fillTo, span: fillSpan)
                                .filter { r in !existing.contains { !$0.isNamedYear && $0.startYear <= r.upperBound && r.lowerBound <= $0.endYear } }
                                .map { Range(start: $0.lowerBound, end: $0.upperBound) }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("New year folders").font(.headline)
                        Spacer()
                        Button {
                            let lastEnd = (ranges.map(\.closed.upperBound) + existing.filter { !$0.isNamedYear }.map(\.endYear)).max()
                                ?? Calendar.current.component(.year, from: Date()) - 1
                            ranges.append(Range(start: lastEnd + 1, end: lastEnd + 2))
                        } label: { Label("Add Range", systemImage: "plus") }
                    }
                    if ranges.isEmpty {
                        Text("No new folders yet. Use Quick fill, or Add Range.").foregroundStyle(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach($ranges) { $r in
                                HStack(spacing: 8) {
                                    yearField($r.start)
                                    Text("to")
                                    yearField($r.end)
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Label(YearFolders.name(r.closed.lowerBound, r.closed.upperBound), systemImage: "folder")
                                        .frame(minWidth: 130, alignment: .leading)
                                    Spacer()
                                    Button { ranges.removeAll { $0.id == r.id } } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "xmark.circle.fill").foregroundStyle(.red) }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Lock the new year folders afterwards (recommended)", isOn: $lockNew)
                    if rootLocked {
                        Toggle("\(model.libraryName) is Locked: unlock it to add the folders, and lock it again afterwards (logged)", isOn: $allowUnlock)
                    }
                }

                HStack {
                    Text("Only creates folders. Nothing is renamed, moved or deleted.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(ranges.isEmpty ? "Create Folders" : ranges.count == 1 ? "Create 1 Folder" : "Create \(ranges.count) Folders") {
                        working = true
                        Task {
                            result = await model.createYearFolders(ranges.map(\.closed), allowUnlock: allowUnlock, lockNew: lockNew)
                            working = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ranges.isEmpty || !problems.isEmpty || (rootLocked && !allowUnlock) || working || !model.libraryParentExists)
                }
                if !model.libraryParentExists {
                    Label("The folder that should hold the library isn't there (is the drive connected?).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .onAppear {
            let stats = model.yearStats
            if !stats.isEmpty {
                balancedFolders = YearSuggest.defaultBalancedCount(stats)
                fillFrom = stats.first!.year
                fillTo = stats.last!.year
                if ranges.isEmpty { applySuggestion(stats, existing: existing) }
            }
            if stats.isEmpty, let lastEnd = existing.filter({ !$0.isNamedYear }).map(\.endYear).max() {
                fillFrom = lastEnd + 1
                fillTo = max(lastEnd + 2, fillTo)
            }
        }
    }

    // MARK: Suggestions from the added folders

    @ViewBuilder private func suggestions(_ stats: [YearSuggest.YearStat], existing: [YearFolder]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested from the added folders").font(.headline)
            let uncovered = stats.filter { s in !existing.contains { !$0.isNamedYear && $0.contains(s.year) } }
            Text(uncovered.isEmpty
                 ? "Every added folder already has a year folder."
                 : "\(Format.count(uncovered.reduce(0) { $0 + $1.albums }, "album")) need year folders, from \(String(uncovered.first!.year)) to \(String(uncovered.last!.year)):")
                .font(.callout).foregroundStyle(.secondary)
            // Years and what's in them, so the choice of ranges is informed.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(uncovered) { s in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(s.year)).font(.callout.weight(.semibold))
                        Text("\(Format.count(s.albums, "album")) · \(Format.bytes(s.bytes))").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if !uncovered.isEmpty {
                HStack(spacing: 8) {
                    Picker("", selection: $style) {
                        ForEach(StyleChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 340)
                    switch style {
                    case .perYear: EmptyView()
                    case .blocks:
                        Stepper("\(blockYears) years each", value: $blockYears, in: 2...10).fixedSize()
                    case .balanced:
                        Stepper(Format.count(balancedFolders, "folder"), value: $balancedFolders, in: 1...max(1, uncovered.count)).fixedSize()
                    }
                }
                .onChange(of: style) { applySuggestion(stats, existing: existing) }
                .onChange(of: blockYears) { applySuggestion(stats, existing: existing) }
                .onChange(of: balancedFolders) { applySuggestion(stats, existing: existing) }
                Text(styleHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var styleHelp: String {
        switch style {
        case .perYear: "A folder for each year that has albums. Years without photos get no folder."
        case .blocks: "Equal blocks of years from the earliest year, skipping blocks with no albums."
        case .balanced: "Neighbouring years grouped so each folder holds a similar amount: quiet years share a folder, busy years get their own."
        }
    }

    private func applySuggestion(_ stats: [YearSuggest.YearStat], existing: [YearFolder]) {
        let s: YearSuggest.Style = switch style {
        case .perYear: .perYear
        case .blocks: .blocks(blockYears)
        case .balanced: .balanced(balancedFolders)
        }
        ranges = YearSuggest.suggest(stats, style: s, existing: existing).map { Range(start: $0.lowerBound, end: $0.upperBound) }
    }

    private func yearField(_ value: Binding<Int>) -> some View {
        TextField("Year", value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 64)
    }

    @ViewBuilder private func resultView(_ r: YearFolderSetup.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(r.succeeded ? "Done" : "Finished with problems",
                  systemImage: r.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(r.succeeded ? .green : .orange)
            if !r.created.isEmpty { Text("Created: " + r.created.joined(separator: ", ")) }
            if !r.skipped.isEmpty { Text("Already there: " + r.skipped.joined(separator: ", ")).foregroundStyle(.secondary) }
            if !r.lockChanges.isEmpty { Text("Locks: " + r.lockChanges.joined(separator: "; ")).foregroundStyle(.secondary) }
            ForEach(r.failures, id: \.self) { Label($0, systemImage: "xmark.circle").foregroundStyle(.red) }
            HStack {
                if let folder = r.runFolder { Button("Open Run Folder") { NSWorkspace.shared.open(folder) } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
