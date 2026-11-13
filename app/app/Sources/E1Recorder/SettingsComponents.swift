import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A section title with an ⓘ that shows its explanation on click, instead of a paragraph under the section.
struct SectionTitle: View {
    let title: String
    let info: String
    init(_ title: String, info: String) { self.title = title; self.info = info }
    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            InfoButton(text: info)
        }
    }
}

struct InfoButton: View {
    let text: String
    @State private var shown = false
    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 12)).foregroundStyle(Color.t2)
        }
        .buttonStyle(.plain)
        .help("说明").accessibilityLabel("说明")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Text(.init(text)).font(.callout).foregroundStyle(Color.t1)
                .frame(width: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// A large-radius pill button (same shape as the connection pill), for the page's main actions.
struct CapsuleActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    private struct StyledBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color.t1)
                .padding(.horizontal, 14).frame(height: 30)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hover ? 0.1 : 0.06)))
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .onHover { hover = $0 }
        }
    }
}

/// A row with a chevron that opens a sub-page.
struct NavRow: View {
    let title: String
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FolderRow: View {
    let title: String
    @Binding var path: String
    var body: some View {
        LabeledContent {
            Button("更改…") { if let p = choose(folder: true) { path = p } }
        } label: {
            Label {
                Text(title)
                Text(prettyPath(path)).help(path)
            } icon: {
                Image(nsImage: FileManager.default.fileExists(atPath: path) ? NSWorkspace.shared.icon(forFile: path) : NSWorkspace.shared.icon(for: .folder))
                    .resizable().frame(width: 20, height: 20)
            }
        }
    }
}

struct InfoTile: View {
    var icon: AnyView? = nil
    var symbol: String? = nil
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                if let icon { icon } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.t2)
                }
            }
            .frame(height: 16)
            Text(value).font(.e1Title).foregroundStyle(Color.t1).lineLimit(1)
            Text(label).font(.e1Sub).foregroundStyle(Color.t2).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct BatteryIcon: View {
    let level: Int?
    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill((level ?? 0) <= 20 ? Color.e1Red : Color.e1Green)
                    .frame(width: max(0, 16 * CGFloat(level ?? 0) / 100), height: 7).padding(.leading, 2)
            }
            .frame(width: 21, height: 11)
            RoundedRectangle(cornerRadius: 1).fill(Color.primary.opacity(0.35)).frame(width: 1.8, height: 4)
        }
    }
}
