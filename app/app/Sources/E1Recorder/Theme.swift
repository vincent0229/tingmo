import AppKit
import SwiftUI

// MARK: - Tokens (design spec: 规范 1–3 on the design canvas)

extension Color {
    /// A color with separate light/dark values.
    static func dyn(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
    static let e1Blue = dyn(0x0088FF, 0x0091FF)
    static let e1BluePressed = dyn(0x0071D6, 0x0077E0)
    static let e1Green = dyn(0x34C759, 0x30D158)
    static let e1Red = dyn(0xFF383C, 0xFF4245)
    static let e1Group = dyn(0xF8F8F8, 0xFFFFFF, darkAlpha: 0.05)
    static let e1Content = dyn(0xFFFFFF, 0x1E1E1E)
    static let t1 = Color.primary.opacity(0.85)
    static let t2 = Color.primary.opacity(0.5)
    static let t3 = Color.primary.opacity(0.25)
    static let e1Sep = Color.primary.opacity(0.1)
}

extension Font {
    static let e1Body = Font.system(size: 13)
    static let e1Sub = Font.system(size: 11)
    static let e1Head = Font.system(size: 13, weight: .bold)
    static let e1Title = Font.system(size: 15, weight: .semibold)
}

// MARK: - Layout pieces

struct SectionHeader: View {
    let text: String
    var body: some View {
        Text(text).font(.e1Head).foregroundStyle(Color.t1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2).padding(.top, 20).padding(.bottom, 8)
    }
}

/// Rounded group (#F8F8F8, radius 12) holding rows separated by hairlines.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color.e1Group, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct Hairline: View {
    var leading: CGFloat = 12
    var body: some View {
        Rectangle().fill(Color.e1Sep).frame(height: 1).padding(.leading, leading).padding(.trailing, 12)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var sub: String? = nil
    var dimmed = false
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.e1Body).foregroundStyle(dimmed ? Color.t3 : Color.t1)
                if let sub { Text(sub).font(.e1Sub).foregroundStyle(dimmed ? Color.t3 : Color.t2) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: sub == nil ? 38 : 46)
    }
}

/// Secondary value shown at the right of a row.
struct Value: View {
    let text: String
    var body: some View { Text(text).font(.e1Body).foregroundStyle(Color.t2).lineLimit(1).truncationMode(.middle) }
}

struct Note: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text).font(.e1Sub).foregroundStyle(Color.t2).lineSpacing(2).tint(Color.e1Blue)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 2).padding(.top, 8)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Dot: View {
    enum Kind { case ok, bad, off }
    let kind: Kind
    var size: CGFloat = 8
    var body: some View {
        switch kind {
        case .ok: Circle().fill(Color.e1Green).frame(width: size, height: size)
        case .bad: Circle().fill(Color.e1Red).frame(width: size, height: size)
        case .off: Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: size > 6 ? 1.5 : 1.2).frame(width: size, height: size)
        }
    }
}

struct Spinner: View {
    var body: some View { ProgressView().controlSize(.mini).frame(width: 12, height: 12) }
}

// MARK: - Buttons (控件状态复查表)

/// Grey pill: default 6% · hover 9% · pressed 14% · disabled 3% with 25% text.
struct PillButtonStyle: ButtonStyle {
    var height: CGFloat = 22
    var minWidth: CGFloat = 0
    var radius: CGFloat = 6
    func makeBody(configuration: Configuration) -> some View {
        StyledBody(configuration: configuration, height: height, minWidth: minWidth, radius: radius)
    }
    struct StyledBody: View {
        let configuration: Configuration
        let height: CGFloat, minWidth: CGFloat, radius: CGFloat
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false
        var body: some View {
            let fill = !enabled ? 0.03 : configuration.isPressed ? 0.14 : hover ? 0.09 : 0.06
            configuration.label
                .font(.e1Body).foregroundStyle(enabled ? Color.t1 : Color.t3)
                .padding(.horizontal, minWidth > 0 ? 12 : 10)
                .frame(minWidth: minWidth, minHeight: height, maxHeight: height)
                .background(Color.primary.opacity(fill), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .onHover { hover = $0 }
        }
    }
}

/// Blue default button (存储): pressed darker; disabled or window in background turns grey.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    struct StyledBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlActiveState) private var active
        var body: some View {
            let inactive = active == .inactive
            let bg: Color = !enabled ? Color.primary.opacity(0.04)
                : inactive ? Color.primary.opacity(0.06)
                : configuration.isPressed ? .e1BluePressed : .e1Blue
            configuration.label
                .font(.e1Body).foregroundStyle(!enabled ? Color.t3 : inactive ? Color.t1 : .white)
                .padding(.horizontal, 12).frame(minWidth: 72, minHeight: 24, maxHeight: 24)
                .background(bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
    }
}

/// Blue text link: default #0088FF · hover #006AD1 · pressed #0058AD.
struct LinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledBody(configuration: configuration) }
    struct StyledBody: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label.font(.e1Sub)
                .foregroundStyle(configuration.isPressed ? Color.dyn(0x0058AD, 0x4DA8FF) : hover ? Color.dyn(0x006AD1, 0x3FA0FF) : Color.e1Blue)
                .onHover { hover = $0 }
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static var pill: PillButtonStyle { PillButtonStyle() }
    static var sheetPill: PillButtonStyle { PillButtonStyle(height: 24, minWidth: 72, radius: 7) }
}
extension ButtonStyle where Self == PrimaryButtonStyle { static var primary: PrimaryButtonStyle { PrimaryButtonStyle() } }
extension ButtonStyle where Self == LinkStyle { static var e1Link: LinkStyle { LinkStyle() } }

/// Pop-up value: grey text + round up/down chevron; opens a native menu.
struct PopupValue<MenuContent: View>: View {
    let value: String
    @ViewBuilder var menu: MenuContent
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    var body: some View {
        Menu { menu } label: {
            HStack(spacing: 8) {
                Text(value).font(.e1Body).foregroundStyle(!enabled ? Color.t3 : hover ? Color.t1 : Color.t2)
                ZStack {
                    Circle().fill(Color.primary.opacity(!enabled ? 0.03 : hover ? 0.1 : 0.05))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(enabled ? Color.primary.opacity(hover ? 0.75 : 0.6) : Color.t3)
                }
                .frame(width: 20, height: 20)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hover = $0 }
    }
}

// MARK: - Icons

/// Apple-style continuous-corner tile (same outline as the sidebar icons on the canvas).
struct Squircle: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        var p = Path()
        p.move(to: CGPoint(x: x + w * 0.5, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + h * 0.5), control1: CGPoint(x: x + w * 0.865, y: y), control2: CGPoint(x: x + w, y: y + h * 0.135))
        p.addCurve(to: CGPoint(x: x + w * 0.5, y: y + h), control1: CGPoint(x: x + w, y: y + h * 0.865), control2: CGPoint(x: x + w * 0.865, y: y + h))
        p.addCurve(to: CGPoint(x: x, y: y + h * 0.5), control1: CGPoint(x: x + w * 0.135, y: y + h), control2: CGPoint(x: x, y: y + h * 0.865))
        p.addCurve(to: CGPoint(x: x + w * 0.5, y: y), control1: CGPoint(x: x, y: y + h * 0.135), control2: CGPoint(x: x + w * 0.135, y: y))
        p.closeSubpath()
        return p
    }
}

/// Sidebar icons (方案 B): gradient squircle, dark hairline, soft shadow, detailed white line glyph.
struct SidebarIcon: View {
    enum Glyph { case platform, storage, device, general, about }
    let glyph: Glyph
    var size: CGFloat = 20

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 20
            ctx.scaleBy(x: s, y: s)
            // System Settings tiles: continuous corners at ~23% of the side, one system colour per item.
            let tile = RoundedRectangle(cornerRadius: 4.6, style: .continuous).path(in: CGRect(x: 0, y: 0, width: 20, height: 20))
            let (top, bottom): (UInt32, UInt32) = switch glyph {
            case .platform: (0x3AA0FF, 0x0A6CF5)   // blue
            case .storage: (0xFFB938, 0xFF8C00)    // orange
            case .device: (0x46D26F, 0x24B04F)     // green
            case .general: (0xAEAEB3, 0x8B8B90)    // grey
            case .about: (0x3A3A3C, 0x0C0C0D)      // graphite
            }
            ctx.fill(tile, with: .linearGradient(Gradient(colors: [rgb(top), rgb(bottom)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: 20)))
            Self.draw(glyph, in: &ctx)
        }
        .frame(width: size, height: size)
        // no outline: like System Settings, the tile sits on a soft drop shadow only
        .shadow(color: .black.opacity(0.18), radius: 1.2 * size / 20, x: 0, y: 0.6 * size / 20)
    }

    private func rgb(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func draw(_ g: Glyph, in ctx: inout GraphicsContext) {
        let white = GraphicsContext.Shading.color(.white)
        func line(_ w: CGFloat) -> StrokeStyle { StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        switch g {
        case .platform:
            var p = Path()
            p.move(to: CGPoint(x: 5.4, y: 5.3)); p.addLine(to: CGPoint(x: 14.6, y: 5.3))
            p.addArc(tangent1End: CGPoint(x: 16.3, y: 5.3), tangent2End: CGPoint(x: 16.3, y: 12), radius: 1.7)
            p.addLine(to: CGPoint(x: 16.3, y: 12))
            p.addArc(tangent1End: CGPoint(x: 16.3, y: 13.7), tangent2End: CGPoint(x: 5, y: 13.7), radius: 1.7)
            p.addLine(to: CGPoint(x: 10.3, y: 13.7)); p.addLine(to: CGPoint(x: 7.4, y: 16)); p.addLine(to: CGPoint(x: 7.4, y: 13.7))
            p.addLine(to: CGPoint(x: 5.4, y: 13.7))
            p.addArc(tangent1End: CGPoint(x: 3.7, y: 13.7), tangent2End: CGPoint(x: 3.7, y: 5), radius: 1.7)
            p.addLine(to: CGPoint(x: 3.7, y: 7))
            p.addArc(tangent1End: CGPoint(x: 3.7, y: 5.3), tangent2End: CGPoint(x: 16, y: 5.3), radius: 1.7)
            p.closeSubpath()
            ctx.stroke(p, with: white, style: line(1.3))
            for (x, y, h) in [(6.6, 8.6, 1.8), (8.4, 7.6, 3.8), (10.2, 8.1, 2.8), (12.0, 8.8, 1.4)] as [(CGFloat, CGFloat, CGFloat)] {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y, width: 1.1, height: h), cornerRadius: 0.55), with: white)
            }
        case .storage:
            var p = Path()
            p.move(to: CGPoint(x: 6.6, y: 3.6)); p.addLine(to: CGPoint(x: 11.3, y: 3.6)); p.addLine(to: CGPoint(x: 14.4, y: 6.7))
            p.addLine(to: CGPoint(x: 14.4, y: 15.7))
            p.addArc(tangent1End: CGPoint(x: 14.4, y: 16.8), tangent2End: CGPoint(x: 6, y: 16.8), radius: 1.1)
            p.addLine(to: CGPoint(x: 6.6, y: 16.8))
            p.addArc(tangent1End: CGPoint(x: 5.5, y: 16.8), tangent2End: CGPoint(x: 5.5, y: 4), radius: 1.1)
            p.addLine(to: CGPoint(x: 5.5, y: 4.7))
            p.addArc(tangent1End: CGPoint(x: 5.5, y: 3.6), tangent2End: CGPoint(x: 10, y: 3.6), radius: 1.1)
            p.closeSubpath()
            ctx.stroke(p, with: white, style: line(1.3))
            var f = Path(); f.move(to: CGPoint(x: 11.2, y: 3.7)); f.addLine(to: CGPoint(x: 11.2, y: 6.7)); f.addLine(to: CGPoint(x: 14.2, y: 6.7))
            ctx.stroke(f, with: white, style: line(1.2))
            var l = Path()
            l.move(to: CGPoint(x: 7.6, y: 10)); l.addLine(to: CGPoint(x: 12.4, y: 10))
            l.move(to: CGPoint(x: 7.6, y: 12.2)); l.addLine(to: CGPoint(x: 12.4, y: 12.2))
            l.move(to: CGPoint(x: 7.6, y: 14.4)); l.addLine(to: CGPoint(x: 10.6, y: 14.4))
            ctx.stroke(l, with: white, style: line(1.1))
        case .device:
            ctx.stroke(Path(roundedRect: CGRect(x: 7, y: 2.6, width: 6, height: 14.8), cornerRadius: 1.9), with: white, style: line(1.25))
            for (x, y) in [(8.95, 4.7), (11.05, 4.7), (8.75, 13.2), (10.0, 13.2), (11.25, 13.2)] as [(CGFloat, CGFloat)] {
                ctx.fill(circle(x, y, 0.6), with: white)
            }
            ctx.fill(Path(roundedRect: CGRect(x: 8.4, y: 6.5, width: 3.2, height: 3.5), cornerRadius: 0.6), with: white)
        case .general:
            ctx.stroke(circle(10, 10, 6.6), with: white, style: StrokeStyle(lineWidth: 1.3, dash: [0.95, 0.78]))
            ctx.stroke(circle(10, 10, 5.5), with: white, style: line(1.1))
            var sp = Path()
            sp.move(to: CGPoint(x: 10, y: 10)); sp.addLine(to: CGPoint(x: 10, y: 5.2))
            sp.move(to: CGPoint(x: 10, y: 10)); sp.addLine(to: CGPoint(x: 5.9, y: 12.4))
            sp.move(to: CGPoint(x: 10, y: 10)); sp.addLine(to: CGPoint(x: 14.1, y: 12.4))
            ctx.stroke(sp, with: white, style: line(1.1))
            ctx.fill(circle(10, 10, 1.2), with: white)
        case .about:
            ctx.stroke(circle(10, 10, 6.2), with: white, style: line(1.3))
            ctx.fill(circle(10, 7, 0.9), with: white)
            var i = Path(); i.move(to: CGPoint(x: 10, y: 9.4)); i.addLine(to: CGPoint(x: 10, y: 13.8))
            ctx.stroke(i, with: white, style: line(1.6))
        }
    }
}

/// The E1 pen silhouette used in the panel's device circle (24-unit grid).
struct PenGlyph: View {
    var body_: Color = .white
    var detail: Color = .e1Blue
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 24
            ctx.scaleBy(x: s, y: s)
            ctx.fill(Path(roundedRect: CGRect(x: 7.5, y: 1.5, width: 9, height: 21), cornerRadius: 2.6), with: .color(body_))
            for (x, y, r) in [(10.4, 4.2, 0.95), (13.6, 4.2, 0.95), (10.0, 15.4, 0.85), (12.0, 15.4, 0.85), (14.0, 15.4, 0.85)] as [(CGFloat, CGFloat, CGFloat)] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(detail))
            }
            ctx.fill(Path(roundedRect: CGRect(x: 9.3, y: 6.6, width: 5.4, height: 5.6), cornerRadius: 0.9), with: .color(detail))
        }
    }
}

/// Monochrome template images for the menu bar (dark menu bars invert them automatically). Three styles:
/// "ring" 声纹录音键 (same as the app icon), "bars" 声波, "pen" 录音笔.
enum MenuBarIcon {
    static let styles: [(id: String, name: String)] = [("ring", "声纹录音键"), ("bars", "声波"), ("pen", "录音笔")]

    private static let ringPattern: [CGFloat] = [1.2, 2.0, 2.8, 1.7, 1.0, 1.5, 2.5, 3.0, 2.0, 1.2, 1.7, 2.3, 1.3, 2.1, 2.7, 1.6, 1.0, 1.6]
    private static let barFrames: [[CGFloat]] = [[4, 9, 13, 7, 3], [9, 4, 7, 13, 6], [13, 7, 4, 9, 11], [7, 13, 9, 4, 7]]
    private static var cache: [String: NSImage] = [:]

    static func idle(_ style: String) -> NSImage { image(style, frame: 0, dot: false) }
    static func attention(_ style: String) -> NSImage { image(style, frame: 0, dot: true) }
    static func frame(_ style: String, _ i: Int) -> NSImage { image(style, frame: i % 6, dot: false) }

    private static func image(_ style: String, frame: Int, dot: Bool) -> NSImage {
        let key = "\(style)-\(frame)-\(dot)"
        if let i = cache[key] { return i }
        let img = NSImage(size: NSSize(width: dot ? 19 : 16, height: 16), flipped: true) { _ in
            NSColor.black.set()
            switch style {
            case "bars":
                let h = barFrames[frame % barFrames.count]
                for (i, x) in ([1.2, 4.4, 7.6, 10.8, 14] as [CGFloat]).enumerated() {
                    NSBezierPath(roundedRect: NSRect(x: x, y: 8 - h[i] / 2, width: 1.8, height: h[i]), xRadius: 0.9, yRadius: 0.9).fill()
                }
            case "pen":
                let body = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 0.8, width: 6.8, height: 14.4), xRadius: 2.2, yRadius: 2.2)
                body.lineWidth = 1.2; body.stroke()
                NSBezierPath(roundedRect: NSRect(x: 6.4, y: 3.2, width: 3.2, height: 3.4), xRadius: 0.6, yRadius: 0.6).fill()
                // record dot blinks while working
                let r: CGFloat = frame % 2 == 0 ? 1.5 : 1.0
                NSBezierPath(ovalIn: NSRect(x: 8 - r, y: 10.6 - r, width: 2 * r, height: 2 * r)).fill()
            default:
                let c = NSPoint(x: 8, y: 8)
                NSBezierPath(ovalIn: NSRect(x: c.x - 2.7, y: c.y - 2.7, width: 5.4, height: 5.4)).fill()
                for i in 0..<18 {
                    let a = CGFloat(i) * .pi / 9 - .pi / 2
                    let l = ringPattern[(i + frame * 3) % ringPattern.count]
                    let r0: CGFloat = 4.4
                    let bar = NSBezierPath()
                    bar.move(to: NSPoint(x: c.x + r0 * cos(a), y: c.y + r0 * sin(a)))
                    bar.line(to: NSPoint(x: c.x + (r0 + l) * cos(a), y: c.y + (r0 + l) * sin(a)))
                    bar.lineWidth = 1.0
                    bar.lineCapStyle = .round
                    bar.stroke()
                }
            }
            if dot { NSBezierPath(ovalIn: NSRect(x: 14.4, y: 0.4, width: 4.4, height: 4.4)).fill() }
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}

// MARK: - Helpers

func formatBytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

@MainActor func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

/// "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/A/B" → "Obsidian › A › B".
func prettyPath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if let r = path.range(of: "iCloud~md~obsidian/Documents/") {
        return (["Obsidian"] + path[r.upperBound...].split(separator: "/").map(String.init)).joined(separator: " › ")
    }
    if path.hasPrefix(home) {
        let names = ["Music": "音乐", "Documents": "文稿", "Desktop": "桌面", "Downloads": "下载"]
        let parts = path.dropFirst(home.count).split(separator: "/").map { names[String($0)] ?? String($0) }
        return parts.isEmpty ? "个人文件夹" : parts.joined(separator: " › ")
    }
    return path
}

@MainActor
func choose(folder: Bool) -> String? {
    NSApp.activate(ignoringOtherApps: true)
    let p = NSOpenPanel()
    p.canChooseDirectories = folder
    p.canChooseFiles = !folder
    p.canCreateDirectories = folder
    if !folder { p.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText, .plainText] }
    return p.runModal() == .OK ? p.url?.path : nil
}
