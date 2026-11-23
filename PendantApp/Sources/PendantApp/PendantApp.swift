import SwiftUI

@main
struct PendantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var library = LibraryStore()
    @StateObject private var sync = SyncController()
    @StateObject private var player = Player()
    @StateObject private var transcription = TranscriptionQueue()

    var body: some Scene {
        WindowGroup("Pendant") {
            ContentView()
                .environmentObject(library)
                .environmentObject(sync)
                .environmentObject(player)
                .environmentObject(transcription)
                .frame(minWidth: 760, minHeight: 460)
                .onAppear {
                    library.reload()
                    transcription.library = library
                    sync.onFinished = { library.reload(); SelfTest.finish(sync); transcription.kick() }
                    transcription.kick()
                    SelfTest.startIfRequested(sync)
                }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Development aid: `open Pendant.app --args --selftest-sync <log-file>`
/// runs one sync at launch and writes the event lines to the log file.
@MainActor
enum SelfTest {
    static var logURL: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest-sync"), args.count > i + 1 else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }
    static func startIfRequested(_ sync: SyncController) {
        if logURL != nil { sync.sync() }
    }
    static func finish(_ sync: SyncController) {
        guard let logURL else { return }
        let text = (sync.log + ["status: \(sync.status)"]).joined(separator: "\n")
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
    }
}
