import XCTest
@testable import RoomScanCore

final class MeasurementTests: XCTestCase {
    func testSampleKitchenAreaWallsAndDoor() {
        let kitchen = SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan
        let summary = MeasurementMath.summarize(kitchen)
        XCTAssertEqual(summary.floorArea, 11.52, accuracy: 1e-9)
        XCTAssertEqual(summary.wallLengths.reduce(0, +), 13.6, accuracy: 1e-9)
        XCTAssertEqual(summary.doorWidths, [0.9])
        XCTAssertTrue(summary.windowWidths.isEmpty)
        let living = MeasurementMath.summarize(SampleApartment.make().room(id: SampleApartment.livingRoomID)!.floorPlan)
        XCTAssertEqual(living.floorArea, (8.8 - 3.6) * 4, accuracy: 1e-6)
        XCTAssertEqual(living.windowWidths, [1.8])
        XCTAssertEqual(MeasurementMath.squareMeters(11.52), "11.52 m²")
    }
}
