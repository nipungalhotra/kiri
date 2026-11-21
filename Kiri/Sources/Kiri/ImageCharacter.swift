import ImageIO
import AppKit
import SwiftUI

/// A character drawn from PNG art: one image per mood (`idle.png`, `thinking.png`, `working.png`,
/// `happy.png`, `sad.png`, `sleepy.png`) in a folder named after the character.
///
/// Folders are searched in this order, so you can drop in better art without rebuilding:
///   1. ~/Library/Application Support/Kiri/characters/<name>/
///   2. Kiri.app/Contents/Resources/characters/<name>/
///   3. the project's `characters/<name>/` (when run with `swift run`)
enum ImageArt {
    private static var cache: [String: NSImage] = [:]

    static var searchRoots: [URL] {
        var roots: [URL] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(support.appendingPathComponent("Kiri/characters"))
        }
        if let res = Bundle.main.resourceURL { roots.append(res.appendingPathComponent("characters")) }
        roots.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("characters"))
        return roots
    }

    static func image(_ character: String, _ mood: Mood) -> NSImage? {
        image(character, names: [mood.rawValue, Mood.idle.rawValue])
    }

    /// Decode the PNG once, up front. A plain `NSImage(contentsOf:)` decodes lazily and was being
    /// re-decoded on every animation frame, which burned CPU.
    private static func decoded(_ url: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let png = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        // Copy into a plain in-memory bitmap so nothing is left that can be lazily re-decoded.
        let w = png.width, h = png.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(png, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let bitmap = ctx.makeImage() else { return nil }
        return NSImage(cgImage: bitmap, size: NSSize(width: w, height: h))
    }

    /// Names already looked for and not found, so misses don't hit the disk every frame.
    private static var missing: Set<String> = []

    static func image(_ character: String, named name: String) -> NSImage? {
        image(character, names: [name])
    }

    private static func image(_ character: String, names: [String]) -> NSImage? {
        for name in names {
            let key = "\(character)/\(name)"
            if let hit = cache[key] { return hit }
            if missing.contains(key) { continue }
            for root in searchRoots {
                let url = root.appendingPathComponent("\(character)/\(name).png")
                if let img = decoded(url) {
                    cache[key] = img
                    return img
                }
            }
            missing.insert(key)
        }
        return nil
    }
}

struct ImageCharacterFrame: View {
    let name: String
    let accent: Color
    let mood: Mood
    let t: Double
    /// True when the art has no real sleeping face, so we dim the idle-ish one instead.
    var fakeSleep = false

    var body: some View {
        let bob = mood == .happy ? -abs(sin(t * 4.5)) * 10 : sin(t * (mood == .sleepy ? 1.1 : 2.0)) * 3.5
        let pulse = 0.55 + 0.45 * sin(t * (mood == .working ? 5 : 2))
        ZStack {
            Ellipse().fill(accent.opacity(0.45)).frame(width: 74, height: 12).blur(radius: 7).offset(y: 62)

            ZStack {
                Circle().fill(accent.opacity(0.35)).frame(width: 118, height: 118).blur(radius: 14).opacity(pulse)
                Group {
                    if let img = ImageArt.image(name, mood) {
                        Image(nsImage: img).resizable().interpolation(.high).scaledToFill()
                    } else {
                        ZStack {
                            Color.black
                            Text("missing\n\(name)/\(mood.rawValue).png").font(.caption2).foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .frame(width: 104, height: 104)
                .clipShape(Circle())
                .saturation(fakeSleep && mood == .sleepy ? 0.5 : 1)
                .brightness(fakeSleep && mood == .sleepy ? -0.18 : 0)
                .id(mood)
                .transition(.opacity)
                Circle()
                    .stroke(AngularGradient(colors: [accent, accent.opacity(0.2), .white.opacity(0.8), accent.opacity(0.2), accent],
                                            center: .center, angle: .degrees(t * (mood == .working ? 120 : 30))),
                            lineWidth: 3)
                    .frame(width: 106, height: 106)
                    .shadow(color: accent, radius: 6 * pulse)
            }
            .animation(.easeInOut(duration: 0.35), value: mood)
            .offset(y: bob)

            extras.offset(y: bob)
        }
        .frame(width: 160, height: 150)
    }

    @ViewBuilder private var extras: some View {
        switch mood {
        case .thinking:
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(accent).frame(width: 6, height: 6).offset(y: sin(t * 6 - Double(i)) * 3)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 6)
            .background(Capsule().fill(Color.black.opacity(0.75)))
            .overlay(Capsule().stroke(accent.opacity(0.6), lineWidth: 1))
            .offset(x: 56, y: -48)
        case .working:
            Text("</>")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(accent)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.75)))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(accent.opacity(0.6), lineWidth: 1))
                .offset(x: 56, y: -46 + sin(t * 5) * 2)
        case .happy:
            ForEach(0..<5, id: \.self) { i in
                let a = Double(i) / 5 * 2 * .pi + t * 1.3
                Text("✦").font(.system(size: 10 + CGFloat(i % 2) * 5))
                    .foregroundStyle(i % 2 == 0 ? accent : .yellow)
                    .offset(x: cos(a) * 70, y: sin(a) * 52)
                    .opacity(0.6 + 0.4 * sin(t * 4 + Double(i)))
            }
        case .sleepy:
            Zzz(t: t, color: accent, x: 46, y: -44)
        case .sad:
            Text("!").font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(Color.yellow)
                .offset(x: 52, y: -46 + sin(t * 8) * 2)
        case .idle:
            EmptyView()
        }
    }
}
