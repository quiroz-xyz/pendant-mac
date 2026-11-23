import Foundation

struct Recording: Identifiable, Hashable {
    let id: String          // audio file path
    let audioURL: URL
    let start: Date
    let seconds: Double
    let timeUncertain: Bool
    /// A name you gave the recording, if any.
    var title: String? = nil
    /// For a combined recording: where each joined part begins, in seconds.
    var joins: [Double] = []
    /// What to call it in lists: its name, or its time.
    var displayName: String { title ?? listTimeText }

    var day: String { Recording.dayFormatter.string(from: start) }
    /// Folder name of the day this recording is filed under, e.g. 2026-11-23.
    var dayKey: String { audioURL.deletingLastPathComponent().lastPathComponent }
    var timeText: String { Recording.timeFormatter.string(from: start) }

    /// Heading for the day this recording is filed under (which can differ from
    /// the day it was actually recorded, if it was moved to the night before).
    var filedDayTitle: String {
        guard let date = Recording.keyFormatter.date(from: dayKey) else { return day }
        return Recording.dayFormatter.string(from: date)
    }
    /// True when the recording is filed under a different day than it was recorded on.
    var isFiledOnAnotherDay: Bool { Recording.keyFormatter.string(from: start) != dayKey }
    /// Time for the list; adds the real date when filed under another day.
    var listTimeText: String {
        isFiledOnAnotherDay ? "\(timeText) · \(Recording.shortDayFormatter.string(from: start))" : timeText
    }
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
    static let keyFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static let shortDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    static var todayKey: String { keyFormatter.string(from: Date()) }
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}

struct DayGroup: Identifiable {
    let id: String          // day folder, e.g. 2026-11-23
    let recordings: [Recording]
    var title: String { recordings.first?.filedDayTitle ?? id }
}

@MainActor
final class LibraryStore: ObservableObject {
    @Published var days: [DayGroup] = []

    private struct Sidecar: Decodable {
        let file: String
        let start: String
        let seconds: Double
        let time_uncertain: Bool?
        let title: String?
        let joins: [Double]?
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
                                     seconds: side.seconds, timeUncertain: side.time_uncertain ?? false,
                                     title: (side.title?.isEmpty ?? true) ? nil : side.title,
                                     joins: side.joins ?? []))
            }
        }
        // Group by the day folder a recording is filed in; newest day first,
        // and within a day in the order things happened.
        let byDay = Dictionary(grouping: all, by: \.dayKey)
        days = byDay.keys.sorted(by: >).map { key in
            DayGroup(id: key, recordings: (byDay[key] ?? []).sorted { $0.start < $1.start })
        }
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

    /// Files a recording under the day before (-1) or after (+1). The recording
    /// keeps its real time; only the day it is listed under changes.
    /// Returns the recording's new id, or nil if it could not be moved.
    func move(_ rec: Recording, byDays delta: Int) -> String? {
        guard let current = Recording.keyFormatter.date(from: rec.dayKey),
              let target = Calendar.current.date(byAdding: .day, value: delta, to: current) else { return nil }
        let targetKey = Recording.keyFormatter.string(from: target)
        let fm = FileManager.default
        let targetDir = Config.libraryURL.appendingPathComponent("audio").appendingPathComponent(targetKey)
        try? fm.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let ext = rec.audioURL.pathExtension
        let oldBase = rec.audioURL.deletingPathExtension()
        var stem = oldBase.lastPathComponent
        var n = 1
        while fm.fileExists(atPath: targetDir.appendingPathComponent("\(stem).\(ext)").path) {
            n += 1
            stem = "\(oldBase.lastPathComponent)-\(n)"
        }
        let newBase = targetDir.appendingPathComponent(stem)
        let newAudio = newBase.appendingPathExtension(ext)
        do {
            try fm.moveItem(at: rec.audioURL, to: newAudio)
        } catch { return nil }
        for suffix in ["txt", "transcript.json"] {
            let from = oldBase.appendingPathExtension(suffix)
            if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: newBase.appendingPathExtension(suffix)) }
        }
        // The details file names the audio file, so rewrite it for the new name.
        let oldSide = oldBase.appendingPathExtension("json")
        if let data = try? Data(contentsOf: oldSide),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj["file"] = newAudio.lastPathComponent
            if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
                try? out.write(to: newBase.appendingPathExtension("json"))
                try? fm.removeItem(at: oldSide)
            }
        }
        if (try? fm.contentsOfDirectory(atPath: rec.audioURL.deletingLastPathComponent().path))?.isEmpty == true {
            try? fm.removeItem(at: rec.audioURL.deletingLastPathComponent())
        }
        reload()
        for key in [rec.dayKey, targetKey] { rewriteMarkdown(dayKey: key) }
        return newAudio.path
    }

    /// Gives a recording a name (or clears it when the name is empty).
    func rename(_ rec: Recording, to newTitle: String) {
        let side = rec.audioURL.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: side),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { obj.removeValue(forKey: "title") } else { obj["title"] = trimmed }
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? out.write(to: side, options: .atomic)
        }
        reload()
        rewriteMarkdown(dayKey: rec.dayKey)
    }

    /// Joins several recordings into one (audio is joined without re-encoding;
    /// transcripts are joined with their times shifted). The originals go to the Trash.
    /// Returns the new recording's id, or an error message.
    func combine(_ recs: [Recording], title: String) async -> (id: String?, error: String?) {
        guard recs.count >= 2, let first = recs.min(by: { $0.start < $1.start }) else {
            return (nil, "Pick at least two recordings to combine.")
        }
        let python = Config.pythonPath, driver = Config.driverPath
        guard FileManager.default.isExecutableFile(atPath: python), !driver.isEmpty else {
            return (nil, "Setup problem: Python or the sync script is missing.")
        }
        let outDir = first.audioURL.deletingLastPathComponent()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [driver, "combine", "--out-dir", outDir.path, "--title", title] + recs.map(\.audioURL.path)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (nil, "Could not start: \(error.localizedDescription)") }
        var newPath: String?
        var message: String?
        if let lines = try? await out.fileHandleForReading.bytes.lines.reduce(into: [String](), { $0.append($1) }) {
            for line in lines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if obj["event"] as? String == "combined" { newPath = obj["path"] as? String }
                if obj["event"] as? String == "error" { message = obj["message"] as? String }
            }
        }
        p.waitUntilExit()
        guard let newPath, FileManager.default.fileExists(atPath: newPath) else {
            return (nil, message ?? "Combining failed.")
        }
        // Only now that the combined file exists do the originals go to the Trash.
        for rec in recs {
            let base = rec.audioURL.deletingPathExtension()
            for url in [rec.audioURL, base.appendingPathExtension("json"),
                        base.appendingPathExtension("txt"), base.appendingPathExtension("transcript.json")]
            where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        reload()
        for key in Set(recs.map(\.dayKey)) { rewriteMarkdown(dayKey: key) }
        return (newPath, nil)
    }

    private func rewriteMarkdown(dayKey: String) {
        let url = Markdown.dayURL(dayKey)
        if let text = Markdown.dayText(dayKey: dayKey, library: self) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func recording(withID id: String?) -> Recording? {
        guard let id else { return nil }
        for day in days { if let r = day.recordings.first(where: { $0.id == id }) { return r } }
        return nil
    }
}
