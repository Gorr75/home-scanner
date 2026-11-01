import XCTest
@testable import RoomScanCore

final class HeatmapTests: XCTestCase {
    func testInverseDistanceBlendsNumericSensors() {
        XCTAssertNil(Heatmap.value(atX: 0, z: 0, samples: []))
        let only = [HeatSample(x: 1, z: 1, value: 21.5)]
        XCTAssertEqual(Heatmap.value(atX: 8, z: 8, samples: only), 21.5)
        let samples = [
            HeatSample(x: 0, z: 0, value: 10),
            HeatSample(x: 2, z: 0, value: 30)
        ]
        XCTAssertEqual(Heatmap.value(atX: 0, z: 0, samples: samples) ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(Heatmap.value(atX: 1, z: 0, samples: samples) ?? -1, 20, accuracy: 1e-6)
        let grid = Heatmap.grid(
            samples: samples,
            bounds: AABB(min: .zero, max: Vec3(x: 2, y: 0, z: 2)),
            columns: 2,
            rows: 2
        )
        XCTAssertEqual(grid.count, 2)
        XCTAssertEqual(grid[0].count, 2)
        XCTAssertNotNil(grid[0][0])
    }
}
