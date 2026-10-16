import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Diisi oleh App setelah jendela siap. File yang dibuka sebelum itu disimpan dulu.
    weak var manager: TranscriptionManager? {
        didSet { flushPendingFile() }
    }
    private var pendingFile: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diperlukan agar jendela tampil normal saat dijalankan lewat `swift run`.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Dipanggil saat file dibuka lewat Finder ("Open With"), atau di-drop ke ikon Dock.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        pendingFile = url
        flushPendingFile()
    }

    private func flushPendingFile() {
        guard let manager, let url = pendingFile else { return }
        pendingFile = nil
        manager.setFile(url)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct AITranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var manager = TranscriptionManager()
    @StateObject private var player = AudioPlayer()

    var body: some Scene {
        Window("AI Transcriber", id: "main") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(player)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { appDelegate.manager = manager }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
