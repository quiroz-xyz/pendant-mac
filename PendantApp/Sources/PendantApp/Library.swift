import Foundation

struct Recording: Identifiable, Hashable {
    let id: String          // audio file path
    let audioURL: URL
    let start: Date
    let seconds: Double
    let timeUncertain: Bool

    var day: String { Recording.dayFormatter.string(from: start) }
    /// Folder name of the day this recording is filed under, e.g. 2026-11-23.
    var dayKey: String { audioURL.deletingLastPathComponent().lastPathComponent }
    var timeText: String { Recording.timeFormatter.string(from: start) }
    var durationText: String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Transcript text if one has been written next to the audio file.
    var transcriptURL: URL { audioURL.deletingPathExtension().appendingPathExtension("txt") }
    var transcript: String? {
        guard let text = try? String(contentsOf: transcriptURL, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d, yyyy"; return f
    }()
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}

struct DayGroup: Identifiable {
    let id: String
    let recordings: [Recording]
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var days: [DayGroup] = []

    private struct Sidecar: Decodable {
        let file: String
        let start: String
        let seconds: Double
        let time_uncertain: Bool?
    }

    func reload() {
        let audioRoot = Config.libraryURL.appendingPathComponent("audio")
        let fm = FileManager.default
        var all: [Recording] = []
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        iso.locale = Locale(identifier: "en_US_POSIX")

        let dayDirs = (try? fm.contentsOfDirectory(at: audioRoot, includingPropertiesForKeys: nil)) ?? []
        for dir in dayDirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for json in files where json.pathExtension == "json" && !json.lastPathComponent.hasSuffix(".transcript.json") {
                guard let data = try? Data(contentsOf: json),
                      let side = try? JSONDecoder().decode(Sidecar.self, from: data),
                      let start = iso.date(from: side.start) else { continue }
                let audio = dir.appendingPathComponent(side.file)
                guard fm.fileExists(atPath: audio.path) else { continue }
                all.append(Recording(id: audio.path, audioURL: audio, start: start,
                                     seconds: side.seconds, timeUncertain: side.time_uncertain ?? false))
            }
        }
        all.sort { $0.start > $1.start }
        var groups: [DayGroup] = []
        for rec in all {
            if let last = groups.last, last.id == rec.day {
                groups[groups.count - 1] = DayGroup(id: last.id, recordings: last.recordings + [rec])
            } else {
                groups.append(DayGroup(id: rec.day, recordings: [rec]))
            }
        }
        days = groups
    }

    /// Moves a recording's audio and transcript files to the Trash.
    func delete(_ rec: Recording) {
        let base = rec.audioURL.deletingPathExtension()
        let files = [rec.audioURL,
                     base.appendingPathExtension("json"),
                     base.appendingPathExtension("txt"),
                     base.appendingPathExtension("transcript.json")]
        for url in files where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
        reload()
        // Rewrite that day's Markdown without it (or remove it if the day is now empty).
        let dayURL = Markdown.dayURL(rec.dayKey)
        if let text = Markdown.dayText(dayKey: rec.dayKey, library: self) {
            try? text.write(to: dayURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: dayURL)
        }
    }

    func recording(withID id: String?) -> Recording? {
        guard let id else { return nil }
        for day in days { if let r = day.recordings.first(where: { $0.id == id }) { return r } }
        return nil
    }
}
