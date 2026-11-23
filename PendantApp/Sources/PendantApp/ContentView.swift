import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var sync: SyncController
    @EnvironmentObject var player: Player
    @EnvironmentObject var transcription: TranscriptionQueue
    @State private var selection: String?
    @State private var pendingDelete: Recording?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.days) { day in
                    Section(day.id) {
                        ForEach(day.recordings) { rec in
                            HStack(spacing: 6) {
                                Text(rec.timeText)
                                if transcription.currentID == rec.id {
                                    ProgressView().controlSize(.mini)
                                } else if rec.transcript == nil {
                                    Image(systemName: "clock").foregroundStyle(.tertiary)
                                        .help("Waiting to be transcribed")
                                }
                                Spacer()
                                Text(rec.durationText).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .tag(rec.id)
                            .contextMenu {
                                Button("Delete…", role: .destructive) { pendingDelete = rec }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .onDeleteCommand {
                pendingDelete = library.recording(withID: selection)
            }
            .overlay {
                if library.days.isEmpty {
                    Text("No recordings yet.\nPress Sync to download from the pendant.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
        } detail: {
            if let rec = library.recording(withID: selection) {
                RecordingDetail(recording: rec, onDelete: { pendingDelete = rec })
            } else {
                Text("Select a recording").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { !transcription.paused }, set: { transcription.paused = !$0 })) {
                    Label("Transcribe", systemImage: "text.bubble")
                }
                .help(transcription.paused ? "Background transcription is paused" : "Transcribing new recordings in the background")

                if sync.isRunning {
                    Button { sync.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop syncing. Audio already downloaded is kept.")
                } else {
                    Button { sync.sync() } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                        .help("Download new recordings from the pendant")
                }
            }
        }
        // Status lives in its own bar so long messages never push the toolbar buttons around.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                if sync.isRunning || transcription.isRunning { ProgressView().controlSize(.small) }
                Text(statusText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let battery = sync.battery {
                    Label("\(battery)%", systemImage: "battery.75").fixedSize()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        // Control-Delete (or Command-Delete) removes the selected recording straight away,
        // whichever side of the window has focus. It goes to the Trash, so it can be recovered.
        .background {
            Group {
                Button("") { deleteSelectedNow() }.keyboardShortcut(.delete, modifiers: .control)
                Button("") { deleteSelectedNow() }.keyboardShortcut(.delete, modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { rec in
            Button("Move to Trash", role: .destructive) {
                if transcription.currentID == rec.id { return }
                if selection == rec.id { selection = nil; player.unload() }
                library.delete(rec)
            }
            Button("Cancel", role: .cancel) {}
        } message: { rec in
            Text(transcription.currentID == rec.id
                 ? "This recording is being transcribed right now. Try again when it finishes."
                 : "The audio and transcript from \(rec.timeText) will be moved to the Trash. It is no longer on the pendant.")
        }
    }

    private func deleteSelectedNow() {
        guard let rec = library.recording(withID: selection), transcription.currentID != rec.id else {
            NSSound.beep()
            return
        }
        // Move the selection to the neighbouring recording so you can keep going.
        let all = library.days.flatMap(\.recordings)
        var next: String?
        if let i = all.firstIndex(where: { $0.id == rec.id }) {
            next = i + 1 < all.count ? all[i + 1].id : (i > 0 ? all[i - 1].id : nil)
        }
        player.unload()
        library.delete(rec)
        selection = next
    }

    private var statusText: String {
        if sync.isRunning { return sync.status }
        if !transcription.status.isEmpty { return transcription.status }
        return sync.status
    }
}

struct RecordingDetail: View {
    let recording: Recording
    let onDelete: () -> Void
    @EnvironmentObject var player: Player
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(recording.day), \(recording.timeText)")
                    .font(.title3).bold()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if recording.timeUncertain {
                    Text("The pendant's clock was not set, so this time may be wrong.")
                        .font(.callout).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 10) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(player.error != nil)
                Text(clock(player.position)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 1))
                Text(clock(player.duration)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            if let error = player.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            // One main button plus a menu, so the row fits at any window width.
            HStack(spacing: 8) {
                Text("Transcript").font(.headline)
                Spacer(minLength: 8)
                Button {
                    copy(recording.transcript ?? "")
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(recording.transcript == nil)
                .help("Copy this transcript")
                .fixedSize()

                Menu {
                    Button("Copy Whole Day") {
                        copy(Markdown.dayText(dayKey: recording.dayKey, library: library) ?? "")
                    }
                    .disabled(Markdown.dayText(dayKey: recording.dayKey, library: library) == nil)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([recording.audioURL])
                    }
                    Divider()
                    Button("Delete…", role: .destructive, action: onDelete)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ScrollView {
                Text(recording.transcript ?? "Not transcribed yet.")
                    .foregroundStyle(recording.transcript == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(18)
        .onAppear { player.load(recording) }
        .onChange(of: recording.id) { _, _ in player.load(recording) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
