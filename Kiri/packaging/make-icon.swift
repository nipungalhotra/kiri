// Renders the Kiri app icon (owl on a soft purple rounded square) into an .iconset.
import AppKit
let owlPath = CommandLine.arguments[1], outDir = CommandLine.arguments[2]
let owl = NSImage(contentsOfFile: owlPath)!
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09, r = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.38, alpha: 1),
                        NSColor(calibratedRed: 0.07, green: 0.06, blue: 0.16, alpha: 1)])!.draw(in: shape, angle: -90)
    // soft glow behind the owl
    NSGradient(colors: [NSColor(calibratedRed: 0.62, green: 0.42, blue: 1, alpha: 0.55), .clear])!
        .draw(in: NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.12, dy: r.width * 0.12)), relativeCenterPosition: .zero)
    let h = r.height * 0.80, w = h * owl.size.width / owl.size.height
    owl.draw(in: NSRect(x: r.midX - w / 2, y: r.minY + r.height * 0.07, width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(base)x\(base)@2x.png"))
}
print("iconset ready")
