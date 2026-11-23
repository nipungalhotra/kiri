import Foundation
import IOKit.ps
import SwiftUI

/// Mac battery level via IOKit power sources.
enum Battery {
    struct Status {
        let percent: Int
        let onBattery: Bool
    }

    /// `--battery 15` pretends the battery is at 15% (unplugged), for testing.
    static let override: Int? = CommandLine.arguments.firstIndex(of: "--battery").flatMap {
        $0 + 1 < CommandLine.arguments.count ? Int(CommandLine.arguments[$0 + 1]) : nil }

    static func read() -> Status? {
        if let o = override { return Status(percent: o, onBattery: true) }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            return Status(percent: cur * 100 / max, onBattery: state == kIOPSBatteryPowerValue)
        }
        return nil  // desktop Mac: no battery
    }
}

/// Small shared signals the character art reacts to (beyond the mood itself).
@MainActor
final class PetSignals: ObservableObject {
    static let shared = PetSignals()
    /// Unplugged and at or below the low-battery threshold.
    @Published var batteryLow = false
    @Published var batteryPercent = 100
    /// Wide-eyed "oh!" until this moment.
    @Published var surprisedUntil = Date.distantPast
    /// Chat panel is open (the owl looks up at it).
    @Published var chatOpen = false
    /// Quiet mode / Focus is on (the owl wears a little "shh" badge).
    @Published var quiet = false
    /// What Claude is doing right now ("Reading app.py"), and since when Kiri has been busy.
    var activity: String?
    var busySince: Date?
    /// Claude jobs running in the background.
    @Published var backgroundCount = 0

    /// A little picture for the current activity.
    static func icon(for activity: String?) -> String? {
        guard let a = activity?.lowercased() else { return nil }
        if a.hasPrefix("reading") { return "📖" }
        if a.hasPrefix("editing") || a.hasPrefix("writing") { return "✏️" }
        if a.hasPrefix("running") { return a.contains("test") ? "🧪" : "💻" }
        if a.hasPrefix("searching") { return "🔍" }
        if a.hasPrefix("looking it up") { return "🌐" }
        if a.hasPrefix("making a plan") { return "📝" }
        if a.hasPrefix("listening") { return "🎧" }
        if a.hasPrefix("looking at your screen") { return "👀" }
        return nil
    }

    func surprise(for seconds: Double = 0.7) { surprisedUntil = Date().addingTimeInterval(seconds) }
}

/// Blinking red battery shown above the owl when the battery is low.
struct LowBatteryBadge: View {
    let t: Double
    let percent: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "battery.25percent").font(.system(size: 20, weight: .semibold))
            Text("\(percent)%").font(.system(size: 13, weight: .bold, design: .rounded))
        }
        .foregroundStyle(Color(red: 1, green: 0.32, blue: 0.3))
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.75)))
        .opacity(0.55 + 0.45 * (sin(t * 4) > 0 ? 1 : 0.3))
    }
}
