// Generates the two layers of Resources/AppIcon.icon (方案 C · 声纹录音键): a ring of green sound bars and a
// red record button, as full-bleed 1024 px PNGs. The background gradient, mask and shadows live in icon.json;
// build.sh compiles the .icon with actool. Usage: swift make_icon.swift Resources/AppIcon.icon/Assets
let lengths: [CGFloat] = Array(repeating: [6, 9, 12, 8, 5, 7, 11, 13, 9, 6, 8, 10] as [CGFloat], count: 3).flatMap { $0 }
func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: a) }
func canvas(_ body: (CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.translateBy(x: 0, y: 1024); ctx.cgContext.scaleBy(x: 1, y: -1)
    body(10.24)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
let ring = canvas { u in
    for (i, l) in lengths.enumerated() {
        let a = (CGFloat(i) * 10 - 90) * .pi / 180, r0: CGFloat = 21.5
        let y0 = 50 + r0 * sin(a), y1 = 50 + (r0 + l) * sin(a)
        let t = ((y0 + y1) / 2 - 18) / 66
        let c = rgb(0x4FDB7E).blended(withFraction: max(0, min(1, t)), of: rgb(0x1EA54E))!
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: (50 + r0 * cos(a)) * u, y: y0 * u))
        bar.line(to: NSPoint(x: (50 + (r0 + l) * cos(a)) * u, y: y1 * u))
        bar.lineWidth = 2.7 * u; bar.lineCapStyle = .round
        c.setStroke(); bar.stroke()
    }
}
let dot = canvas { u in
    let r: CGFloat = 15
    let path = NSBezierPath(ovalIn: NSRect(x: (50 - r) * u, y: (50 - r) * u, width: 2 * r * u, height: 2 * r * u))
    NSGradient(starting: rgb(0xFF6B62), ending: rgb(0xE2342B))!.draw(in: path, angle: 90)
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try! ring.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("ring.png"))
try! dot.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("dot.png"))
