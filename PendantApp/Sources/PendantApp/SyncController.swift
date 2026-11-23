import Foundation

/// Runs pendant_drain.py and turns its JSON progress lines into status text.
@MainActor
final class SyncController: ObservableObject {
    @Published var isRunning = false
    @Published var status = "Not synced yet"
    @Published var battery: Int?
    /// Raw event lines, kept for troubleshooting and the self-test.
    @Published var log: [String] = []

    private var process: Process?
    var onFinished: (() -> Void)?

    func sync() {
        guard !isRunning else { return }
        isRunning = true
        log = []
        Task {
            if Config.pendantAddress == nil {
                status = "Looking for the pendant…"
                await run(["scan"])
            }
            if let address = Config.pendantAddress {
                status = "Connecting…"
                await run(["sync", "--address", address, "--library", Config.libraryURL.path])
            }
            isRunning = false
            onFinished?()
        }
    }

    /// Ask the running sync to finish up. Audio already received is kept.
    func stop() {
        process?.interrupt()
        status = "Stopping…"
    }

    private func run(_ arguments: [String]) async {
        let python = Config.pythonPath
        let driver = Config.driverPath
        guard FileManager.default.isExecutableFile(atPath: python), !driver.isEmpty else {
            status = "Setup problem: Python or the sync script is missing."
            log.append("python=\(python) driver=\(driver)")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [driver] + arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()   // pendant-cli's log chatter; not shown
        process = p

        do { try p.run() } catch {
            status = "Could not start sync: \(error.localizedDescription)"
            return
        }
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                handle(line)
            }
        } catch {
            log.append("read error: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        process = nil
    }

    private func handle(_ line: String) {
        log.append(line)
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String else { return }
        switch event {
        case "found":
            Config.pendantAddress = obj["address"] as? String
            status = "Found the pendant"
        case "connected":
            battery = obj["battery"] as? Int
            status = "Connected, downloading…"
        case "progress":
            let kb = (obj["bytes"] as? Int ?? 0) / 1024
            status = "Downloading… \(kb) KB"
        case "recovering":
            status = "Recovering an interrupted sync…"
        case "error":
            status = "Sync problem: \(obj["message"] as? String ?? "unknown")"
        case "done":
            let count = (obj["recordings"] as? [Any])?.count ?? 0
            let reason = obj["stop_reason"] as? String ?? ""
            if reason != "error" {
                let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
                status = count == 0 ? "Synced at \(time): nothing new"
                                    : "Synced at \(time): \(count) new recording\(count == 1 ? "" : "s")"
            }
        default:
            break
        }
    }
}
