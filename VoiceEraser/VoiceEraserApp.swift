import AppKit
import SwiftUI

@main
struct VoiceEraserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("VoiceEraser", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 620, minHeight: 520)
                .onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                    .disabled(model.isRunning)
            }
        }
    }
}

/// Receives files opened from Finder ("Open With", or dropped on the Dock
/// icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet {
            guard let model, !pendingURLs.isEmpty else { return }
            model.add(pendingURLs)
            pendingURLs = []
        }
    }

    private var pendingURLs: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            model.add(urls)
        } else {
            pendingURLs += urls
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
