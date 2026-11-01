import XCTest
@testable import RoomScanCore

final class HomeExportTests: XCTestCase {
    func testSlugRejectsTraversalAndAcceptsUUID() {
        XCTAssertNil(HomeScannerSlug.accept("../etc"))
        XCTAssertNil(HomeScannerSlug.accept("rooms/kitchen"))
        XCTAssertNil(HomeScannerSlug.accept(""))
        XCTAssertEqual(HomeScannerSlug.accept(SampleApartment.kitchenID.uuidString), SampleApartment.kitchenID.uuidString)
    }

    func testPackagesMatchTheViewerFolders() throws {
        let home = SampleApartment.make()
        let usdz = Data("usdz-bytes".utf8)
        let packages = try HomeExport.packages(for: home, usdzFiles: ["structure.usdz": usdz])
        XCTAssertEqual(packages.map(\.slug), [
            home.id.uuidString,
            SampleApartment.kitchenID.uuidString,
            SampleApartment.livingRoomID.uuidString
        ])
        let homePackage = try XCTUnwrap(packages.first)
        XCTAssertEqual(homePackage.modelUSDZ, usdz)
        XCTAssertEqual(homePackage.files.map(\.filename), ["layout.json", "model.glb", "model.usdz"])
        XCTAssertEqual(homePackage.modelGLB.prefix(4), Data("glTF".utf8))

        let kitchen = packages[1]
        XCTAssertNil(kitchen.modelUSDZ)
        let document = try HomeLayoutDocument.decode(kitchen.layoutJSON)
        XCTAssertEqual(document.home.rooms.map(\.name), ["Kitchen"])
        XCTAssertEqual(document.home.pins.map(\.entityId), ["light.kitchen"])
        XCTAssertNil(document.home.structure)

        let zip = try HomeExport.zip(for: home, usdzFiles: ["structure.usdz": usdz])
        XCTAssertEqual(zip.prefix(2), Data("PK".utf8))
        let kitchenPath = "home_scanner/\(SampleApartment.kitchenID.uuidString)/layout.json"
        XCTAssertTrue(zip.contains(Data(kitchenPath.utf8)))
        XCTAssertTrue(zip.contains(Data("roomscan.home".utf8)))
    }

    func testGLBJSONDescribesAMesh() throws {
        let data = FloorPlanGLB.data(for: SampleApartment.make().rooms[0].floorPlan)
        XCTAssertEqual(data.prefix(4), Data("glTF".utf8))
        let version: UInt32 = readUInt32(data, offset: 4)
        XCTAssertEqual(version, 2)
        let jsonLength = Int(readUInt32(data, offset: 12))
        let jsonType = readUInt32(data, offset: 16)
        XCTAssertEqual(jsonType, 0x4E4F534A)
        let json = data.subdata(in: 20..<(20 + jsonLength))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let meshes = try XCTUnwrap(object["meshes"] as? [[String: Any]])
        let primitives = try XCTUnwrap(meshes.first?["primitives"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(primitives.count, 2)
        let accessors = try XCTUnwrap(object["accessors"] as? [[String: Any]])
        XCTAssertFalse(accessors.isEmpty)
        let empty = FloorPlanGLB.data(for: FloorPlan())
        XCTAssertEqual(empty.prefix(4), Data("glTF".utf8))
    }

    func testUploadPostsMultipartToTheRoomFolder() async throws {
        let layout = try HomeLayoutDocument(home: SampleApartment.make()).encode()
        let glb = FloorPlanGLB.data(for: FloorPlan())
        let slug = SampleApartment.kitchenID.uuidString
        let transport = ScriptedTransport { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.path.contains("/api/home_scanner/upload/\(slug)") == true)
            let body = try XCTUnwrap(request.httpBody)
            let text = String(decoding: body, as: UTF8.self)
            XCTAssertTrue(text.contains("filename=\"layout.json\""))
            XCTAssertTrue(text.contains("filename=\"model.glb\""))
            XCTAssertTrue(text.contains("roomscan.home"))
            let response = """
            {"ok":true,"room":"\(slug)","files":["layout.json","model.glb"],"local_path":"/local/home_scanner/\(slug)/"}
            """
            return HTTPResponse(statusCode: 200, data: Data(response.utf8))
        }
        let client = HomeAssistantClient(
            endpoint: HomeAssistantEndpoint(
                baseURL: try XCTUnwrap(URL(string: "http://homeassistant.local:8123")),
                token: "test-token"
            ),
            transport: transport
        )
        let receipt = try await client.upload(
            slug: slug,
            files: [.layout(layout), .modelGLB(glb)]
        )
        XCTAssertEqual(receipt.room, slug)
        XCTAssertEqual(receipt.files, ["layout.json", "model.glb"])
        XCTAssertEqual(receipt.localPath, "/local/home_scanner/\(slug)/")
        XCTAssertEqual(
            HomeAssistantLinks.companionDashboard?.absoluteString,
            "homeassistant://navigate/lovelace/home-scanner"
        )
    }

    private func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }
}
