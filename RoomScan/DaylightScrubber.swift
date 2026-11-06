import SwiftUI
import RoomScanCore
import UIKit

enum DaylightPreference {
    static let enabledKey = "se.jansson.homescan.daylight.enabled"
}

enum DaylightScene {
    static func tint(enabled: Bool, previewHour: Double?, sun: SunSample?, now: Date) -> DaylightTint? {
        guard enabled else { return nil }
        if let previewHour {
            return DaylightMath.tint(hour: previewHour)
        }
        return DaylightMath.resolve(sample: sun, at: now)
    }
}

enum DaylightPaint {
    static func color(_ tint: DaylightTint) -> UIColor {
        UIColor(red: CGFloat(tint.red), green: CGFloat(tint.green), blue: CGFloat(tint.blue), alpha: 1)
    }

    /// Charcoal, pulled a little toward the sun so the empty ground reads the time of day.
    static func background(_ tint: DaylightTint?) -> UIColor {
        guard let tint else { return UIColor(Theme.charcoal) }
        let mix = 0.12 + 0.10 * tint.key
        func channel(_ base: Double, _ tinted: Double) -> CGFloat {
            CGFloat(base * (1 - mix) + tinted * mix)
        }
        return UIColor(
            red: channel(16.0 / 255, tint.red),
            green: channel(14.0 / 255, tint.green),
            blue: channel(12.0 / 255, tint.blue),
            alpha: 1
        )
    }

    /// Yaw for the key light. Morning comes from one side, evening from the other.
    static func yaw(for phase: DaylightPhase) -> Float {
        switch phase {
        case .sunrise: return 0.9
        case .sunset: return -0.9
        case .day: return 0.35
        case .night: return 0.2
        }
    }
}

struct DaylightScrubber: View {
    @Binding var previewHour: Double?
    var now: Date
    var tint: DaylightTint

    private var liveHour: Double {
        DaylightMath.hour(of: now, calendar: .current)
    }

    private var shownHour: Double {
        previewHour ?? liveHour
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(title)
                Spacer(minLength: 8)
                if previewHour != nil {
                    Button("Live") { previewHour = nil }
                        .font(.caption.weight(.semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.mist)
            Slider(
                value: Binding(
                    get: { shownHour },
                    set: { previewHour = $0 }
                ),
                in: 0...24
            )
            .tint(Theme.accentOnCharcoal)
            .accessibilityLabel("Preview time of day")
            .accessibilityValue(DaylightMath.clockLabel(hour: shownHour))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.navy.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var title: String {
        if previewHour != nil {
            return "Preview \(DaylightMath.clockLabel(hour: shownHour)) · \(tint.phase.label)"
        }
        return "Live · \(tint.phase.label)"
    }

    private var symbol: String {
        switch tint.phase {
        case .day: return "sun.max.fill"
        case .sunrise: return "sunrise.fill"
        case .sunset: return "sunset.fill"
        case .night: return "moon.stars.fill"
        }
    }
}
