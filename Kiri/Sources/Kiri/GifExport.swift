import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Kiri --gif out.gif` renders Hoot cycling through every mood, for the README / social posts.
enum GifExport {
    @MainActor
    static func render(to url: URL) {
        let script: [(Mood, String, Double)] = [
            (.idle, "Hi, I'm Hoot 🦉", 2.0), (.thinking, "Thinking…", 1.6), (.working, "Running your tests…", 1.8),
            (.sad, "Tests failed — want me to fix it?", 2.0), (.happy, "Fixed! All tests pass 🎉", 2.2), (.sleepy, "It's late… 😴", 1.8),
        ]
        let fps = 12.0
        var frames: [CGImage] = []
        var t = 0.0
        for (mood, caption, seconds) in script {
            for _ in 0..<Int(seconds * fps) {
                t += 1 / fps
                let view = ZStack(alignment: .bottom) {
                    LinearGradient(colors: [Color(red: 0.12, green: 0.10, blue: 0.22), Color(red: 0.05, green: 0.05, blue: 0.09)],
                                   startPoint: .top, endPoint: .bottom)
                    OwlFrame(mood: mood, t: t).offset(y: -26)
                    Text(caption)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .padding(.bottom, 12)
                }
                .frame(width: 280, height: 330)
                let r = ImageRenderer(content: view)
                r.scale = 1.5
                if let cg = r.cgImage { frames.append(cg) }
            }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, frameProps) }
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path) (\(frames.count) frames)")
    }
}
