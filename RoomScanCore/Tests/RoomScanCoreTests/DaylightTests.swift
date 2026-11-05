import XCTest
@testable import RoomScanCore

final class DaylightTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)!
    }

    func testHorizonIsWarmAndLowAndNightIsDimBlue() {
        let sunrise = DaylightMath.tint(elevation: 0, morning: true)
        let sunset = DaylightMath.tint(elevation: 0, morning: false)
        XCTAssertEqual(sunrise.phase, .sunrise)
        XCTAssertEqual(sunset.phase, .sunset)
        XCTAssertEqual(sunrise.red, 1, accuracy: 0.001)
        XCTAssertEqual(sunrise.green, 0.55, accuracy: 0.001)
        XCTAssertEqual(sunrise.blue, 0.26, accuracy: 0.001)
        XCTAssertEqual(sunrise.key, 0.32, accuracy: 0.001)
        XCTAssertEqual(sunrise.red, sunset.red, accuracy: 0.001)
        XCTAssertEqual(sunrise.blue, sunset.blue, accuracy: 0.001)
        XCTAssertEqual(sunrise.key, sunset.key, accuracy: 0.001)
        XCTAssertGreaterThan(sunrise.red, sunrise.blue + 0.5)

        let midday = DaylightMath.tint(elevation: 48, morning: true)
        XCTAssertEqual(midday.phase, .day)
        XCTAssertEqual(midday.key, 1, accuracy: 0.001)
        XCTAssertGreaterThan(midday.blue, 0.9)
        XCTAssertEqual(midday.red, 1, accuracy: 0.001)
        XCTAssertLessThan(abs(midday.red - midday.blue), 0.1)
        XCTAssertGreaterThan(midday.key, sunrise.key)

        let night = DaylightMath.tint(elevation: -90, morning: false)
        XCTAssertEqual(night.phase, .night)
        XCTAssertEqual(night.red, 0.30, accuracy: 0.001)
        XCTAssertEqual(night.blue, 0.76, accuracy: 0.001)
        XCTAssertEqual(night.key, 0.06, accuracy: 0.001)
        XCTAssertGreaterThan(night.blue, night.red)
        XCTAssertGreaterThan(night.fill, 0.05)
        XCTAssertLessThan(night.key, 0.2)
        XCTAssertLessThan(night.key, sunrise.key)
    }

    func testKeyRisesFromNightToMidday() {
        var previous = -1.0
        for elevation in stride(from: -40.0, through: 60.0, by: 2) {
            let tint = DaylightMath.tint(elevation: elevation, morning: true)
            XCTAssertGreaterThanOrEqual(tint.key, previous - 0.0001)
            previous = tint.key
            for channel in [tint.red, tint.green, tint.blue, tint.key, tint.fill] {
                XCTAssertGreaterThanOrEqual(channel, 0)
                XCTAssertLessThanOrEqual(channel, 1)
            }
        }
    }

    func testClockApproximationIsLocationFree() {
        let calendar = utc
        let summerNoon = date("2026-06-21T12:00:00Z")
        let winterNoon = date("2026-12-21T12:00:00Z")
        XCTAssertEqual(
            DaylightMath.tint(at: summerNoon, calendar: calendar),
            DaylightMath.tint(at: winterNoon, calendar: calendar)
        )

        let noon = DaylightMath.tint(at: summerNoon, calendar: calendar)
        let sunrise = DaylightMath.tint(at: date("2026-06-21T06:00:00Z"), calendar: calendar)
        let sunset = DaylightMath.tint(at: date("2026-06-21T18:00:00Z"), calendar: calendar)
        let midnight = DaylightMath.tint(at: date("2026-06-21T00:00:00Z"), calendar: calendar)
        let seven = DaylightMath.tint(at: date("2026-06-21T07:00:00Z"), calendar: calendar)

        XCTAssertEqual(noon.phase, .day)
        XCTAssertGreaterThan(noon.key, 0.9)
        XCTAssertEqual(sunrise.phase, .sunrise)
        XCTAssertEqual(sunset.phase, .sunset)
        XCTAssertEqual(sunrise.red, sunset.red, accuracy: 0.001)
        XCTAssertEqual(sunrise.blue, sunset.blue, accuracy: 0.001)
        XCTAssertEqual(midnight.phase, .night)
        XCTAssertGreaterThan(midnight.blue, midnight.red)
        XCTAssertGreaterThan(noon.key, sunrise.key)
        XCTAssertGreaterThan(sunrise.key, midnight.key)
        XCTAssertEqual(seven.phase, .sunrise)
        XCTAssertGreaterThan(seven.red, seven.blue + 0.4)
        XCTAssertLessThan(seven.key, noon.key)

        XCTAssertEqual(DaylightMath.tint(hour: 24), DaylightMath.tint(hour: 0))
        XCTAssertEqual(DaylightMath.tint(hour: -1), DaylightMath.tint(hour: 23))
        XCTAssertEqual(DaylightMath.clockLabel(hour: 6.5), "06:30")
        XCTAssertEqual(DaylightMath.clockLabel(hour: 0), "00:00")
        XCTAssertEqual(DaylightMath.clockLabel(hour: 24), "00:00")
    }

    func testElevationBeatsTheClockAndTheHorizonState() {
        let calendar = utc
        let midnight = date("2026-06-21T00:00:00Z")
        let high = SunSample(state: "below_horizon", elevation: 50, nextRising: nil, nextSetting: nil)
        let tint = DaylightMath.resolve(sample: high, at: midnight, calendar: calendar)
        XCTAssertEqual(tint.phase, .day)
        XCTAssertGreaterThan(tint.key, 0.9)

        let clockOnly = DaylightMath.resolve(sample: nil, at: midnight, calendar: calendar)
        XCTAssertEqual(clockOnly.phase, .night)
    }

    func testRiseAndSetStandInForElevation() {
        let calendar = utc
        let noon = date("2026-06-21T12:00:00Z")
        let day = SunSample(
            state: "above_horizon",
            elevation: nil,
            nextRising: date("2026-06-22T06:00:00Z"),
            nextSetting: date("2026-06-21T18:00:00Z")
        )
        let dayTint = DaylightMath.resolve(sample: day, at: noon, calendar: calendar)
        XCTAssertEqual(dayTint.phase, .day)
        XCTAssertEqual(dayTint.key, 1, accuracy: 0.02)

        let midnight = date("2026-06-21T00:00:00Z")
        let night = SunSample(
            state: "below_horizon",
            elevation: nil,
            nextRising: date("2026-06-21T06:00:00Z"),
            nextSetting: date("2026-06-21T18:00:00Z")
        )
        let nightTint = DaylightMath.resolve(sample: night, at: midnight, calendar: calendar)
        XCTAssertEqual(nightTint.phase, .night)
        XCTAssertGreaterThan(nightTint.blue, nightTint.red)
        XCTAssertLessThan(nightTint.key, 0.2)
    }

    func testLowSunUsesRiseAndSetToPickSunriseOrSunset() {
        let calendar = utc
        let morning = SunSample(
            state: "above_horizon",
            elevation: 4,
            nextRising: date("2026-06-22T06:00:00Z"),
            nextSetting: date("2026-06-21T18:00:00Z")
        )
        let sunrise = DaylightMath.tint(sample: morning, now: date("2026-06-21T07:00:00Z"), calendar: calendar)
        XCTAssertEqual(sunrise?.phase, .sunrise)

        let evening = SunSample(
            state: "above_horizon",
            elevation: 4,
            nextRising: date("2026-06-22T06:00:00Z"),
            nextSetting: date("2026-06-21T18:00:00Z")
        )
        let sunset = DaylightMath.tint(sample: evening, now: date("2026-06-21T17:00:00Z"), calendar: calendar)
        XCTAssertEqual(sunset?.phase, .sunset)
        XCTAssertEqual(sunrise?.red ?? -1, sunset?.red ?? -2, accuracy: 0.001)

        let beforeDawn = SunSample(
            state: "below_horizon",
            elevation: -2,
            nextRising: date("2026-06-21T06:00:00Z"),
            nextSetting: date("2026-06-21T18:00:00Z")
        )
        XCTAssertEqual(
            DaylightMath.tint(sample: beforeDawn, now: date("2026-06-21T05:00:00Z"), calendar: calendar)?.phase,
            .sunrise
        )
        let afterDusk = SunSample(
            state: "below_horizon",
            elevation: -2,
            nextRising: date("2026-06-22T06:00:00Z"),
            nextSetting: date("2026-06-22T18:00:00Z")
        )
        XCTAssertEqual(
            DaylightMath.tint(sample: afterDusk, now: date("2026-06-21T21:00:00Z"), calendar: calendar)?.phase,
            .sunset
        )
    }

    func testHorizonStateIsUsedWhenNumbersAreMissing() {
        let calendar = utc
        let noon = date("2026-06-21T12:00:00Z")
        let above = DaylightMath.resolve(
            sample: SunSample(state: "above_horizon"),
            at: noon,
            calendar: calendar
        )
        XCTAssertEqual(above.phase, .day)
        XCTAssertGreaterThan(above.key, 0.9)
        XCTAssertGreaterThan(above.blue, 0.85)

        let below = DaylightMath.resolve(
            sample: SunSample(state: "below_horizon"),
            at: noon,
            calendar: calendar
        )
        XCTAssertEqual(below.phase, .night)
        XCTAssertGreaterThan(below.blue, below.red)
    }

    func testUnknownSunDoesNotOverrideTheClock() {
        let calendar = utc
        let noon = date("2026-06-21T12:00:00Z")
        let sample = SunSample(state: "unknown")
        XCTAssertFalse(sample.drivesTint)
        XCTAssertEqual(
            DaylightMath.resolve(sample: sample, at: noon, calendar: calendar).phase,
            .day
        )
    }

    func testSunStateCarriesElevationAndFractionalRiseSet() throws {
        let data = Data(#"""
        {"entity_id":"sun.sun","state":"above_horizon","attributes":{"elevation":12.5,"azimuth":93,"next_rising":"2026-11-06T06:42:00.000000+00:00","next_setting":"2026-11-05T16:10:00+00:00","friendly_name":"Sun"}}
        """#.utf8)
        let record = try XCTUnwrap(try HomeAssistantDecoding.records(from: data).first)
        XCTAssertEqual(record.elevation ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(record.nextRising, date("2026-11-06T06:42:00Z"))
        XCTAssertEqual(record.nextSetting, date("2026-11-05T16:10:00Z"))
        let sample = SunSample(record.snapshot)
        XCTAssertTrue(sample.drivesTint)
        let tint = DaylightMath.resolve(sample: sample, at: date("1970-01-01T00:00:00Z"), calendar: utc)
        XCTAssertNotEqual(tint.phase, .night)
        XCTAssertGreaterThan(tint.red, tint.blue + 0.4)

        let light = Data(#"""
        {"entity_id":"light.kitchen","state":"on","attributes":{"elevation":80,"brightness":255}}
        """#.utf8)
        let lamp = try XCTUnwrap(try HomeAssistantDecoding.records(from: light).first)
        XCTAssertNil(lamp.elevation)
        XCTAssertNil(lamp.snapshot.elevation)
    }

    func testProvidersExposeSunOrLeaveTheClockAlone() async {
        let missing = await UnconfiguredHomeAssistantClient().sunSample()
        XCTAssertNil(missing)

        let mock = await MockHomeStateProvider().sunSample()
        XCTAssertEqual(mock?.state, "unknown")
        XCTAssertEqual(mock?.drivesTint, false)
        let noon = DaylightMath.resolve(sample: mock, at: date("2026-06-21T12:00:00Z"), calendar: utc)
        XCTAssertEqual(noon.phase, .day)

        let scripted = ScriptedSun(sun: EntitySnapshot(
            entityId: "sun.sun",
            state: "above_horizon",
            domain: "sun",
            elevation: 48
        ))
        let sample = await scripted.sunSample()
        XCTAssertEqual(sample?.elevation ?? -1, 48, accuracy: 0.001)
        XCTAssertEqual(sample?.drivesTint, true)
    }
}

private struct ScriptedSun: HomeStateProvider {
    var sun: EntitySnapshot

    func snapshot(for entityId: String) async throws -> EntitySnapshot {
        if entityId == DaylightMath.sunEntityID { return sun }
        throw HomeStateError.notConfigured
    }

    func perform(_ action: EntityAction, entityId: String) async throws -> EntitySnapshot {
        throw HomeStateError.notConfigured
    }

    func setBrightness(_ level: Double, entityId: String) async throws -> EntitySnapshot {
        throw HomeStateError.notConfigured
    }
}
