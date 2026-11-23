import AppKit
import SwiftUI

/// Hoot — the purple owl. Art lives in `characters/owl/`:
///   body.png    full body (transparent)
///   working.png headphones pose (upper body)
///   happy.png   celebrating pose (upper body)
enum OwlArt {
    static let accent = Color(red: 0.62, green: 0.42, blue: 1.0)
    static let fur = [Color(red: 0.50, green: 0.25, blue: 0.80), Color(red: 0.36, green: 0.15, blue: 0.62)]

    /// Eye whites inside body.png, as fractions of the image (center x, center y, width, height).
    static let leftEye = CGRect(x: 0.347, y: 0.300, width: 0.335, height: 0.262)
    static let rightEye = CGRect(x: 0.779, y: 0.300, width: 0.255, height: 0.258)

    static func pose(for mood: Mood) -> String {
        switch mood {
        case .working: return "working"
        case .happy: return "happy"
        default: return "body"
        }
    }
}

/// An eyelid that slides down over one eye; `amount` 0 = open, 1 = closed.
struct Eyelid: View {
    let amount: CGFloat
    var tilt: Double = 0

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            ZStack(alignment: .top) {
                Ellipse()
                    .fill(LinearGradient(colors: OwlArt.fur, startPoint: .top, endPoint: .bottom))
                    .frame(width: g.size.width * 1.5, height: max(0, h * amount) * 2)
                    .offset(y: -max(0, h * amount))
                    .overlay(alignment: .bottom) {
                        // lash line along the lid edge
                        Ellipse()
                            .trim(from: 0.0, to: 0.5)
                            .stroke(Color(red: 0.1, green: 0.04, blue: 0.18), lineWidth: 2.5)
                            .frame(width: g.size.width * 1.5, height: max(0, h * amount) * 2)
                            .offset(y: -max(0, h * amount))
                            .opacity(amount > 0.05 ? 1 : 0)
                    }
                    .rotationEffect(.degrees(tilt))
            }
            .frame(width: g.size.width, height: h, alignment: .top)
            .clipShape(Ellipse())
        }
    }
}

struct OwlFrame: View {
    let mood: Mood
    let t: Double
    /// Just the owl (with eyelids), filling the given height — used inside the notch.
    var headOnly = false
    /// Eyes follow the mouse (off for static renders).
    var followMouse = true
    /// Force where the eyes look (-1...1 each axis), for previews.
    var lookOverride: CGPoint? = nil
    /// Show the talking beak without actual speech, for previews.
    var previewTalking = false

    static let size = CGSize(width: 210, height: 290)
    private let bodyHeight: CGFloat = 196

    var body: some View {
        if headOnly, let img = ImageArt.image("owl", named: "body") {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .overlay {
                    GeometryReader { g in
                        face(img, in: g.size)
                    }
                }
                .brightness(mood == .sleepy ? -0.12 : 0)
        } else {
            fullBody
        }
    }

    private var surprised: Bool { Date() < PetSignals.shared.surprisedUntil }

    private var lid: CGFloat {
        if surprised { return 0 }
        let blink = t.truncatingRemainder(dividingBy: 4.0) < 0.13 || (t + 0.25).truncatingRemainder(dividingBy: 11.0) < 0.13
        switch mood {
        case .sleepy: return 0.72 + CGFloat(sin(t * 1.1)) * 0.06
        case .sad: return blink ? 1 : 0.34
        case .thinking: return blink ? 1 : 0.18
        default: return blink ? 1 : 0
        }
    }

    @ViewBuilder private var fullBody: some View {
        let accent = OwlArt.accent
        // On long jobs, switch between the headphones pose and reading the code (live eyes scanning).
        // working uses the full body (live eyes reading the code) with drawn headphones
        let pose = mood == .working ? "body" : OwlArt.pose(for: mood)
        let jump = mood == .happy ? -abs(sin(t * 4.2)) * 16 : (mood == .working ? -abs(sin(t * 4.4)) * 4 : 0)   // bopping to the music
        let breathe = 1 + sin(t * (mood == .sleepy ? 1.0 : 2.0)) * 0.012
        // thinking: tilt the head one way, then the other, every few seconds
        let thinkSide: Double = sin(t * 0.55) > 0 ? 1 : -1
        let tilt: Double = mood == .thinking ? thinkSide * (6 + sin(t * 1.4) * 2)
            : (mood == .sad ? -4 : (mood == .working ? sin(t * 2.2) * 4 : sin(t * 0.8) * 2.5))

        ZStack(alignment: .bottom) {
            // soft floor glow
            Ellipse().fill(RadialGradient(colors: [accent.opacity(0.45), .clear], center: .center, startRadius: 2, endRadius: 70))
                .frame(width: 150, height: 28).offset(y: -14)
            particles(accent)

            ZStack {
                if pose == "body", let img = ImageArt.image("owl", named: "body") {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                        .overlay {
                            GeometryReader { g in
                                face(img, in: g.size)
                            }
                        }
                        .brightness(mood == .sleepy ? -0.15 : 0)
                        .saturation(mood == .sad ? 0.75 : 1)
                        .frame(height: bodyHeight)
                        .scaleEffect(x: 1 + (breathe - 1) * 0.5, y: breathe, anchor: .bottom)
                        .rotationEffect(.degrees(tilt), anchor: .bottom)
                        .transition(.opacity)
                } else if let img = ImageArt.image("owl", named: pose) {
                    // upper-body poses fade out at the bottom so they float
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                        .frame(width: 200)
                        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.75),
                                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                        .scaleEffect(breathe, anchor: .bottom)
                        .rotationEffect(.degrees(tilt), anchor: .bottom)
                        .offset(y: -40)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: pose)
            .offset(y: -18 + jump)

            props(accent)
            if PetSignals.shared.quiet && mood != .thinking {
                Text("🤫 Focus").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0.36, green: 0.22, blue: 0.6).opacity(0.9)))
                    .offset(x: -62, y: -200)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
    }

    // MARK: Live face — moving irises, reacting pupils, talking beak

    /// Beak tip inside body.png (fractions of the image).
    private static let beakTip = CGPoint(x: 0.586, y: 0.418)

    @ViewBuilder
    private func face(_ img: NSImage, in size: CGSize) -> some View {
        let look = lookVector
        liveEye(OwlArt.leftEye, in: size, look: look, isRight: false)
        liveEye(OwlArt.rightEye, in: size, look: look, isRight: true)
        furLid(img, OwlArt.leftEye, in: size, tilt: mood == .sad ? -14 : 0)
        furLid(img, OwlArt.rightEye, in: size, tilt: mood == .sad ? 14 : 0)
        if Voice.shared.isSpeaking || previewTalking { talkingBeak(in: size) }
        OwlAccessories(worn: Evolution.shared.worn, size: size)
        if mood == .working { Headphones(t: t, size: size) }
    }

    /// Where the eyes point, -1...1 on each axis (y down).
    private var lookVector: CGPoint {
        if let o = lookOverride { return o }
        if surprised { return CGPoint(x: 0, y: -0.35) }
        switch mood {
        case .thinking: return CGPoint(x: 0.65 + sin(t * 0.7) * 0.1, y: -0.85)
        case .working: return CGPoint(x: sin(t * 2.4) * 0.75, y: 0.6)          // reading lines of code
        case .sad: return CGPoint(x: sin(t * 0.5) * 0.15, y: 0.75)
        case .sleepy: return CGPoint(x: 0, y: 0.5)
        default: break
        }
        if PetSignals.shared.chatOpen { return CGPoint(x: -0.45, y: -0.75) }  // looking up at the chat
        if followMouse, let m = mouseLook { return m }
        return wander
    }

    /// Look at the mouse when it's reasonably close to the owl.
    private var mouseLook: CGPoint? {
        let f = PetGeometry.frame
        guard f.width > 0 else { return nil }
        let m = NSEvent.mouseLocation
        let eyes = CGPoint(x: f.midX, y: f.minY + f.height * 0.55)
        let dx = m.x - eyes.x, dy = m.y - eyes.y
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist < 700, dist > 12 else { return nil }
        let k = min(1, dist / 220)
        return CGPoint(x: dx / dist * k, y: -dy / dist * k)
    }

    /// Idle glances: hold a spot, then dart to a new one (like real eyes).
    private var wander: CGPoint {
        func spot(_ n: Double) -> CGPoint {
            func r(_ s: Double) -> Double { let v = sin(n * 12.9898 + s) * 43758.5453; return (v - v.rounded(.down)) * 2 - 1 }
            return CGPoint(x: r(1) * 0.8, y: r(2) * 0.5)
        }
        let period = 2.4
        let seg = (t / period).rounded(.down)
        let p = min(1, (t / period - seg) * 7)   // quick dart, then hold
        let a = spot(seg - 1), b = spot(seg)
        return CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }

    private var pupilRatio: CGFloat {
        if surprised { return 0.4 }
        switch mood {
        case .working: return 0.5
        case .thinking: return 0.56
        case .sad: return 0.72
        case .sleepy: return 0.66
        default: return 0.7 + CGFloat(sin(t * 0.9)) * 0.03   // slow, relaxed "breathing" pupils
        }
    }

    /// Repaints the eye white and draws a moving iris + pupil, clipped to the eye.
    private func liveEye(_ r: CGRect, in size: CGSize, look: CGPoint, isRight: Bool) -> some View {
        let w = r.width * size.width, h = r.height * size.height
        let cx = r.minX * size.width, cy = r.minY * size.height
        let irisH = h * 0.6
        let squash: CGFloat = isRight ? 0.86 : 1      // the right eye turns away a little
        let irisW = irisH * squash
        let maxX = max(0, (w - irisW) / 2 * 0.8), maxY = max(0, (h - irisH) / 2 * 0.72)
        return ZStack {
            Ellipse()
                .fill(RadialGradient(colors: [Color(white: 0.99), Color(white: 0.94), Color(white: 0.80)],
                                     center: UnitPoint(x: 0.45, y: 0.42), startRadius: 0, endRadius: max(w, h) * 0.58))
                .frame(width: w * 0.97, height: h * 0.97)
            Ellipse()
                .fill(LinearGradient(colors: [Color.black.opacity(0.22), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))
                .frame(width: w * 0.97, height: h * 0.97)
            iris(size: irisH)
                .scaleEffect(x: squash, y: 1)
                .offset(x: look.x * maxX, y: look.y * maxY)
        }
        .frame(width: w * 0.97, height: h * 0.97)
        .clipShape(Ellipse())
        .position(x: cx, y: cy)
    }

    private func iris(size d: CGFloat) -> some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(red: 0.30, green: 0.13, blue: 0.04), Color(red: 0.66, green: 0.33, blue: 0.11),
                                                  Color(red: 0.42, green: 0.17, blue: 0.05)],
                                         center: .center, startRadius: 0, endRadius: d / 2))
            ForEach(0..<14, id: \.self) { i in
                Capsule().fill(Color(red: 0.85, green: 0.55, blue: 0.25).opacity(0.25))
                    .frame(width: d * 0.02, height: d * 0.16)
                    .offset(y: -d * 0.36)
                    .rotationEffect(.degrees(Double(i) * 360 / 14))
            }
            Circle().stroke(Color(red: 0.16, green: 0.06, blue: 0.02), lineWidth: d * 0.07)
            Circle().fill(Color.black).frame(width: d * pupilRatio, height: d * pupilRatio)
            Ellipse().fill(Color.white.opacity(0.95)).frame(width: d * 0.27, height: d * 0.21).offset(x: -d * 0.16, y: -d * 0.19)
            Circle().fill(Color.white.opacity(0.85)).frame(width: d * 0.09, height: d * 0.09).offset(x: d * 0.19, y: d * 0.15)
        }
        .frame(width: d, height: d)
    }

    /// Beak opens and closes while Kiri speaks out loud.
    private func talkingBeak(in size: CGSize) -> some View {
        let open = CGFloat(abs(sin(t * 15)) * (0.65 + 0.35 * sin(t * 2.7)))
        let x = Self.beakTip.x * size.width, tipY = Self.beakTip.y * size.height
        let gapH = size.height * 0.05 * open
        return ZStack {
            // dark open mouth just under the upper beak
            Ellipse().fill(LinearGradient(colors: [Color(red: 0.22, green: 0.05, blue: 0.08), Color(red: 0.45, green: 0.12, blue: 0.16)],
                                          startPoint: .top, endPoint: .bottom))
                .frame(width: size.width * 0.07, height: max(0.5, gapH))
                .position(x: x, y: tipY - size.height * 0.004 + gapH / 2)
            // lower beak drops as the mouth opens
            BeakTip().fill(LinearGradient(colors: [Color(red: 0.90, green: 0.70, blue: 0.48), Color(red: 0.68, green: 0.46, blue: 0.28)],
                                          startPoint: .top, endPoint: .bottom))
                .frame(width: size.width * 0.055, height: size.height * 0.028)
                .position(x: x, y: tipY + gapH * 0.9)
        }
    }

    /// An eyelid made of the owl's own fur: the cheek fur just below the eye is copied up
    /// into the eye and clipped to a curved lid shape, so it matches texture and lighting.
    @ViewBuilder
    private func furLid(_ img: NSImage, _ r: CGRect, in size: CGSize, tilt: Double) -> some View {
        let amount = lid
        let w = r.width * size.width, h = r.height * size.height
        let cx = r.minX * size.width, cy = r.minY * size.height
        let top = cy - h / 2
        let lidH = max(0.001, amount * h * 1.04)
        let eyeMask = Ellipse().frame(width: w * 1.04, height: h * 1.04).position(x: cx, y: cy)
        let lidShape = Ellipse().frame(width: w * 1.7, height: lidH * 2).position(x: cx, y: top)
            .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: cx / size.width, y: cy / size.height))
        if amount > 0.01 {
            ZStack {
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: size.width, height: size.height)
                    .offset(y: -(h + 8))
                // a little shading toward the lid edge for depth
                LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                    .frame(width: w * 1.1, height: lidH).position(x: cx, y: top + lidH / 2)
            }
            .frame(width: size.width, height: size.height)
            .mask(lidShape)
            .mask(eyeMask)
            // lash line along the lid edge
            Ellipse().stroke(Color(red: 0.08, green: 0.03, blue: 0.14), lineWidth: 2.2)
                .frame(width: w * 1.7, height: lidH * 2).position(x: cx, y: top)
                .rotationEffect(.degrees(tilt), anchor: UnitPoint(x: cx / size.width, y: cy / size.height))
                .mask(eyeMask)
        }
    }

    private func particles(_ accent: Color) -> some View {
        let count = mood == .happy ? 14 : (mood == .sleepy ? 3 : 7)
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let seed = Double(i) * 7.31
                let ph = (t * (mood == .happy ? 0.8 : 0.28) + Double(i) / Double(count)).truncatingRemainder(dividingBy: 1)
                Circle().fill(i % 3 == 0 ? Color.white : accent)
                    .frame(width: i % 4 == 0 ? 4 : 2.5, height: i % 4 == 0 ? 4 : 2.5)
                    .shadow(color: accent, radius: 3)
                    .offset(x: sin(seed) * 80, y: -20 - ph * 220)
                    .opacity(sin(ph * .pi) * 0.9)
            }
        }
    }

    @ViewBuilder private func props(_ accent: Color) -> some View {
        switch mood {
        case .thinking:
            ThinkSparks(t: t, color: accent)
            WorkBadge(t: t)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(accent).frame(width: 7, height: 7).offset(y: sin(t * 6 - Double(i)) * 3)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(0.95)))
            .shadow(color: .black.opacity(0.2), radius: 4)
            .offset(x: 70, y: -218)
        case .working:
            ZStack {
                CodeGlyphs(t: t, color: accent)
                WorkBadge(t: t)
            }
        case .happy:
            Confetti(t: t).offset(y: -150)
        case .sad where PetSignals.shared.batteryLow:
            LowBatteryBadge(t: t, percent: PetSignals.shared.batteryPercent).offset(y: -226 + sin(t * 1.5) * 2)
        case .sad:
            ZStack {
                CloudShape().fill(LinearGradient(colors: [Color(white: 0.75), Color(white: 0.55)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 70, height: 48)
                ForEach(0..<4, id: \.self) { i in
                    let ph = (t * 1.3 + Double(i) * 0.4).truncatingRemainder(dividingBy: 1)
                    Capsule().fill(Color(red: 0.5, green: 0.75, blue: 1)).frame(width: 2.5, height: 8)
                        .offset(x: -18 + CGFloat(i) * 12, y: 30 + ph * 26).opacity(1 - ph)
                }
            }
            .offset(x: 0, y: -232 + sin(t * 1.5) * 2)
        case .sleepy:
            Zzz(t: t, color: accent, x: 40, y: -210)
        case .idle:
            EmptyView()
        }
    }
}

/// Glowing audio bars on both sides — "listening / working".
struct SoundWaves: View {
    let t: Double
    var color: Color
    var spread: CGFloat = 112
    var bars = 9

    var body: some View {
        HStack(spacing: spread) {
            side(flip: false)
            side(flip: true)
        }
    }

    private func side(flip: Bool) -> some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                let k = flip ? i : bars - 1 - i
                let h = 6 + abs(sin(t * 7 + Double(k) * 0.8)) * Double(26 - k * 2)
                Capsule().fill(color).frame(width: 2.5, height: max(4, h))
                    .shadow(color: color, radius: 3)
                    .opacity(1 - Double(k) * 0.08)
            }
        }
    }
}

/// Little celebratory confetti and stars that drift and twinkle.
struct Confetti: View {
    let t: Double
    var width: CGFloat = 220
    var height: CGFloat = 160

    var body: some View {
        let colors: [Color] = [.yellow, .pink, .mint, .cyan, .purple, .orange]
        ZStack {
            ForEach(0..<16, id: \.self) { i in
                let seed = Double(i) * 3.77
                let ph = (t * 0.55 + Double(i) / 16).truncatingRemainder(dividingBy: 1)
                Group {
                    if i % 4 == 0 {
                        Text("✦").font(.system(size: 12))
                    } else if i % 4 == 1 {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                    } else {
                        RoundedRectangle(cornerRadius: 1).frame(width: 5, height: 8)
                    }
                }
                .foregroundStyle(colors[i % colors.count])
                .rotationEffect(.degrees(t * 180 + seed * 40))
                .offset(x: sin(seed) * width / 2, y: -height / 2 + ph * height)
                .opacity(sin(ph * .pi))
            }
        }
    }
}

/// Small downward triangle: the lower half of the beak when it opens.
struct BeakTip: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 2 - r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: Busy animations (so Hoot never just stands still while Claude works)

/// Little bits of code floating up from the owl while it works.
struct CodeGlyphs: View {
    let t: Double
    let color: Color
    private static let glyphs = ["</>", "{ }", ";", "#", "()", "=>", "[ ]", "fn"]
    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                let ph = (t * 0.35 + Double(i) / 6).truncatingRemainder(dividingBy: 1)
                let side: CGFloat = i % 2 == 0 ? -1 : 1
                Text(Self.glyphs[(i + Int(t * 0.35)) % Self.glyphs.count])
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(i % 3 == 0 ? Color.white : color)
                    .shadow(color: color, radius: 4)
                    .offset(x: side * (95 + CGFloat(sin(t * 1.3 + Double(i))) * 8), y: -50 - CGFloat(ph) * 190)
                    .opacity(sin(ph * .pi))
            }
        }
    }
}

/// Sparks circling the head while thinking.
struct ThinkSparks: View {
    let t: Double
    let color: Color
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let a = t * 1.6 + Double(i) * 2.094
                Image(systemName: "sparkle").font(.system(size: 11 + CGFloat(i) * 2, weight: .bold))
                    .foregroundStyle(i == 1 ? Color.yellow : color)
                    .offset(x: cos(a) * 88, y: -222 + sin(a) * 14)
                    .opacity(0.55 + 0.45 * sin(a * 2))
            }
        }
    }
}

/// What Hoot is doing and for how long: "✏️ 0:42".
struct WorkBadge: View {
    let t: Double
    var body: some View {
        let s = PetSignals.shared
        if let since = s.busySince {
            let secs = max(0, Int(Date().timeIntervalSince(since)))
            HStack(spacing: 4) {
                Text(PetSignals.icon(for: s.activity) ?? "💭").font(.system(size: 13))
                    .scaleEffect(1 + 0.12 * sin(t * 6))
                Text(String(format: "%d:%02d", secs / 60, secs % 60))
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.6)))
            .offset(x: -70, y: -12)
        }
    }
}

/// Glowing headphones drawn on the full-body owl while it works (positions are fractions of body.png).
struct Headphones: View {
    let t: Double
    let size: CGSize
    var body: some View {
        let w = size.width, h = size.height
        let glow = Color(red: 0.35, green: 0.8, blue: 1)
        let pulse = 0.65 + 0.35 * sin(t * 5)
        let l = CGPoint(x: 0.1 * w, y: 0.38 * h), r = CGPoint(x: 0.99 * w, y: 0.38 * h)
        ZStack {
            Path { p in
                p.move(to: CGPoint(x: l.x + 0.01 * w, y: l.y - 0.06 * h))
                p.addQuadCurve(to: CGPoint(x: r.x - 0.01 * w, y: r.y - 0.06 * h), control: CGPoint(x: 0.55 * w, y: -0.2 * h))
            }
            .stroke(LinearGradient(colors: [Color(white: 0.22), Color(white: 0.42)], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: 0.035 * w, lineCap: .round))
            ForEach([l, r], id: \.x) { c in
                ZStack {
                    RoundedRectangle(cornerRadius: 0.05 * w).fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.12)], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: 0.05 * w).stroke(glow.opacity(pulse), lineWidth: 0.012 * w)
                }
                .frame(width: 0.1 * w, height: 0.19 * h)
                .shadow(color: glow.opacity(0.7 * pulse), radius: 6)
                .position(c)
            }
            // little music notes popping out
            ForEach(0..<2, id: \.self) { i in
                let ph = (t * 0.7 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Image(systemName: i == 0 ? "music.note" : "music.quarternote.3")
                    .font(.system(size: 0.07 * w, weight: .bold)).foregroundStyle(glow)
                    .position(x: (i == 0 ? r.x + 0.06 * w : l.x - 0.06 * w), y: r.y - 0.1 * h - ph * 0.2 * h)
                    .opacity(sin(ph * .pi))
            }
        }
        .allowsHitTesting(false)
    }
}
