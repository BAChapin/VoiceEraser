import AppKit
import SwiftUI

@main
struct VoiceEraserApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("VoiceEraser", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 520, minHeight: 460)
                .onAppear { appDelegate.model = model }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
        }
    }
}

/// Receives files opened from Finder ("Open With", or dropped on the Dock
/// icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet {
            guard let model, let url = pendingURL else { return }
            pendingURL = nil
            model.open(url)
        }
    }

    private var pendingURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model {
            model.open(url)
        } else {
            pendingURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
