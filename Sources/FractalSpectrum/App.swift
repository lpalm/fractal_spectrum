import SwiftUI
import AppKit
import FractalKit

@main
struct FractalSpectrumApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Spectrum") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1560, height: 980)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {
                Button("Export Image…") {
                    model.export.kind = .image
                    model.showExport = true
                }
                .keyboardShortcut("s", modifiers: .command)
                Button("Export Zoom Video…") {
                    model.export.kind = .video
                    model.showExport = true
                }
                .keyboardShortcut("e", modifiers: .command)
                Button(model.recordingSince == nil ? "Start Recording" : "Stop Recording") { model.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Image") { model.copyImage() }.keyboardShortcut("c", modifiers: [.command, .option])
            }
            CommandMenu("Navigate") {
                Button("Home") { model.goHome() }.keyboardShortcut("h", modifiers: [])
                Button("Zoom In") { model.zoomStep(-1) }.keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { model.zoomStep(1) }.keyboardShortcut("-", modifiers: .command)
                Divider()
                Button(model.autopilot ? "Stop Autopilot" : "Start Autopilot") { model.autopilot.toggle() }
                    .keyboardShortcut("p", modifiers: [])
                Button("Back") { model.goBack() }.keyboardShortcut("[", modifiers: .command)
                Button("Forward") { model.goForward() }.keyboardShortcut("]", modifiers: .command)
                Button("Go to Coordinates…") { model.showGoTo = true }.keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Find Mini-Mandelbrot") { model.findMinibrot() }.keyboardShortcut("m", modifiers: [])
                Button("Copy Coordinates") { model.copyCoordinates() }.keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("Fractal") {
                ForEach(FractalFamily.allCases) { f in
                    Button(f.displayName) { model.selectFamily(f) }
                }
                Divider()
                Button(model.formula.julia ? "Back to Parameter Plane" : "Julia Set of View Centre") { model.toggleJulia() }
                    .keyboardShortcut("j", modifiers: [])
            }
            CommandGroup(after: .sidebar) {
                Button(model.showUI ? "Hide Interface" : "Show Interface") { model.showUI.toggle() }
                    .keyboardShortcut(.space, modifiers: [])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting finishes a recording (keeping it) and would abandon a running export: after asking,
    /// the export is cancelled (removing its partly written file) before the app terminates.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model, model.recordingSince != nil || model.export.running else { return .terminateNow }
            model.stopRecording { self.confirmExport(of: model) }
            return .terminateLater
        }
    }

    @MainActor private func confirmExport(of model: AppModel) {
        let export = model.export
        guard export.running else {
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        let alert = NSAlert()
        alert.messageText = "An export is still running"
        alert.informativeText = "Quitting now cancels it."
        alert.addButton(withTitle: "Keep Exporting")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertSecondButtonReturn else {
            NSApp.reply(toApplicationShouldTerminate: false)
            return
        }
        export.onFinish = { NSApp.reply(toApplicationShouldTerminate: true) }
        export.cancel()
    }
}
