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

    static let size = CGSize(width: 210, height: 290)
    private let bodyHeight: CGFloat = 196

    var body: some View {
        if headOnly, let img = ImageArt.image("owl", named: "body") {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .overlay {
                    GeometryReader { g in
                        furLid(img, OwlArt.leftEye, in: g.size, tilt: mood == .sad ? -14 : 0)
                        furLid(img, OwlArt.rightEye, in: g.size, tilt: mood == .sad ? 14 : 0)
                    }
                }
                .brightness(mood == .sleepy ? -0.12 : 0)
        } else {
            fullBody
        }
    }

    private var lid: CGFloat {
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
        let pose = OwlArt.pose(for: mood)
        let jump = mood == .happy ? -abs(sin(t * 4.2)) * 16 : 0
        let breathe = 1 + sin(t * (mood == .sleepy ? 1.0 : 2.0)) * 0.012
        let tilt: Double = mood == .thinking ? 6 + sin(t * 1.4) * 2 : (mood == .sad ? -4 : sin(t * 0.8) * 2.5)

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
                                furLid(img, OwlArt.leftEye, in: g.size, tilt: mood == .sad ? -14 : 0)
                                furLid(img, OwlArt.rightEye, in: g.size, tilt: mood == .sad ? 14 : 0)
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
                        .offset(y: -40)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: pose)
            .offset(y: -18 + jump)

            props(accent)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
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
            SoundWaves(t: t, color: Color(red: 0.4, green: 0.8, blue: 1)).offset(y: -140)
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
