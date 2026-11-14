import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Identifiable {
    case platform, storage, device, general, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .platform: "转写"
        case .storage: "纪要"
        case .device: "设备"
        case .general: "通用"
        case .about: "关于"
        }
    }
    var glyph: SidebarIcon.Glyph {
        switch self {
        case .platform: .platform
        case .storage: .storage
        case .device: .device
        case .general: .general
        case .about: .about
        }
    }
}

/// Preferences window: always-expanded sidebar, back/forward in the toolbar, one native grouped form per section,
/// so text, rows, buttons, pop-ups and switches are drawn by the system exactly as in System Settings.
/// Lets other parts of the app (e.g. the menu bar panel) open Preferences at a given page.
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var request: SettingsSection?
    var requestSub: String?

    /// Preferences › 转写 › 服务选项 (cloud services: transcription, WiFi storage, budget).
    @MainActor static func openServiceOptions() {
        shared.requestSub = "platform-settings"
        shared.request = .platform
    }
}

private struct OpenSubpageKey: EnvironmentKey { static let defaultValue: (String) -> Void = { _ in } }

extension EnvironmentValues {
    /// Pushes a sub-page (a row with a chevron); the toolbar's back button returns.
    var openSubpage: (String) -> Void {
        get { self[OpenSubpageKey.self] }
        set { self[OpenSubpageKey.self] = newValue }
    }
}

struct SettingsView: View {
    @EnvironmentObject var s: AppSettings
    @EnvironmentObject var pipeline: Pipeline
    @ObservedObject private var nav = SettingsNav.shared
    @State private var selection: SettingsSection? =
        SettingsSection(rawValue: UserDefaults.standard.string(forKey: "previewSection") ?? "") ?? .platform
    @State private var sub: String? = UserDefaults.standard.string(forKey: "previewSub")
    struct Route: Equatable { var section: SettingsSection; var sub: String? }
    @State private var history: [Route] = []
    @State private var index = -1
    @State private var jumping = false

    private static let subTitles = ["platform-settings": "服务选项"]

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach([SettingsSection.platform, .storage, .device, .general]) { row($0) }
                }
                Section {
                    row(.about)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 32)
            .frame(minWidth: 220)
            .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 220)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let section = selection ?? .platform
            Group {
                if let sub { subpage(sub) } else { page(section) }
            }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .environment(\.openSubpage, { open($0) })
            .background(Color.e1Content.ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 540, ideal: 540)
            .navigationTitle(sub.flatMap { Self.subTitles[$0] } ?? section.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button(action: back) { Image(systemName: "chevron.left") }.disabled(index <= 0).help("后退")
                    Button(action: forward) { Image(systemName: "chevron.right") }.disabled(index >= history.count - 1).help("前进")
                }
            }
        }
        .frame(width: 760, height: UIPreview.enabled && UserDefaults.standard.double(forKey: "previewHeight") > 0
               ? UserDefaults.standard.double(forKey: "previewHeight") : 620)   // screenshots of a whole page
        .onAppear { if history.isEmpty, let s = selection { history = [Route(section: s, sub: sub)]; index = 0 } }
        .onChange(of: selection) { _, new in
            guard let new else { return }
            if jumping { jumping = false; return }
            sub = nil
            push(Route(section: new, sub: nil))
        }
        .onReceive(nav.$request) { r in
            guard let r else { return }
            let target = nav.requestSub
            nav.request = nil; nav.requestSub = nil
            if selection != r { jumping = true; selection = r }
            sub = target
            push(Route(section: r, sub: target))
        }
    }

    private func push(_ r: Route) {
        guard history.last != r || index != history.count - 1 else { return }
        history = Array(history.prefix(index + 1)) + [r]
        index = history.count - 1
    }

    private func open(_ page: String) {
        sub = page
        push(Route(section: selection ?? .platform, sub: page))
    }

    private func go(_ r: Route) {
        if selection != r.section { jumping = true; selection = r.section }
        sub = r.sub
    }

    @ViewBuilder private func subpage(_ id: String) -> some View {
        switch id {
        case "platform-settings": PlatformSettingsPage()
        default: page(selection ?? .platform)
        }
    }

    private func row(_ s: SettingsSection) -> some View {
        HStack(spacing: 8) {
            SidebarIcon(glyph: s.glyph)
            Text(s.title)
        }
        .frame(height: 24).tag(s)
    }

    @ViewBuilder private func page(_ s: SettingsSection) -> some View {
        switch s {
        case .platform: PlatformPage()
        case .storage: StoragePage()
        case .device: DevicePage()
        case .general: GeneralPage()
        case .about: AboutPage()
        }
    }

    private func back() {
        guard index > 0 else { return }
        index -= 1; go(history[index])
    }

    private func forward() {
        guard index < history.count - 1 else { return }
        index += 1; go(history[index])
    }
}

/// Grey trailing value next to a row's button.
struct Trailing: View {
    let text: String
    var body: some View { Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
}

struct EditSheet: View {
    let title: String
    let help: String
    let placeholder: String
    var secure = false
    let initial: String
    let validate: (String) -> String?
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let error = trimmed.isEmpty ? nil : validate(trimmed)
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(commit)
            Text(error ?? " ").font(.callout).foregroundStyle(.red)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("存储", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || error != nil || trimmed == initial)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { text = secure ? "" : initial }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, validate(t) == nil, t != initial else { return }
        save(t)
        dismiss()
    }
}
