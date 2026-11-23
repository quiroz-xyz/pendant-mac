import AVFoundation
import Foundation

/// Plays a recording with AVAudioEngine, reading through AVAudioFile.
/// (AVAudioPlayer stops early on the pendant's Ogg Opus files: it ended a
/// 15.9 s clip at about 10.5 s. AVAudioFile decodes them completely.)
@MainActor
final class Player: ObservableObject {
    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var sampleRate: Double = 48_000
    private var startFrame: AVAudioFramePosition = 0   // where the current segment began
    private var generation = 0                          // ignores callbacks from old segments
    private var timer: Timer?
    private var loadedID: String?
    private var attached = false

    func load(_ recording: Recording) {
        guard loadedID != recording.id else { return }
        stop()
        loadedID = recording.id
        error = nil
        do {
            let f = try AVAudioFile(forReading: recording.audioURL)
            file = f
            sampleRate = f.processingFormat.sampleRate
            duration = Double(f.length) / sampleRate
            position = 0
            if !attached {
                engine.attach(node)
                attached = true
            }
            engine.connect(node, to: engine.mainMixerNode, format: f.processingFormat)
        } catch {
            file = nil
            duration = recording.seconds
            self.error = "This recording could not be opened for playback."
        }
    }

    /// Forget the loaded recording (used when it is deleted).
    func unload() {
        stop()
        file = nil
        loadedID = nil
        duration = 0
    }

    func toggle() {
        isPlaying ? pause() : play(from: position >= duration - 0.2 ? 0 : position)
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), duration)
        if isPlaying { play(from: target) } else { position = target }
    }

    func stop() {
        generation += 1
        node.stop()
        timer?.invalidate()
        isPlaying = false
        position = 0
    }

    private func pause() {
        let here = currentSeconds()
        generation += 1
        node.stop()
        timer?.invalidate()
        isPlaying = false
        position = here
    }

    private func play(from seconds: Double) {
        guard let file else { return }
        generation += 1
        let mine = generation
        node.stop()
        let frame = AVAudioFramePosition(seconds * sampleRate)
        let remaining = file.length - frame
        guard remaining > 0 else { position = 0; isPlaying = false; return }
        startFrame = frame
        node.scheduleSegment(file, startingFrame: frame, frameCount: AVAudioFrameCount(remaining), at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.finished(generation: mine) }
        }
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            self.error = "Audio could not start: \(error.localizedDescription)"
            return
        }
        node.play()
        isPlaying = true
        position = seconds
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.position = min(self.currentSeconds(), self.duration)
            }
        }
    }

    private func finished(generation finishedGeneration: Int) {
        guard finishedGeneration == generation else { return }   // a newer play/seek replaced it
        timer?.invalidate()
        isPlaying = false
        position = 0
    }

    private func currentSeconds() -> Double {
        guard let nodeTime = node.lastRenderTime, let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return position
        }
        return Double(startFrame + playerTime.sampleTime) / sampleRate
    }
}
