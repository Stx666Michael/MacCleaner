import SwiftUI
import AppKit

@main
struct MacCleanerApp: App {
    @StateObject private var viewModel = MainViewModel()

    init() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--generate-screenshots") {
            let outDir = (idx + 1 < args.count) ? args[idx + 1] : "docs"
            do {
                try ScreenshotGenerator.generateAll(docsDir: outDir)
                exit(0)
            } catch {
                fputs("Failed to generate screenshots: \(error)\n", stderr)
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainWindowView(vm: viewModel)
                .frame(minWidth: 920, minHeight: 640)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    if let window = NSApplication.shared.windows.first {
                        window.title = "MacCleaner"
                        window.titleVisibility = .hidden
                        window.titlebarAppearsTransparent = true
                        window.backgroundColor = Theme.nsWindowBg
                        window.setContentSize(NSSize(width: 1120, height: 760))
                        window.center()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
    }
}
