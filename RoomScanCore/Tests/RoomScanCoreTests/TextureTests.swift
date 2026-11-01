import XCTest
@testable import RoomScanCore

final class TextureTests: XCTestCase {
    func testProjectWallCornersIntoTheScanCamera() {
        let pose = ScanCameraPose(
            columns: Mat4.identity.m,
            fx: 1000,
            fy: 1000,
            cx: 500,
            cy: 500,
            imageWidth: 1000,
            imageHeight: 1000,
            matchesScan: true
        )
        let wall = WallSegment(
            id: UUID(),
            start: Vec3(x: -0.5, y: 0, z: -2),
            end: Vec3(x: 0.5, y: 0, z: -2),
            height: 1,
            thickness: 0.1
        )
        let corners = TextureProjection.suggestCorners(wall: wall, pose: pose)
        let projected = try? XCTUnwrap(corners)
        XCTAssertEqual(projected?[0].x ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertEqual(projected?[0].y ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(projected?[1].x ?? -1, 0.75, accuracy: 1e-6)
        XCTAssertEqual(projected?[2].y ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(projected?[3].x ?? -1, 0.25, accuracy: 1e-6)
        let match = TextureProjection.bestTarget(in: FloorPlan(walls: [wall]), pose: pose)
        XCTAssertEqual(match, wall.id)
    }

    func testInverseTranslatesBack() {
        let translated = Mat4(m: [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            1, 2, 3, 1
        ])
        let inverse = translated.inverse()
        let point = inverse?.multiplyPoint(Vec3(x: 1, y: 2, z: 3))
        XCTAssertEqual(point?.x ?? 99, 0, accuracy: 1e-6)
        XCTAssertEqual(point?.y ?? 99, 0, accuracy: 1e-6)
        XCTAssertEqual(point?.z ?? 99, 0, accuracy: 1e-6)
    }

    func testAssignKeepsTheBestFramePerWall() {
        let pose = ScanCameraPose(
            columns: Mat4.identity.m,
            fx: 800,
            fy: 800,
            cx: 400,
            cy: 400,
            imageWidth: 800,
            imageHeight: 800,
            matchesScan: true
        )
        let wall = WallSegment(
            id: UUID(),
            start: Vec3(x: -0.4, y: 0, z: -2),
            end: Vec3(x: 0.4, y: 0, z: -2),
            height: 1,
            thickness: 0.1
        )
        let photo = UUID()
        let assigned = TextureProjection.assign(photos: [(photo, pose)], plan: FloorPlan(walls: [wall]))
        XCTAssertEqual(assigned[photo], wall.id)
        XCTAssertEqual(TextureProjection.bestTarget(in: FloorPlan(walls: [wall]), imageAspect: 0.8), wall.id)
    }

    func testTexturedGLBAndUSDZCarryTheJPEG() throws {
        let wall = WallSegment(
            id: UUID(),
            start: Vec3(x: 0, y: 0, z: 0),
            end: Vec3(x: 2, y: 0, z: 0),
            height: 2.4,
            thickness: 0.12
        )
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let texture = AppliedTexture(
            surfaceId: wall.id,
            jpeg: jpeg,
            corners: TextureProjection.fullFrameCorners()
        )
        let plan = FloorPlan(walls: [wall])
        let glb = FloorPlanGLB.data(for: plan, textures: [texture])
        XCTAssertEqual(glb.prefix(4), Data("glTF".utf8))
        let json = String(decoding: glb, as: UTF8.self)
        XCTAssertTrue(json.contains("image/jpeg") || json.contains("image\\/jpeg"))
        XCTAssertTrue(glb.contains(jpeg))
        let usdz = try XCTUnwrap(TexturedUSDZ.data(layers: [(plan, .zero)], textures: [texture]))
        XCTAssertEqual(usdz.prefix(2), Data("PK".utf8))
        XCTAssertTrue(usdz.contains(Data("#usda 1.0".utf8)))
        XCTAssertTrue(usdz.contains(jpeg))
    }

    func testTextureLibraryDoesNotChangeTheHomeDocument() throws {
        let home = SampleApartment.make()
        let before = try HomeLayoutDocument(home: home).encode()
        var library = TextureLibrary()
        library.photos.append(
            SurfaceTexture(
                id: UUID(),
                surfaceId: home.rooms[0].floorPlan.walls[0].id,
                kind: .wall,
                imagePath: "textures/example.jpg",
                corners: TextureProjection.fullFrameCorners()
            )
        )
        let encoded = try library.encode()
        let decoded = try TextureLibrary.decode(encoded)
        XCTAssertEqual(decoded.photos.count, 1)
        XCTAssertEqual(try HomeLayoutDocument(home: home).encode(), before)
    }
}
