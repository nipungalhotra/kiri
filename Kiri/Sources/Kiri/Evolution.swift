import SwiftUI

/// Hoot earns accessories as you work together:
///   🤓 glasses after 10 passing test runs · 🎓 graduation cap after 5 fixes · 👑 crown for a 10-run green streak
@MainActor
final class Evolution: ObservableObject {
    static let shared = Evolution()

    enum Accessory: String, CaseIterable {
        case glasses, cap, crown
        var title: String { ["glasses": "Smart glasses 🤓", "cap": "Graduation cap 🎓", "crown": "Crown 👑"][rawValue]! }
        var goal: String { ["glasses": "10 passing test runs", "cap": "5 fixes", "crown": "10 green runs in a row"][rawValue]! }
    }

    @Published private(set) var passes: Int
    @Published private(set) var fixes: Int
    @Published private(set) var bestStreak: Int
    @Published var showAccessories: Bool { didSet { UserDefaults.standard.set(showAccessories, forKey: "showAccessories") } }
    /// For screenshots/demos: `--accessories` shows everything.
    private let forceAll = CommandLine.arguments.contains("--accessories")

    private init() {
        let d = UserDefaults.standard
        passes = d.integer(forKey: "evoPasses")
        fixes = d.integer(forKey: "evoFixes")
        bestStreak = d.integer(forKey: "evoBestStreak")
        showAccessories = d.object(forKey: "showAccessories") as? Bool ?? true
    }

    func has(_ a: Accessory) -> Bool {
        switch a {
        case .glasses: return passes >= 10
        case .cap: return fixes >= 5
        case .crown: return bestStreak >= 10
        }
    }

    /// What the owl wears right now.
    var worn: Set<Accessory> {
        if forceAll { return Set(Accessory.allCases) }
        guard showAccessories else { return [] }
        return Set(Accessory.allCases.filter(has))
    }

    func progress(_ a: Accessory) -> String {
        switch a {
        case .glasses: return "\(min(passes, 10))/10"
        case .cap: return "\(min(fixes, 5))/5"
        case .crown: return "\(min(bestStreak, 10))/10"
        }
    }

    /// Returns any accessory that was just unlocked.
    func testsPassed(streak: Int) -> Accessory? {
        let before = Set(Accessory.allCases.filter(has))
        passes += 1
        bestStreak = max(bestStreak, streak)
        save()
        return Accessory.allCases.first { has($0) && !before.contains($0) }
    }

    func fixed() -> Accessory? {
        let had = has(.cap)
        fixes += 1
        save()
        return !had && has(.cap) ? .cap : nil
    }

    var summary: String {
        Accessory.allCases.map { a in (has(a) ? "✅ " : "🔒 ") + "\(a.title): \(a.goal) (\(progress(a)))" }.joined(separator: "\n")
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(passes, forKey: "evoPasses")
        d.set(fixes, forKey: "evoFixes")
        d.set(bestStreak, forKey: "evoBestStreak")
    }
}

/// Drawn on top of the owl's body image (coordinates are fractions of body.png, like the eyes).
struct OwlAccessories: View {
    let worn: Set<Evolution.Accessory>
    let size: CGSize

    var body: some View {
        ZStack {
            if worn.contains(.glasses) { glasses }
            if worn.contains(.crown) {
                Text("👑").font(.system(size: size.width * 0.26))
                    .rotationEffect(.degrees(-8))
                    .position(x: size.width * 0.56, y: size.height * 0.06)
            } else if worn.contains(.cap) {
                Text("🎓").font(.system(size: size.width * 0.3))
                    .rotationEffect(.degrees(-6))
                    .position(x: size.width * 0.56, y: size.height * 0.07)
            }
        }
        .allowsHitTesting(false)
    }

    private var glasses: some View {
        let l = OwlArt.leftEye, r = OwlArt.rightEye
        let frame = Color(red: 0.16, green: 0.08, blue: 0.24)
        let lw = size.width * 0.022
        // OwlArt eye rects store the eye's centre in x/y (same as the live eyes use)
        let lc = CGPoint(x: l.minX * size.width, y: l.minY * size.height)
        let rc = CGPoint(x: r.minX * size.width, y: r.minY * size.height)
        let ld = max(l.width * size.width, l.height * size.height) * 1.1
        let rd = max(r.width * size.width, r.height * size.height) * 1.1
        return ZStack {
            Circle().stroke(frame, lineWidth: lw).frame(width: ld, height: ld).position(lc)
            Circle().stroke(frame, lineWidth: lw).frame(width: rd, height: rd).position(rc)
            Path { p in
                p.move(to: CGPoint(x: lc.x + ld / 2, y: lc.y - ld * 0.08))
                p.addQuadCurve(to: CGPoint(x: rc.x - rd / 2, y: rc.y - rd * 0.08),
                               control: CGPoint(x: (lc.x + rc.x) / 2, y: min(lc.y, rc.y) - ld * 0.22))
            }.stroke(frame, lineWidth: lw)
            // a little shine on the lenses
            Circle().fill(Color.white.opacity(0.1)).frame(width: ld * 0.9, height: ld * 0.9).position(lc)
            Circle().fill(Color.white.opacity(0.1)).frame(width: rd * 0.9, height: rd * 0.9).position(rc)
        }
    }
}
