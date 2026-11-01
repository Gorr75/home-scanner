import XCTest
@testable import RoomScanCore

final class ObjectLabelTests: XCTestCase {
    func testKnownCategoriesAndDimensions() {
        let fridge = SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan.objects[0]
        XCTAssertEqual(fridge.category, "refrigerator")
        XCTAssertEqual(ObjectLabels.title(for: fridge.category), "Refrigerator")
        XCTAssertEqual(ObjectLabels.size(fridge), "0.70 × 1.80 × 0.70 m")
        XCTAssertEqual(ObjectLabels.footprint(fridge), "0.70 × 0.70 m")
        XCTAssertEqual(ObjectLabels.title(for: "washer_dryer"), "Washer / dryer")
        XCTAssertEqual(ObjectLabels.title(for: "plant_stand"), "Plant Stand")
        XCTAssertEqual(ObjectLabels.title(for: "unknown"), "Object")
    }
}
