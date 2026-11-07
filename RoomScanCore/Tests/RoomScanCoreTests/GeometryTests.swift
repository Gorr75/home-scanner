import XCTest
@testable import RoomScanCore

final class GeometryTests: XCTestCase {
    func testWallRunsAlongFloorFromCenter() {
        let wall = FloorPlanGeometry.wall(
            center: Vec3(x: 2, y: 1.2, z: 1),
            axisX: Vec3(x: 2, y: 5, z: 0),
            width: 4,
            height: 2.4,
            thickness: 0.12,
            id: UUID()
        )
        XCTAssertEqual(wall.start.x, 0, accuracy: 1e-9)
        XCTAssertEqual(wall.end.x, 4, accuracy: 1e-9)
        XCTAssertEqual(wall.start.z, 1, accuracy: 1e-9)
        XCTAssertEqual(wall.end.z, 1, accuracy: 1e-9)
        XCTAssertEqual(wall.start.y, 0, accuracy: 1e-9)
        XCTAssertEqual(wall.height, 2.4, accuracy: 1e-9)
        XCTAssertEqual(wall.length, 4, accuracy: 1e-9)
    }

    func testYawAndOpeningEndpoints() {
        let opening = Opening(
            id: UUID(),
            kind: .door,
            center: Vec3(x: 3.6, y: 1.05, z: 1.6),
            width: 0.9,
            height: 2.1,
            yaw: .pi / 2
        )
        let ends = opening.widthEndpoints
        XCTAssertEqual(ends.start.x, 3.6, accuracy: 1e-9)
        XCTAssertEqual(ends.end.x, 3.6, accuracy: 1e-9)
        XCTAssertEqual(ends.start.z, 1.15, accuracy: 1e-9)
        XCTAssertEqual(ends.end.z, 2.05, accuracy: 1e-9)
        XCTAssertEqual(FloorPlanGeometry.yaw(axisX: Vec3(x: 0, y: 0, z: 1)), .pi / 2, accuracy: 1e-9)
    }

    func testRectangleCornersUseSurfaceAxes() {
        var transform = Transform.identity
        transform.translation = Vec3(x: 1, y: 0, z: 2)
        let corners = FloorPlanGeometry.rectangleCorners(width: 2, height: 4, transform: transform)
        XCTAssertEqual(corners[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(corners[0].y, -2, accuracy: 1e-9)
        XCTAssertEqual(corners[1].x, 2, accuracy: 1e-9)
        XCTAssertEqual(corners[2].y, 2, accuracy: 1e-9)
        XCTAssertEqual(corners[0].z, 2, accuracy: 1e-9)
    }

    func testFootprintRotatesLengthOntoZ() {
        let sofa = PlacedObject(
            id: UUID(),
            category: "sofa",
            center: Vec3(x: 6.6, y: 0.4, z: 2.8),
            dimensions: Vec3(x: 2.2, y: 0.85, z: 0.9),
            yaw: .pi / 2
        )
        let xs = sofa.footprint.map(\.x)
        let zs = sofa.footprint.map(\.z)
        XCTAssertEqual((xs.max() ?? 0) - (xs.min() ?? 0), 0.9, accuracy: 1e-9)
        XCTAssertEqual((zs.max() ?? 0) - (zs.min() ?? 0), 2.2, accuracy: 1e-9)
    }

    func testBoundsIncludeWallHeight() {
        let plan = FloorPlan(walls: [
            WallSegment(
                id: UUID(),
                start: Vec3(x: 0, y: 0, z: 0),
                end: Vec3(x: 3, y: 0, z: 0),
                height: 2.4,
                thickness: 0.1
            )
        ])
        let box = FloorPlanGeometry.bounds(of: plan)
        XCTAssertEqual(box.max.x, 3, accuracy: 1e-9)
        XCTAssertEqual(box.max.y, 2.4, accuracy: 1e-9)
        XCTAssertEqual(box.min.y, 0, accuracy: 1e-9)
    }

    func testUnmergedRoomsArePlacedSideBySide() {
        let left = room(id: SampleApartment.id(0x41), x: 0)
        let right = room(id: SampleApartment.id(0x42), x: 0)
        let frames = FloorPlanLayout.frames(rooms: [left, right], coordinatesAreUnified: false, gap: 0.8)
        XCTAssertEqual(frames[0].offset.x, 0, accuracy: 1e-9)
        XCTAssertEqual(frames[1].offset.x, 2.8, accuracy: 1e-9)
        let unified = FloorPlanLayout.frames(rooms: [left, right], coordinatesAreUnified: true)
        XCTAssertEqual(unified[0].offset, .zero)
        XCTAssertEqual(unified[1].offset, .zero)
    }

    func testPlanProjectorRoundTrip() {
        let projector = PlanProjector.fitting(
            bounds: AABB(min: Vec3(x: 1, y: 0, z: 2), max: Vec3(x: 5, y: 2, z: 6)),
            viewWidth: 400,
            viewHeight: 300,
            padding: 20
        ).withInteraction(scale: 2, offsetX: 12, offsetY: -4)
        let screen = projector.screen(x: 3, z: 4)
        let world = projector.world(screenX: screen.x, screenY: screen.y)
        XCTAssertEqual(world.x, 3, accuracy: 1e-6)
        XCTAssertEqual(world.z, 4, accuracy: 1e-6)
    }

    func testRoomNameIsDroppedWhenItDoesNotFit() {
        let wide = PlanLabelFit.Span(minX: 0, minY: 0, maxX: 120, maxY: 80)
        let narrow = PlanLabelFit.Span(minX: 160, minY: 0, maxX: 190, maxY: 80)
        let accepted = PlanLabelFit.accepted(
            rooms: [wide, narrow],
            labelSizes: [
                PlanLabelFit.LabelSize(width: 70, height: 14),
                PlanLabelFit.LabelSize(width: 70, height: 14)
            ]
        )
        XCTAssertEqual(accepted, [0])
    }

    func testRoomNameFitsExactlyInsideTheMargin() {
        let exact = PlanLabelFit.Span(minX: 0, minY: 0, maxX: 78, maxY: 22)
        let tight = PlanLabelFit.Span(minX: 100, minY: 0, maxX: 177, maxY: 22)
        let accepted = PlanLabelFit.accepted(
            rooms: [exact, tight],
            labelSizes: [
                PlanLabelFit.LabelSize(width: 70, height: 14),
                PlanLabelFit.LabelSize(width: 70, height: 14)
            ],
            margin: 4
        )
        XCTAssertEqual(accepted, [0])
    }

    func testSeparateRoomsKeepBothNames() {
        let left = PlanLabelFit.Span(minX: 0, minY: 0, maxX: 100, maxY: 80)
        let right = PlanLabelFit.Span(minX: 140, minY: 0, maxX: 260, maxY: 80)
        let accepted = PlanLabelFit.accepted(
            rooms: [left, right],
            labelSizes: [
                PlanLabelFit.LabelSize(width: 40, height: 14),
                PlanLabelFit.LabelSize(width: 50, height: 14)
            ]
        )
        XCTAssertEqual(accepted, [0, 1])
    }

    func testOverlappingRoomsKeepTheLargerName() {
        let small = PlanLabelFit.Span(minX: 40, minY: 40, maxX: 120, maxY: 100)
        let large = PlanLabelFit.Span(minX: 0, minY: 0, maxX: 200, maxY: 160)
        let accepted = PlanLabelFit.accepted(
            rooms: [small, large],
            labelSizes: [
                PlanLabelFit.LabelSize(width: 40, height: 14),
                PlanLabelFit.LabelSize(width: 60, height: 14)
            ]
        )
        XCTAssertEqual(accepted, [1])
    }

    func testTouchingLabelsNeedAGap() {
        let left = PlanLabelFit.Span(minX: 0, minY: 0, maxX: 100, maxY: 40)
        // Centered 40 pt labels: 30...70, then 73...113 (3 pt apart) or 74...114 (4 pt apart).
        let right = PlanLabelFit.Span(minX: 53, minY: 0, maxX: 133, maxY: 30)
        let sizes = [
            PlanLabelFit.LabelSize(width: 40, height: 12),
            PlanLabelFit.LabelSize(width: 40, height: 12)
        ]
        let crowded = PlanLabelFit.accepted(rooms: [left, right], labelSizes: sizes, gap: 4)
        XCTAssertEqual(crowded, [0])
        let cleared = PlanLabelFit.Span(minX: 54, minY: 0, maxX: 134, maxY: 30)
        let spaced = PlanLabelFit.accepted(rooms: [left, cleared], labelSizes: sizes, gap: 4)
        XCTAssertEqual(spaced, [0, 1])
    }

    func testRelativePathStaysInsideHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertTrue(RelativePath.isSafe("rooms/kitchen.usdz"))
        XCTAssertFalse(RelativePath.isSafe("../secret"))
        XCTAssertFalse(RelativePath.isSafe("/etc/passwd"))
        XCTAssertFalse(RelativePath.isSafe(""))
        XCTAssertFalse(RelativePath.isSafe("rooms/../../x"))
        let resolved = try XCTUnwrap(RelativePath.resolve(homeDirectory: home, relative: "rooms/kitchen.usdz"))
        XCTAssertTrue(resolved.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path))
        XCTAssertNil(RelativePath.resolve(homeDirectory: home, relative: "../outside"))
    }

    private func room(id: UUID, x: Double) -> Room {
        Room(
            id: id,
            name: "Room",
            createdAt: SampleApartment.createdAt,
            floorPlan: FloorPlan(walls: [
                WallSegment(
                    id: UUID(),
                    start: Vec3(x: x, y: 0, z: 0),
                    end: Vec3(x: x + 2, y: 0, z: 0),
                    height: 2.4,
                    thickness: 0.1
                )
            ])
        )
    }
}

private extension PlanProjector {
    func withInteraction(scale: Double, offsetX: Double, offsetY: Double) -> PlanProjector {
        var copy = self
        copy.userScale = scale
        copy.userOffsetX = offsetX
        copy.userOffsetY = offsetY
        return copy
    }
}
