import AppKit
import SwiftUI

/// Screen tutor: a glowing ring and arrow that points at a spot on your screen for a few seconds
/// ("click here"). Click-through, so it never gets in your way.
@MainActor
enum Pointer {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    /// `x`, `y` are pixels in the last screenshot (or 0...1 fractions), measured from the top-left.
    static func show(x: Double, y: Double, label: String) -> String {
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == CGMainDisplayID() }
            ?? NSScreen.main
        guard let screen else { return "I couldn't find your screen." }
        let size = ScreenHelp.lastSize ?? CGSize(width: 1, height: 1)
        let fx = x > 1 ? x / size.width : x
        let fy = y > 1 ? y / size.height : y
        guard (0...1).contains(fx), (0...1).contains(fy) else { return "I wasn't sure where to point 🤔" }

        hideWork?.cancel()
        panel?.orderOut(nil)
        let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .screenSaver
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let point = CGPoint(x: fx * screen.frame.width, y: fy * screen.frame.height)
        p.contentView = NSHostingView(rootView: PointerView(point: point, label: label))
        p.setFrame(screen.frame, display: true)
        p.orderFrontRegardless()
        panel = p
        let work = DispatchWorkItem { panel?.orderOut(nil); panel = nil }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: work)
        Log.write("pointer shown at \(Int(fx * 100))%,\(Int(fy * 100))%")
        return "Look where I'm pointing 👉 \(label)"
    }
}

struct PointerView: View {
    let point: CGPoint
    let label: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let pulse = 1 + 0.18 * sin(t * 5)
            let bob = 8 * sin(t * 4)
            // arrow comes from the side with more room
            let fromLeft = point.x > 260
            ZStack {
                Color.clear
                Circle().stroke(Color(red: 0.72, green: 0.45, blue: 1), lineWidth: 5)
                    .frame(width: 54 * pulse, height: 54 * pulse)
                    .shadow(color: Color(red: 0.72, green: 0.45, blue: 1).opacity(0.8), radius: 10)
                    .position(point)
                Circle().fill(Color(red: 0.72, green: 0.45, blue: 1).opacity(0.18)).frame(width: 54, height: 54).position(point)
                HStack(spacing: 6) {
                    if !fromLeft { Image(systemName: "arrow.left").font(.system(size: 30, weight: .black)) }
                    Text("🦉 " + label).font(.system(size: 15, weight: .bold, design: .rounded))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color(red: 0.25, green: 0.12, blue: 0.4)))
                    if fromLeft { Image(systemName: "arrow.right").font(.system(size: 30, weight: .black)) }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 6)
                .fixedSize()
                .position(x: point.x + (fromLeft ? -150 : 150) + (fromLeft ? -bob : bob), y: point.y)
            }
        }
        .ignoresSafeArea()
    }
}
