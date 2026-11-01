import XCTest
@testable import RoomScanCore

final class ScanDiffTests: XCTestCase {
    func testMoveAddAndRemove() {
        let previous = SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan
        var current = previous
        current.objects[0].center.x += 1
        let table = current.objects.remove(at: 1)
        current.objects.append(
            PlacedObject(
                id: UUID(),
                category: "chair",
                center: Vec3(x: 2, y: 0.45, z: 1),
                dimensions: Vec3(x: 0.45, y: 0.9, z: 0.45),
                yaw: 0
            )
        )
        let changes = ScanDiff.compare(previous: previous, current: current)
        let counts = ScanDiff.counts(changes)
        XCTAssertEqual(counts.added, 1)
        XCTAssertEqual(counts.removed, 1)
        XCTAssertEqual(counts.moved, 1)
        XCTAssertEqual(changes.first { $0.kind == .removed }?.object.id, table.id)
        guard case .moved(let distance) = changes.first(where: { $0.object.category == "refrigerator" })?.kind else {
            return XCTFail("Expected the refrigerator to move")
        }
        XCTAssertEqual(distance, 1, accuracy: 1e-9)
    }

    func testSmallShiftStaysUnchanged() {
        var current = SampleApartment.make().room(id: SampleApartment.kitchenID)!.floorPlan
        let previous = current
        current.objects[0].center.x += 0.05
        let changes = ScanDiff.compare(previous: previous, current: current)
        XCTAssertEqual(ScanDiff.counts(changes).moved, 0)
        XCTAssertTrue(changes.allSatisfy {
            if case .unchanged = $0.kind { return true }
            return false
        })
    }
}
