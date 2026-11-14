import AppKit
import SwiftUI

@main
struct E1RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings.shared
    @StateObject private var pipeline = Pipeline.shared
    @StateObject private var recorder = MacRecorder.shared

    init() {
        Pipeline.shared.start()
        if UIPreview.enabled { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { UIPreview.show() } }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel().environmentObject(settings).environmentObject(pipeline)
        } label: {
            Image(nsImage: recorder.isRecording ? MenuBarIcon.frame(settings.menuIcon, Int(recorder.elapsed * 3)) : pipeline.menuBarImage)
        }
        .menuBarExtraStyle(.window)

        Window("偏好设置", id: "settings") {
            SettingsView().environmentObject(settings).environmentObject(pipeline)
        }
        .windowResizability(.contentSize)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("欢迎使用", id: "welcome") {
            WelcomeView().environmentObject(settings).environmentObject(pipeline)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(AppSettings.shared.onboardingDone || UIPreview.enabled ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        WindowGroup("为发言人命名", id: "speakers", for: String.self) { $jobId in
            if let jobId { SpeakerNamingView(jobId: jobId).environmentObject(settings).environmentObject(pipeline) }
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// Developer aid: `E1Recorder -uiPreview YES [-previewSection device | -previewPanel YES] [-previewPen off]` opens the
/// real menu bar panel (and, unless `previewPanel`, the preferences) with a simulated pen, no Keychain access and no uploads.
enum UIPreview {
    #if E1_PREVIEW
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "uiPreview") }
    #else
    static let enabled = false   // release builds can't be switched into screenshot mode
    #endif
    static var panelOnly: Bool { UserDefaults.standard.bool(forKey: "previewPanel") }

    @MainActor static var openedSettings = false

    @MainActor static var windows: [NSWindow] = []

    /// Shows the panel in a borderless glass window shaped like the system's menu bar panel, so it can be
    /// screenshotted (the real panel only opens from a click on the menu bar icon).
    @MainActor static func show() {
        if UserDefaults.standard.bool(forKey: "previewDark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        if UserDefaults.standard.string(forKey: "previewSection") == "components" {
            let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "组件预览"
            w.contentView = NSHostingView(rootView: Form { PenComponentsSection() }.formStyle(.grouped).frame(width: 600, height: 380)
                .environmentObject(AppSettings.shared).environmentObject(Pipeline.shared))
            w.makeKeyAndOrderFront(nil)
            windows.append(w)
        }
        let size = NSSize(width: 300, height: 560)
        let w = NSPanel(contentRect: NSRect(origin: NSPoint(x: 120, y: 260), size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        let host = NSHostingView(rootView: MenuPanel().environmentObject(AppSettings.shared).environmentObject(Pipeline.shared))
        host.frame = NSRect(origin: .zero, size: size)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: host.frame)
            glass.cornerRadius = 18
            glass.contentView = host
            w.contentView = glass
        } else {
            let fx = NSVisualEffectView(frame: host.frame)
            fx.material = .popover; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 12
            fx.addSubview(host)
            w.contentView = fx
        }
        let fit = host.fittingSize
        w.setContentSize(NSSize(width: 300, height: fit.height))
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        windows.append(w)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Audio files opened with the app (dragged onto its icon, or「打开方式」in Finder) are imported for transcription.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) { Pipeline.flushWrites() }

    func application(_ application: NSApplication, open urls: [URL]) {
        let audio = urls.filter { ["m4a", "mp3", "wav", "aac", "aiff", "aif", "caf", "flac", "mp4", "mov", "amr", "ogg", "opus", "wma"].contains($0.pathExtension.lowercased()) }
        guard !audio.isEmpty else { return }
        Task { @MainActor in await Pipeline.shared.importFiles(audio) }
    }
}
