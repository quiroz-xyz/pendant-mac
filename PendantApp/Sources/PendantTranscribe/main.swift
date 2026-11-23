// pendant-transcribe: transcribes one recording with two models and compares them.
//
//   PendantTranscribe --audio FILE.opus --models DIR [--engines whisper,parakeet]
//
// Writes next to the audio file:
//   FILE.transcript.json   every piece, both models' text, language, agreement
//   FILE.txt               the readable transcript the app shows
//
// The audio is cut into pieces of at most ~28 s at its quietest points, and
// each piece is transcribed on its own. That lets Whisper detect the language
// per piece, so a conversation that moves between English and Spanish is
// transcribed in each language. Progress is printed as JSON lines.

import AVFoundation
import FluidAudio
import Foundation
import WhisperKit

// MARK: - Output helpers

func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var obj = fields
    obj["event"] = event
    if let data = try? JSONSerialization.data(withJSONObject: obj),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

func fail(_ message: String) -> Never {
    emit("error", ["message": message])
    exit(1)
}

// MARK: - Arguments

var audioPath = ""
var modelsDir = ""
var engines = ["whisper", "parakeet"]
var whisperModel = "openai_whisper-large-v3"
do {
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let flag = args.removeFirst()
        guard !args.isEmpty else { fail("Missing value for \(flag)") }
        let value = args.removeFirst()
        switch flag {
        case "--audio": audioPath = value
        case "--models": modelsDir = value
        case "--engines": engines = value.split(separator: ",").map(String.init)
        case "--whisper-model": whisperModel = value
        default: fail("Unknown option \(flag)")
        }
    }
}
guard !audioPath.isEmpty, !modelsDir.isEmpty else {
    fail("Usage: PendantTranscribe --audio FILE --models DIR [--engines whisper,parakeet]")
}
let audioURL = URL(fileURLWithPath: audioPath)
let modelsURL = URL(fileURLWithPath: modelsDir)
try? FileManager.default.createDirectory(at: modelsURL, withIntermediateDirectories: true)

// MARK: - Audio loading (any format macOS can read -> 16 kHz mono floats)

let sampleRate = 16_000

func loadAudio(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let inFormat = file.processingFormat
    guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate),
                                        channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
        throw NSError(domain: "pendant", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot convert audio format"])
    }
    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(file.length) * Double(sampleRate) / inFormat.sampleRate) + sampleRate)
    let inCapacity: AVAudioFrameCount = 48_000
    var reachedEnd = false
    while true {
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16_000) else { break }
        var convError: NSError?
        let status = converter.convert(to: outBuffer, error: &convError) { _, outStatus in
            if reachedEnd { outStatus.pointee = .endOfStream; return nil }
            guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCapacity) else {
                outStatus.pointee = .endOfStream; return nil
            }
            do { try file.read(into: inBuffer) } catch { reachedEnd = true }
            if inBuffer.frameLength == 0 {
                reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return inBuffer
        }
        if let convError { throw convError }
        if outBuffer.frameLength > 0, let channel = outBuffer.floatChannelData?[0] {
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength)))
        }
        if status == .endOfStream || status == .error || outBuffer.frameLength == 0 { break }
    }
    return samples
}

// MARK: - Cutting into pieces at quiet points

struct Piece {
    let start: Int   // sample index
    let end: Int
    var startSeconds: Double { Double(start) / Double(sampleRate) }
    var endSeconds: Double { Double(end) / Double(sampleRate) }
}

/// Cuts at pauses, so a piece is roughly one sentence or speaker turn.
/// Short pieces matter for mixed-language audio: a model tends to stay in the
/// language a piece starts in and drop what follows in another language.
func cutIntoPieces(_ samples: [Float]) -> [Piece] {
    let frame = sampleRate / 10                 // 100 ms
    let frameCount = samples.count / frame
    guard frameCount > 0 else { return samples.isEmpty ? [] : [Piece(start: 0, end: samples.count)] }

    var rms = [Float](repeating: 0, count: frameCount)
    for f in 0..<frameCount {
        var energy: Float = 0
        for i in (f * frame)..<((f + 1) * frame) { energy += samples[i] * samples[i] }
        rms[f] = (energy / Float(frame)).squareRoot()
    }
    // "Quiet" is relative to this recording's louder parts, so it still works
    // with background noise or music.
    let sorted = rms.sorted()
    let loud = sorted[min(frameCount - 1, frameCount * 3 / 4)]
    let quiet = max(loud * 0.2, 0.0005)

    let minFrames = 30       // do not cut pieces shorter than 3 s
    let maxFrames = 280      // never longer than 28 s
    let pauseFrames = 5      // a pause is 0.5 s of quiet

    var pieces: [Piece] = []
    var pieceStart = 0       // frame index
    var f = 0
    while f < frameCount {
        let length = f - pieceStart
        if rms[f] < quiet {
            var runEnd = f
            while runEnd < frameCount && rms[runEnd] < quiet { runEnd += 1 }
            if runEnd - f >= pauseFrames && length >= minFrames {
                let cut = (f + runEnd) / 2
                pieces.append(Piece(start: pieceStart * frame, end: cut * frame))
                pieceStart = cut
            }
            f = runEnd
            continue
        }
        if length >= maxFrames {
            // No pause found in time: cut at the quietest frame in the last 10 s.
            var best = f
            for g in max(pieceStart + minFrames, f - 100)...f where rms[g] < rms[best] { best = g }
            pieces.append(Piece(start: pieceStart * frame, end: best * frame))
            pieceStart = best
        }
        f += 1
    }
    if pieceStart * frame < samples.count {
        pieces.append(Piece(start: pieceStart * frame, end: samples.count))
    }
    return pieces
}

// MARK: - Comparing the two models

func normalizedWords(_ text: String) -> [String] {
    let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    return folded.split { !($0.isLetter || $0.isNumber) }.map(String.init)
}

/// 1.0 = same words in the same order; 0.0 = nothing in common.
func agreement(_ a: String, _ b: String) -> Double {
    let x = normalizedWords(a), y = normalizedWords(b)
    if x.isEmpty && y.isEmpty { return 1 }
    if x.isEmpty || y.isEmpty { return 0 }
    var prev = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        var cur = [Int](repeating: 0, count: y.count + 1)
        for j in 1...y.count {
            cur[j] = x[i - 1] == y[j - 1] ? prev[j - 1] + 1 : max(prev[j], cur[j - 1])
        }
        prev = cur
    }
    return 2.0 * Double(prev[y.count]) / Double(x.count + y.count)
}

func clock(_ seconds: Double) -> String {
    let total = Int(seconds)
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - Run

struct PieceResult {
    var whisperText = ""
    var whisperLanguage = ""
    var whisperNoSpeech: Double = 0
    var whisperLogProb: Double = 0
    var parakeetText = ""
    var parakeetConfidence: Double = 0
}

let started = Date()
let samples: [Float]
do {
    samples = try loadAudio(audioURL)
} catch {
    fail("Could not read audio: \(error.localizedDescription)")
}
let pieces = cutIntoPieces(samples)
var results = [PieceResult](repeating: PieceResult(), count: pieces.count)
let audioSeconds = Double(samples.count) / Double(sampleRate)
emit("loaded", ["seconds": audioSeconds, "pieces": pieces.count])

var timings: [String: Double] = [:]

if engines.contains("whisper") {
    let t0 = Date()
    emit("model", ["engine": "whisper", "state": "loading", "name": whisperModel])
    do {
        let config = WhisperKitConfig(model: whisperModel,
                                      downloadBase: modelsURL.appendingPathComponent("whisper"),
                                      verbose: false, logLevel: .error,
                                      prewarm: false, load: true, download: true)
        let whisper = try await WhisperKit(config)
        emit("model", ["engine": "whisper", "state": "ready", "load_seconds": Date().timeIntervalSince(t0)])
        let options = DecodingOptions(verbose: false, task: .transcribe, language: nil,
                                      temperature: 0, usePrefillPrompt: true, detectLanguage: true,
                                      skipSpecialTokens: true, withoutTimestamps: true)
        let t1 = Date()
        for (i, piece) in pieces.enumerated() {
            let chunk = Array(samples[piece.start..<piece.end])
            let out = try await whisper.transcribe(audioArray: chunk, decodeOptions: options)
            let text = out.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            let segs = out.flatMap(\.segments)
            results[i].whisperText = text
            results[i].whisperLanguage = out.first?.language ?? ""
            if !segs.isEmpty {
                results[i].whisperNoSpeech = Double(segs.map(\.noSpeechProb).reduce(0, +)) / Double(segs.count)
                results[i].whisperLogProb = Double(segs.map(\.avgLogprob).reduce(0, +)) / Double(segs.count)
            }
            emit("progress", ["engine": "whisper", "piece": i + 1, "of": pieces.count])
        }
        timings["whisper"] = Date().timeIntervalSince(t1)
    } catch {
        fail("Whisper failed: \(error.localizedDescription)")
    }
}

if engines.contains("parakeet") {
    let t0 = Date()
    emit("model", ["engine": "parakeet", "state": "loading", "name": "parakeet-tdt-v3"])
    do {
        let models = try await AsrModels.downloadAndLoad(to: modelsURL.appendingPathComponent("parakeet-v3"),
                                                         version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        emit("model", ["engine": "parakeet", "state": "ready", "load_seconds": Date().timeIntervalSince(t0)])
        let t1 = Date()
        for (i, piece) in pieces.enumerated() {
            let chunk = Array(samples[piece.start..<piece.end])
            // Parakeet needs at least about a second of audio.
            if chunk.count >= sampleRate {
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let out = try await manager.transcribe(chunk, decoderState: &state)
                results[i].parakeetText = out.text.trimmingCharacters(in: .whitespacesAndNewlines)
                results[i].parakeetConfidence = Double(out.confidence)
            }
            emit("progress", ["engine": "parakeet", "piece": i + 1, "of": pieces.count])
        }
        timings["parakeet"] = Date().timeIntervalSince(t1)
    } catch {
        fail("Parakeet failed: \(error.localizedDescription)")
    }
}

// MARK: - Write results

let both = engines.contains("whisper") && engines.contains("parakeet")
var jsonPieces: [[String: Any]] = []
var lines: [String] = []
var flaggedCount = 0

for (i, piece) in pieces.enumerated() {
    let r = results[i]
    let primary = engines.contains("whisper") ? r.whisperText : r.parakeetText
    let score = both ? agreement(r.whisperText, r.parakeetText) : 1.0
    let wordCount = max(normalizedWords(r.whisperText).count, normalizedWords(r.parakeetText).count)
    // No speech: nothing transcribed, or Whisper itself says it is probably not speech.
    // Whisper writes music as symbols (♪) with no words; that counts as no speech too.
    let speech = !normalizedWords(primary).isEmpty && !(engines.contains("whisper") && r.whisperNoSpeech > 0.6)
    let flagged = both && speech && wordCount >= 3 && score < 0.6
    if flagged { flaggedCount += 1 }

    jsonPieces.append([
        "start": piece.startSeconds, "end": piece.endSeconds,
        "language": r.whisperLanguage,
        "whisper": r.whisperText, "whisper_no_speech": r.whisperNoSpeech, "whisper_logprob": r.whisperLogProb,
        "parakeet": r.parakeetText, "parakeet_confidence": r.parakeetConfidence,
        "agreement": score, "speech": speech, "flagged": flagged,
    ])

    guard speech else { continue }
    let lang = r.whisperLanguage.isEmpty ? "" : " (\(r.whisperLanguage))"
    if flagged {
        lines.append("[\(clock(piece.startSeconds))]\(lang) ⚠ models disagree, check by ear")
        lines.append("    Whisper:  \(r.whisperText)")
        lines.append("    Parakeet: \(r.parakeetText.isEmpty ? "(nothing)" : r.parakeetText)")
    } else {
        lines.append("[\(clock(piece.startSeconds))]\(lang) \(primary)")
    }
}

let base = audioURL.deletingPathExtension()
let summary: [String: Any] = [
    "audio": audioURL.lastPathComponent,
    "seconds": audioSeconds,
    "engines": engines,
    "whisper_model": whisperModel,
    "timings": timings,
    "flagged": flaggedCount,
    "transcribed_at": ISO8601DateFormatter().string(from: Date()),
    "pieces": jsonPieces,
]
do {
    let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: base.appendingPathExtension("transcript.json"), options: .atomic)
    let text = lines.isEmpty ? "(No speech found in this recording.)" : lines.joined(separator: "\n")
    try text.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
} catch {
    fail("Could not save transcript: \(error.localizedDescription)")
}

emit("done", ["seconds": audioSeconds, "pieces": pieces.count, "flagged": flaggedCount,
              "timings": timings, "total_seconds": Date().timeIntervalSince(started)])
