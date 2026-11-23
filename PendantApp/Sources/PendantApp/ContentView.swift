import SwiftUI

struct ContentView: View {
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var sync: SyncController
    @EnvironmentObject var player: Player
    @EnvironmentObject var transcription: TranscriptionQueue
    @State private var selected: Set<String> = []     // click, Shift-click or Command-click
    @State private var pendingDelete: Recording?
    @State private var editingID: String?          // the list row being renamed in place
    @State private var rowDraft = ""
    @FocusState private var rowFieldFocused: Bool
    @State private var nameDraft = ""
    @State private var combineError: String?
    @State private var combining = false
    @State private var selectedDay = Recording.todayKey
    @State private var calendarMonth = Date()
    @State private var combineMode = false     // ticking recordings to combine
    @State private var picked: Set<String> = []
    @State private var pickedInitialDay = false

    /// Recordings filed under the day picked in the calendar.
    private var dayRecordings: [Recording] {
        library.days.first { $0.id == selectedDay }?.recordings ?? []
    }
    private var dayTitle: String {
        guard let date = Recording.keyFormatter.date(from: selectedDay) else { return selectedDay }
        return Recording.dayFormatter.string(from: date)
    }
    private var dayTranscripts: String? { Markdown.dayText(dayKey: selectedDay, library: library) }

    /// The single selected recording's id, when exactly one is selected.
    private var selection: String? {
        get { selected.count == 1 ? selected.first : nil }
        nonmutating set { selected = newValue.map { [$0] } ?? [] }
    }
    /// Recordings chosen for combining: ticked in combine mode, otherwise the multi-selection.
    private var selectedRecordings: [Recording] {
        dayRecordings.filter { (combineMode ? picked : selected).contains($0.id) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                CalendarView(daysWithRecordings: Set(library.days.map(\.id)),
                             selectedDay: $selectedDay, month: $calendarMonth,
                             onCopyDay: { key in
                                 copyToClipboard(Markdown.dayText(dayKey: key, library: library) ?? "")
                             })

                HStack(spacing: 8) {
                    Button("Today") { goToToday() }
                        .disabled(selectedDay == Recording.todayKey
                                  && Calendar.current.isDate(calendarMonth, equalTo: Date(), toGranularity: .month))
                        .help("Go back to today")
                    Spacer(minLength: 4)
                    if combineMode {
                        Button("Cancel") { endCombineMode() }
                            .help("Stop choosing recordings")
                    } else {
                        Button {
                            picked = []
                            nameDraft = ""
                            combineError = nil
                            player.unload()
                            selected = []
                            combineMode = true
                        } label: {
                            Label("Combine", systemImage: "arrow.triangle.merge")
                        }
                        .disabled(dayRecordings.count < 2)
                        .help(dayRecordings.count < 2 ? "This day needs at least two recordings to combine"
                                                      : "Choose recordings from this day to join into one")
                    }
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

                Divider()

                List(selection: combineMode ? .constant([]) : $selected) {
                        ForEach(dayRecordings) { rec in
                            HStack(spacing: 6) {
                                if combineMode {
                                    Image(systemName: picked.contains(rec.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(picked.contains(rec.id) ? Color.accentColor : Color.secondary)
                                }
                                if editingID == rec.id {
                                    TextField("Name", text: $rowDraft)
                                        .textFieldStyle(.roundedBorder)
                                        .focused($rowFieldFocused)
                                        .onSubmit { finishRename(rec, save: true) }
                                        .onExitCommand { finishRename(rec, save: false) }
                                        .onChange(of: rowFieldFocused) { _, focused in
                                            if !focused, editingID == rec.id { finishRename(rec, save: true) }
                                        }
                                } else {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(rec.displayName).lineLimit(1)
                                        if rec.title != nil {
                                            Text(rec.listTimeText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                    // Double-click the name to rename it; a single click still selects.
                                    .onTapGesture(count: 2) { if !combineMode { startRename(rec) } }
                                }
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
                            .contentShape(Rectangle())
                            // While combining, a click anywhere on the row ticks or unticks it.
                            .gesture(TapGesture().onEnded {
                                if picked.contains(rec.id) { picked.remove(rec.id) } else { picked.insert(rec.id) }
                            }, including: combineMode ? .all : .subviews)
                            .contextMenu {
                                if selected.count >= 2, selected.contains(rec.id) {
                                    Button("Combine \(selected.count) Recordings…") { startCombine() }
                                    Button("Copy \(selected.count) Transcripts") {
                                        copyToClipboard(transcriptsText(for: selectedRecordings))
                                    }
                                    .disabled(selectedRecordings.allSatisfy { $0.transcript == nil })
                                    Divider()
                                }
                                Button("Rename…") { startRename(rec) }
                                Button("Move to Previous Day") { move(rec, byDays: -1) }
                                Button("Move to Next Day") { move(rec, byDays: 1) }
                                Divider()
                                Button("Delete…", role: .destructive) { pendingDelete = rec }
                            }
                        }
                }
                .onDeleteCommand {
                    pendingDelete = library.recording(withID: selection)
                }
                .overlay {
                    if dayRecordings.isEmpty {
                        Text(library.days.isEmpty
                             ? "No recordings yet.\nPress Sync to download from the pendant."
                             : "No recordings on this day.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 270)
        } detail: {
            if combineMode || selectedRecordings.count >= 2 {
                CombinePanel(recordings: selectedRecordings, name: $nameDraft, busy: combining,
                             error: combineError, onCombine: { combineSelected() })
            } else if let rec = library.recording(withID: selection) {
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
        .onChange(of: selectedDay) { _, newDay in
            // Keep the calendar on the month of the day being shown.
            if let date = Recording.keyFormatter.date(from: newDay) { calendarMonth = date }
            if let current = library.recording(withID: selection), current.dayKey != newDay { selection = nil }
            endCombineMode()
        }
        .onChange(of: library.days.count) { _, _ in pickInitialDay() }
        .onAppear { pickInitialDay() }
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
        .onChange(of: selected) { _, _ in combineError = nil }
        .onChange(of: picked) { _, _ in combineError = nil }
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

    /// On first launch show today, or the newest day with recordings if today has none.
    private func pickInitialDay() {
        guard !pickedInitialDay, !library.days.isEmpty else { return }
        pickedInitialDay = true
        if !library.days.contains(where: { $0.id == Recording.todayKey }), let newest = library.days.first {
            selectedDay = newest.id
        }
    }

    private func startRename(_ rec: Recording) {
        rowDraft = rec.title ?? ""
        editingID = rec.id
        DispatchQueue.main.async { rowFieldFocused = true }
    }

    private func finishRename(_ rec: Recording, save: Bool) {
        guard editingID == rec.id else { return }
        editingID = nil
        if save, rowDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (rec.title ?? "") {
            library.rename(rec, to: rowDraft)
        }
    }

    /// Selects the recordings for combining; the panel on the right has the name field and button.
    private func startCombine() {
        nameDraft = ""
        combineError = nil
    }

    private func combineSelected() {
        let recs = selectedRecordings
        guard recs.count >= 2, !combining else { return }
        if recs.contains(where: { transcription.currentID == $0.id }) {
            combineError = "One of these is being transcribed right now. Try again when it finishes."
            return
        }
        combining = true
        player.unload()
        let title = nameDraft
        Task {
            let result = await library.combine(recs, title: title)
            combining = false
            if let id = result.id {
                nameDraft = ""
                combineMode = false
                picked = []
                selected = [id]
                transcription.kick()     // transcribes it if the parts had no transcripts
            } else {
                combineError = result.error
            }
        }
    }

    /// The transcripts of several recordings in time order, each under a heading
    /// with its name, time and length. Recordings without a transcript are skipped.
    private func transcriptsText(for recs: [Recording]) -> String {
        recs.sorted { $0.start < $1.start }
            .compactMap { rec -> String? in
                guard let transcript = rec.transcript else { return nil }
                let name = rec.title.map { "\($0), " } ?? ""
                return "## \(name)\(rec.listTimeText) (\(rec.durationText))\n\n\(transcript)"
            }
            .joined(separator: "\n\n")
    }

    private func endCombineMode() {
        combineMode = false
        picked = []
        combineError = nil
    }

    private func goToToday() {
        selectedDay = Recording.todayKey
        calendarMonth = Date()
    }

    private func move(_ rec: Recording, byDays delta: Int) {
        guard transcription.currentID != rec.id else { NSSound.beep(); return }
        let wasSelected = selection == rec.id
        if wasSelected { player.unload() }
        if library.move(rec, byDays: delta) != nil, wasSelected { selection = nil }
    }

    private func deleteSelectedNow() {
        // With several selected, all of them go to the Trash.
        if selected.count >= 2 {
            let recs = selectedRecordings.filter { transcription.currentID != $0.id }
            player.unload()
            for rec in recs { library.delete(rec) }
            selected = []
            return
        }
        guard let rec = library.recording(withID: selection), transcription.currentID != rec.id else {
            NSSound.beep()
            return
        }
        // Move the selection to the neighbouring recording so you can keep going.
        let all = dayRecordings
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

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Shown on the right when two or more recordings are selected.
struct CombinePanel: View {
    let recordings: [Recording]
    @Binding var name: String
    let busy: Bool
    let error: String?
    let onCombine: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(recordings.count >= 2 ? "\(recordings.count) recordings selected" : "Choose recordings to combine")
                .font(.title3).bold()
            if recordings.count < 2 {
                Text("Tick two or more recordings in the list on the left.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(recordings) { rec in
                    HStack {
                        Text(rec.displayName).lineLimit(1)
                        Spacer()
                        Text(rec.durationText).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Divider()
                HStack {
                    Text("Combined length").foregroundStyle(.secondary)
                    Spacer()
                    Text(total).monospacedDigit()
                }
            }
            .frame(maxWidth: 420)

            TextField("Name for the combined recording (optional)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .onSubmit(onCombine)

            HStack(spacing: 10) {
                Button(action: onCombine) {
                    Label(busy ? "Combining…" : "Combine into One Recording", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || recordings.count < 2)
                if busy { ProgressView().controlSize(.small) }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Text("They are joined in time order. The audio is joined as it is, the transcripts are joined with their times adjusted, and the separate recordings are moved to the Trash.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: 420, alignment: .leading)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var total: String {
        let seconds = Int(recordings.map(\.seconds).reduce(0, +).rounded())
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

struct RecordingDetail: View {
    let recording: Recording
    let onDelete: () -> Void
    @EnvironmentObject var library: LibraryStore
    @State private var editingTitle = false
    @State private var titleDraft = ""
    @FocusState private var titleFocused: Bool
    @EnvironmentObject var player: Player
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                if editingTitle {
                    TextField("Name", text: $titleDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .frame(maxWidth: 420)
                        .focused($titleFocused)
                        .onSubmit { finishTitle(save: true) }
                        .onExitCommand { finishTitle(save: false) }
                        .onChange(of: titleFocused) { _, focused in
                            if !focused, editingTitle { finishTitle(save: true) }
                        }
                } else {
                    Text(recording.title ?? "\(recording.day), \(recording.timeText)")
                        .font(.title3).bold()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            titleDraft = recording.title ?? ""
                            editingTitle = true
                            DispatchQueue.main.async { titleFocused = true }
                        }
                        .help("Double-click to name this recording")
                }
                if recording.title != nil {
                    Text("\(recording.day), \(recording.timeText)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if recording.isFiledOnAnotherDay {
                    Text("Listed under \(recording.filedDayTitle).")
                        .font(.callout).foregroundStyle(.secondary)
                }
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
                    // A dot under the bar wherever two combined recordings meet. Click one to jump there.
                    .overlay(alignment: .bottomLeading) {
                        GeometryReader { geo in
                            let inset: CGFloat = 10      // the slider's knob keeps this much clear at each end
                            let span = max(geo.size.width - inset * 2, 1)
                            ForEach(recording.joins, id: \.self) { at in
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 7, height: 7)
                                    .contentShape(Rectangle().inset(by: -5))
                                    .onTapGesture { player.seek(to: at) }
                                    .help("The next combined recording starts here (\(clock(at)))")
                                    .position(x: inset + span * CGFloat(at / max(player.duration, 1)),
                                              y: geo.size.height + 5)
                            }
                        }
                    }
                    .padding(.bottom, recording.joins.isEmpty ? 0 : 8)
                Text(clock(player.duration)).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
            if let error = player.error {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            // ViewThatFits drops the button titles (icons only) if the window is too narrow.
            HStack(spacing: 8) {
                Text("Transcript").font(.headline).fixedSize()
                Spacer(minLength: 8)
                ViewThatFits(in: .horizontal) {
                    actionButtons.labelStyle(.titleAndIcon)
                    actionButtons.labelStyle(.iconOnly)
                }
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
        .onChange(of: recording.id) { _, _ in player.load(recording); copied = false; editingTitle = false }
    }

    private func finishTitle(save: Bool) {
        guard editingTitle else { return }
        editingTitle = false
        if save, titleDraft.trimmingCharacters(in: .whitespacesAndNewlines) != (recording.title ?? "") {
            library.rename(recording, to: titleDraft)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                copyToClipboard(recording.transcript ?? "")
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .disabled(recording.transcript == nil)
            .help("Copy this transcript")

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([recording.audioURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
            }
            .help("Show the audio file in Finder")

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .help("Move this recording to the Trash")
        }
        .fixedSize()
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
