import Foundation

/// Transcribes recordings one at a time, in a separate low-priority process,
/// so the Mac stays responsive. Picks up any recording without a transcript.
@MainActor
final class TranscriptionQueue: ObservableObject {
    @Published var status = ""
    @Published var isRunning = false
    @Published var paused = UserDefaults.standard.bool(forKey: "transcriptionPaused") {
        didSet {
            UserDefaults.standard.set(paused, forKey: "transcriptionPaused")
            if paused { process?.terminate() } else { kick() }
        }
    }
    /// The recording being transcribed right now, for the list's status marks.
    @Published var currentID: String?

    private var process: Process?
    private var failed: Set<String> = []
    weak var library: LibraryStore?

    static var toolPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/PendantTranscribe").path
    }
    static var modelsURL: URL {
        Config.libraryURL.deletingLastPathComponent().appendingPathComponent("Models")
    }

    /// Start working through the queue if it is not already running.
    func kick() {
        guard !isRunning, !paused, let library else { return }
        isRunning = true
        Task {
            while !paused, let next = nextRecording(in: library) {
                currentID = next.id
                let ok = await transcribe(next)
                if !ok && !paused { failed.insert(next.id) }
                currentID = nil
                if ok { Markdown.writeDay(for: next, library: library) }
                library.reload()
            }
            isRunning = false
            if paused {
                status = "Transcription paused"
            } else if failed.isEmpty {
                status = ""
            }
        }
    }

    private func nextRecording(in library: LibraryStore) -> Recording? {
        // Newest first, so what you just synced is ready soonest.
        library.days.flatMap(\.recordings).sorted { $0.start > $1.start }
            .first { $0.transcript == nil && !failed.contains($0.id) }
    }

    private func transcribe(_ rec: Recording) async -> Bool {
        let tool = Self.toolPath
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            status = "Transcription tool is missing from the app."
            paused = true
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = ["--audio", rec.audioURL.path, "--models", Self.modelsURL.path]
        p.qualityOfService = .background     // run slowly, stay out of the way
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        process = p
        status = "Transcribing \(rec.timeText)…"
        do { try p.run() } catch {
            status = "Could not start transcription: \(error.localizedDescription)"
            return false
        }
        var finished = false
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let event = obj["event"] as? String else { continue }
                switch event {
                case "model":
                    if obj["state"] as? String == "loading" {
                        status = "Transcribing \(rec.timeText): loading \(obj["engine"] as? String ?? "model")…"
                    }
                case "progress":
                    let engine = (obj["engine"] as? String ?? "").capitalized
                    status = "Transcribing \(rec.timeText): \(engine) \(obj["piece"] as? Int ?? 0)/\(obj["of"] as? Int ?? 0)"
                case "error":
                    status = "Transcription problem: \(obj["message"] as? String ?? "unknown")"
                case "done":
                    finished = true
                default: break
                }
            }
        } catch {}
        p.waitUntilExit()
        process = nil
        return finished && p.terminationStatus == 0
    }
}

/// Writes one Markdown file per day with every transcript from that day.
enum Markdown {
    static func dayURL(_ dayKey: String) -> URL {
        Config.libraryURL.appendingPathComponent("transcripts").appendingPathComponent("\(dayKey).md")
    }

    @MainActor
    static func dayText(dayKey: String, library: LibraryStore) -> String? {
        let recs = library.days.flatMap(\.recordings)
            .filter { $0.dayKey == dayKey && $0.transcript != nil }
            .sorted { $0.start < $1.start }
        guard let first = recs.first else { return nil }
        var text = "# Pendant transcripts: \(first.filedDayTitle)\n"
        for rec in recs {
            let name = rec.title.map { "\($0), " } ?? ""
            text += "\n## \(name)\(rec.listTimeText) (\(rec.durationText))\n\n\(rec.transcript ?? "")\n"
        }
        return text
    }

    @MainActor
    static func writeDay(for rec: Recording, library: LibraryStore) {
        library.reload()
        guard let text = dayText(dayKey: rec.dayKey, library: library) else { return }
        let url = dayURL(rec.dayKey)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
