import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Where the sun sits for the 3D view. Sunrise and sunset share a colour; the phase
/// only records which side of the day the warm light belongs to.
public enum DaylightPhase: String, Equatable, Sendable, Codable {
    case night
    case sunrise
    case day
    case sunset

    public var label: String {
        switch self {
        case .night: return "Night"
        case .sunrise: return "Sunrise"
        case .sunset: return "Sunset"
        case .day: return "Midday"
        }
    }
}

/// Scene-light colour and strength. Channels and `key` / `fill` are 0...1.
/// `key` is the sun. `fill` is the ambient lift so a room is never black.
public struct DaylightTint: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var key: Double
    public var fill: Double
    public var phase: DaylightPhase

    public init(red: Double, green: Double, blue: Double, key: Double, fill: Double, phase: DaylightPhase) {
        self.red = red
        self.green = green
        self.blue = blue
        self.key = key
        self.fill = fill
        self.phase = phase
    }

    /// Neutral studio light used when the daylight tint is turned off.
    public static let studio = DaylightTint(
        red: 1,
        green: 0.98,
        blue: 0.95,
        key: 1,
        fill: 0.62,
        phase: .day
    )
}

/// `sun.sun` as far as the tint needs it. Dates are the entity's next rise and set.
public struct SunSample: Equatable, Sendable {
    public var state: String
    public var elevation: Double?
    public var nextRising: Date?
    public var nextSetting: Date?

    public init(state: String, elevation: Double? = nil, nextRising: Date? = nil, nextSetting: Date? = nil) {
        self.state = state
        self.elevation = elevation
        self.nextRising = nextRising
        self.nextSetting = nextSetting
    }

    public init(_ snapshot: EntitySnapshot) {
        state = snapshot.state
        elevation = snapshot.elevation
        nextRising = snapshot.nextRising
        nextSetting = snapshot.nextSetting
    }

    /// Elevation, a rise/set pair, or the above/below horizon state. Anything else
    /// leaves the clock approximation in charge.
    public var drivesTint: Bool {
        if let elevation, elevation.isFinite { return true }
        if nextRising != nil, nextSetting != nil { return true }
        return state == "above_horizon" || state == "below_horizon"
    }
}

/// Maps solar elevation, Home Assistant `sun.sun`, or a location-free clock onto a tint.
///
/// The clock path assumes sunrise at 06:00 and sunset at 18:00 local time and a 55° peak,
/// which is an equinox-like day with no latitude. It does not read the device location.
/// A connected Home Assistant wins: elevation first, then `next_rising` / `next_setting`,
/// then the above/below horizon state.
public enum DaylightMath {
    public static let sunEntityID = "sun.sun"
    /// Local hour the approximation treats as sunrise.
    public static let sunriseHour = 6.0
    /// Local hour the approximation treats as sunset.
    public static let sunsetHour = 18.0
    /// Peak elevation of the sine used when Home Assistant has no elevation.
    public static let peakElevation = 55.0

    /// Warm while the sun is low, neutral once it is well up, blue once it is down.
    public static func phase(elevation: Double, morning: Bool) -> DaylightPhase {
        if elevation >= 20 { return .day }
        if elevation <= -6 { return .night }
        return morning ? .sunrise : .sunset
    }

    public static func tint(elevation: Double, morning: Bool) -> DaylightTint {
        let clamped = min(90, max(-90, elevation))
        let sample = interpolate(clamped)
        return DaylightTint(
            red: sample.red,
            green: sample.green,
            blue: sample.blue,
            key: sample.key,
            fill: sample.fill,
            phase: phase(elevation: clamped, morning: morning)
        )
    }

    /// Location-free tint for a local hour in 0...24. 24 matches midnight.
    public static func tint(hour: Double) -> DaylightTint {
        let wrapped = positiveModulo(hour, 24)
        let elevation = peakElevation * sin((wrapped - sunriseHour) / 12 * .pi)
        return tint(elevation: elevation, morning: wrapped < 12)
    }

    public static func tint(at date: Date, calendar: Calendar = .current) -> DaylightTint {
        tint(hour: hour(of: date, calendar: calendar))
    }

    /// Home Assistant first. A sample that cannot drive a tint falls through to the clock.
    public static func resolve(sample: SunSample?, at date: Date, calendar: Calendar = .current) -> DaylightTint {
        if let sample, sample.drivesTint, let tint = tint(sample: sample, now: date, calendar: calendar) {
            return tint
        }
        return tint(at: date, calendar: calendar)
    }

    public static func tint(sample: SunSample, now: Date, calendar: Calendar = .current) -> DaylightTint? {
        let morningFromClock = hour(of: now, calendar: calendar) < 12
        if let elevation = sample.elevation, elevation.isFinite {
            let morning = isMorning(now: now, nextRising: sample.nextRising, nextSetting: sample.nextSetting) ?? morningFromClock
            return tint(elevation: elevation, morning: morning)
        }
        if let rising = sample.nextRising, let setting = sample.nextSetting,
           let elevation = syntheticElevation(now: now, nextRising: rising, nextSetting: setting) {
            let morning = isMorning(now: now, nextRising: rising, nextSetting: setting) ?? morningFromClock
            return tint(elevation: elevation, morning: morning)
        }
        if sample.state == "above_horizon" {
            return tint(elevation: 45, morning: morningFromClock)
        }
        if sample.state == "below_horizon" {
            return tint(elevation: -30, morning: morningFromClock)
        }
        return nil
    }

    public static func hour(of date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60 + Double(parts.second ?? 0) / 3600
    }

    /// `06:30` style label for a fractional hour. Used by the preview slider.
    public static func clockLabel(hour: Double) -> String {
        let wrapped = positiveModulo(hour, 24)
        let totalMinutes = Int((wrapped * 60).rounded()) % (24 * 60)
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    static func number(from value: Any?) -> Double? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        if let text = value as? String {
            let double = Double(text)
            if let double, double.isFinite { return double }
        }
        return nil
    }

    static func date(from value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        if let parsed = isoDate(from: text) { return parsed }
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let tail = text[dot...]
        guard let zone = tail.firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        let trimmed = String(text[..<dot]) + String(text[zone...])
        return isoDate(from: trimmed)
    }

    /// Elevation stand-in when `sun.sun` has rise and set but no elevation.
    /// Day is a positive sine from the previous rise to the next set. Night is the
    /// negative sine from the previous set to the next rise. The previous event is
    /// the matching "next" timestamp minus 24 hours.
    static func syntheticElevation(now: Date, nextRising: Date, nextSetting: Date) -> Double? {
        if nextSetting < nextRising {
            let previousRise = nextRising.addingTimeInterval(-86_400)
            let span = nextSetting.timeIntervalSince(previousRise)
            guard span > 60 else { return nil }
            let fraction = min(1, max(0, now.timeIntervalSince(previousRise) / span))
            return peakElevation * sin(fraction * .pi)
        }
        let previousSet = nextSetting.addingTimeInterval(-86_400)
        let span = nextRising.timeIntervalSince(previousSet)
        guard span > 60 else { return nil }
        let fraction = min(1, max(0, now.timeIntervalSince(previousSet) / span))
        return -peakElevation * sin(fraction * .pi)
    }

    /// `nil` when either timestamp is missing. During the day, morning is the half
    /// before the midpoint of the previous rise and the next set. At night, morning
    /// is the half after the midpoint, toward the next rise.
    static func isMorning(now: Date, nextRising: Date?, nextSetting: Date?) -> Bool? {
        guard let nextRising, let nextSetting else { return nil }
        if nextSetting < nextRising {
            let previousRise = nextRising.addingTimeInterval(-86_400)
            let mid = previousRise.addingTimeInterval(nextSetting.timeIntervalSince(previousRise) / 2)
            return now < mid
        }
        let previousSet = nextSetting.addingTimeInterval(-86_400)
        let mid = previousSet.addingTimeInterval(nextRising.timeIntervalSince(previousSet) / 2)
        return now >= mid
    }

    private static func interpolate(_ elevation: Double) -> (red: Double, green: Double, blue: Double, key: Double, fill: Double) {
        let stops = colorStops
        if elevation <= stops[0].elevation { return channels(stops[0]) }
        if elevation >= stops[stops.count - 1].elevation { return channels(stops[stops.count - 1]) }
        for index in 1..<stops.count {
            let upper = stops[index]
            let lower = stops[index - 1]
            if elevation <= upper.elevation {
                let span = upper.elevation - lower.elevation
                let t = span == 0 ? 0 : (elevation - lower.elevation) / span
                return (
                    mix(lower.red, upper.red, t),
                    mix(lower.green, upper.green, t),
                    mix(lower.blue, upper.blue, t),
                    mix(lower.key, upper.key, t),
                    mix(lower.fill, upper.fill, t)
                )
            }
        }
        return channels(stops[stops.count - 1])
    }

    private static func channels(_ stop: Stop) -> (red: Double, green: Double, blue: Double, key: Double, fill: Double) {
        (stop.red, stop.green, stop.blue, stop.key, stop.fill)
    }

    private static func mix(_ start: Double, _ end: Double, _ t: Double) -> Double {
        let value = start + (end - start) * t
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func positiveModulo(_ value: Double, _ modulus: Double) -> Double {
        guard modulus > 0 else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder < 0 ? remainder + modulus : remainder
    }

    private static func isoDate(from text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// Elevation in degrees, then colour and the two light strengths.
    /// The web card copies this table. Keep the two in step.
    private static let colorStops: [Stop] = [
        Stop(elevation: -90, red: 0.30, green: 0.42, blue: 0.76, key: 0.06, fill: 0.08),
        Stop(elevation: -8, red: 0.40, green: 0.50, blue: 0.74, key: 0.14, fill: 0.13),
        Stop(elevation: 0, red: 1.00, green: 0.55, blue: 0.26, key: 0.32, fill: 0.18),
        Stop(elevation: 15, red: 1.00, green: 0.68, blue: 0.36, key: 0.55, fill: 0.30),
        Stop(elevation: 28, red: 1.00, green: 0.86, blue: 0.68, key: 0.78, fill: 0.42),
        Stop(elevation: 48, red: 1.00, green: 0.97, blue: 0.93, key: 1.00, fill: 0.55),
        Stop(elevation: 90, red: 1.00, green: 0.98, blue: 0.95, key: 1.00, fill: 0.56)
    ]

    private struct Stop {
        var elevation: Double
        var red: Double
        var green: Double
        var blue: Double
        var key: Double
        var fill: Double
    }
}

extension HomeStateProvider {
    /// `sun.sun` when this provider can read it. Nil means the caller should use the clock.
    /// A mock or a missing entity still returns a sample; `drivesTint` says whether to trust it.
    public func sunSample() async -> SunSample? {
        guard let snapshot = try? await snapshot(for: DaylightMath.sunEntityID) else { return nil }
        guard snapshot.entityId == DaylightMath.sunEntityID || snapshot.domain == "sun" else { return nil }
        return SunSample(snapshot)
    }
}
