import AlbumCore
import SwiftUI

/// Progress of a running copy.
struct RunView: View {
    @Environment(AppModel.self) private var model
    let item: ImportItem
    @State private var cancelRequested = false

    private let phases: [ImportJob.Phase] = [.planning, .dryRun, .unlocking, .pilot, .copying, .verifying, .locking, .records]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Copying \(item.proposal?.albumName ?? item.title)").font(.title2.weight(.semibold))
            Text(model.libraryName + "/" + (item.proposal?.albumRelativePath ?? "")).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(phases, id: \.self) { ph in
                    HStack(spacing: 8) {
                        phaseIcon(ph).frame(width: 18)
                        Text(ph.rawValue).foregroundStyle(state(ph) == .upcoming ? .secondary : .primary)
                    }
                }
            }

            if let p = item.progress, p.bytesTotal > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(p.bytesDone), total: Double(p.bytesTotal))
                    HStack {
                        Text("\(Format.bytes(p.bytesDone)) of \(Format.bytes(p.bytesTotal))")
                        Spacer()
                        if p.bytesPerSecond > 0 {
                            let left = Double(p.bytesTotal - p.bytesDone) / p.bytesPerSecond
                            Text("\(Format.bytes(Int64(p.bytesPerSecond)))/s · about \(Format.duration(left)) left")
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if !p.currentFile.isEmpty { Text(p.currentFile).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
            }
            Spacer()
            HStack {
                Text("Keep the drive connected. The Mac won't sleep while this runs.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(cancelRequested ? "Stopping after this file…" : "Cancel") {
                    cancelRequested = true
                    item.job?.cancel()
                }
                .disabled(cancelRequested)
            }
        }
        .padding(24)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private enum PhaseState { case done, current, upcoming }

    private func state(_ ph: ImportJob.Phase) -> PhaseState {
        guard let cur = item.phase, let ci = phases.firstIndex(of: cur), let pi = phases.firstIndex(of: ph) else { return .upcoming }
        return pi < ci ? .done : pi == ci ? .current : .upcoming
    }

    @ViewBuilder private func phaseIcon(_ ph: ImportJob.Phase) -> some View {
        switch state(ph) {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .current: ProgressView().controlSize(.small)
        case .upcoming: Image(systemName: "circle").foregroundStyle(.tertiary)
        }
    }
}

/// The outcome of a copy, with the same report that went into the history file.
struct DoneView: View {
    @Environment(AppModel.self) private var model
    let item: ImportItem
    let result: ImportJob.Result

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 36)).foregroundStyle(result.succeeded ? .green : .orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(.title2.weight(.semibold))
                    Text("\(Format.count(result.copied, "file")) · \(Format.bytes(result.bytes)) · \(Format.duration(result.seconds)) · run folder \(result.runFolder.lastPathComponent)").foregroundStyle(.secondary)
                }
            }
            if !result.failures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.failures.prefix(10), id: \.self) { Label($0, systemImage: "xmark.circle").foregroundStyle(.red) }
                }
            }
            Group {
                let report = Text(markdown(result.report.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                if Snapshot.isActive { report } else { ScrollView { report } }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                if FileManager.default.fileExists(atPath: result.albumPath) {
                    Button("Show Album in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.albumPath)]) }
                }
                Button("Open Run Folder") { NSWorkspace.shared.open(result.runFolder) }
                Spacer()
                Button("Remove from List") { model.remove(item) }
            }
        }
        .padding(24)
        .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }

    private var headline: String {
        if result.succeeded { return "Copied and verified" }
        if result.cancelled { return "Cancelled" }
        return result.copied == 0 ? "Nothing was copied" : "Stopped with a problem"
    }

    private func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
