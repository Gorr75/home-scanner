import Foundation

public enum HomeScannerSlug {
    /// Folder name used under `/config/www/home_scanner/` and inside the zip.
    /// Accepts a UUID string. Rejects empty names, slashes, and `..`.
    public static func accept(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 80 else { return nil }
        guard let first = raw.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }
}

public struct HomeScannerFile: Equatable, Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String, data: Data) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }

    public static func layout(_ data: Data) -> HomeScannerFile {
        HomeScannerFile(filename: "layout.json", mimeType: "application/json", data: data)
    }

    public static func modelGLB(_ data: Data) -> HomeScannerFile {
        HomeScannerFile(filename: "model.glb", mimeType: "model/gltf-binary", data: data)
    }

    public static func modelUSDZ(_ data: Data) -> HomeScannerFile {
        HomeScannerFile(filename: "model.usdz", mimeType: "model/vnd.usdz+zip", data: data)
    }
}

public struct HomeScannerUploadReceipt: Equatable, Sendable {
    public var room: String
    public var files: [String]
    public var localPath: String

    public init(room: String, files: [String], localPath: String) {
        self.room = room
        self.files = files
        self.localPath = localPath
    }
}

public enum HomeAssistantLinks {
    /// Opens the default Lovelace view whose path is `home-scanner`.
    public static let companionDashboard = URL(string: "homeassistant://navigate/lovelace/home-scanner")

    public static func localPath(slug: String) -> String {
        "/local/home_scanner/\(slug)/"
    }
}

/// One folder the card can read: `layout.json`, `model.glb`, and an optional RoomPlan `model.usdz`.
public struct ScanPackage: Equatable, Sendable {
    public var slug: String
    public var title: String
    public var layoutJSON: Data
    public var modelGLB: Data
    public var modelUSDZ: Data?
    /// Photo plates for a one-room folder. Empty for a whole-home package and for older uploads.
    public var plates: [HomeScannerFile]

    public init(
        slug: String,
        title: String,
        layoutJSON: Data,
        modelGLB: Data,
        modelUSDZ: Data? = nil,
        plates: [HomeScannerFile] = []
    ) {
        self.slug = slug
        self.title = title
        self.layoutJSON = layoutJSON
        self.modelGLB = modelGLB
        self.modelUSDZ = modelUSDZ
        self.plates = plates
    }

    public var files: [HomeScannerFile] {
        var items = [HomeScannerFile.layout(layoutJSON), .modelGLB(modelGLB)]
        if let modelUSDZ {
            items.append(.modelUSDZ(modelUSDZ))
        }
        items.append(contentsOf: plates)
        return items
    }

    public func withPlates(_ plates: [HomeScannerFile]) -> ScanPackage {
        var copy = self
        copy.plates = plates
        return copy
    }

    public var zipEntries: [(path: String, data: Data)] {
        files.map { file in
            ("home_scanner/\(slug)/\(file.filename)", file.data)
        }
    }
}

public enum HomeExport {
    /// The home folder uses the home id. Each room folder uses the room id.
    /// Pass USDZ bytes keyed by the relative path stored on the room or structure.
    public static func packages(
        for home: Home,
        usdzFiles: [String: Data] = [:],
        textures: [AppliedTexture] = []
    ) throws -> [ScanPackage] {
        var packages: [ScanPackage] = []
        packages.append(try homePackage(home, usdzFiles: usdzFiles, textures: textures))
        for room in home.rooms {
            let ids = surfaceIDs(in: room.floorPlan)
            let roomTextures = textures.filter { ids.contains($0.surfaceId) }
            packages.append(try roomPackage(home, room: room, usdzFiles: usdzFiles, textures: roomTextures))
        }
        return packages
    }

    public static func zip(
        for home: Home,
        usdzFiles: [String: Data] = [:],
        textures: [AppliedTexture] = []
    ) throws -> Data {
        let entries = try packages(for: home, usdzFiles: usdzFiles, textures: textures).flatMap(\.zipEntries)
        return StoredZip.archive(files: entries)
    }

    private static func homePackage(_ home: Home, usdzFiles: [String: Data], textures: [AppliedTexture]) throws -> ScanPackage {
        let slug = try requireSlug(home.id.uuidString)
        let frames = FloorPlanLayout.frames(rooms: home.rooms, coordinatesAreUnified: home.coordinatesAreUnified)
        let layers = home.rooms.map { room in
            (room.floorPlan, frames.first { $0.roomId == room.id }?.offset ?? .zero)
        }
        let glb: Data
        let usdz: Data?
        // Furniture, flooring, and a stacked dollhouse are drawn from the room plans,
        // so a wall edit is in the same model. A merged shell is used only while each
        // scan still has its own origin and nobody has furnished the home.
        if HomeFurnishing.needsExport(home) {
            let drawn = HomeFurnishing.layers(for: home, stacked: FloorStack.hasStackedFloors(home))
            glb = FloorPlanGLB.data(for: drawn, textures: textures)
            usdz = FurnishedUSDZ.data(layers: drawn)
                ?? home.structure?.usdz.flatMap { usdzFiles[$0] }
        } else if textures.isEmpty,
                  !home.coordinatesAreUnified,
                  let overview = home.structure?.overviewFloorPlan,
                  !overview.isEmpty {
            glb = FloorPlanGLB.data(for: overview)
            usdz = home.structure?.usdz.flatMap { usdzFiles[$0] }
        } else if textures.isEmpty {
            glb = FloorPlanGLB.data(for: layers)
            usdz = home.structure?.usdz.flatMap { usdzFiles[$0] }
        } else {
            glb = FloorPlanGLB.data(for: layers, textures: textures)
            usdz = TexturedUSDZ.data(layers: layers, textures: textures)
                ?? home.structure?.usdz.flatMap { usdzFiles[$0] }
        }
        return ScanPackage(
            slug: slug,
            title: home.name,
            layoutJSON: try HomeLayoutDocument(home: home).encode(),
            modelGLB: glb,
            modelUSDZ: usdz
        )
    }

    private static func roomPackage(_ home: Home, room: Room, usdzFiles: [String: Data], textures: [AppliedTexture]) throws -> ScanPackage {
        let slug = try requireSlug(room.id.uuidString)
        let single = Home(
            id: home.id,
            name: home.name,
            createdAt: home.createdAt,
            updatedAt: home.updatedAt,
            rooms: [room],
            pins: home.pins(in: room.id),
            structure: nil
        )
        let layers = [(room.floorPlan, Vec3.zero)]
        let glb: Data
        let usdz: Data?
        if HomeFurnishing.needsExport(room) {
            let drawn = [HomeFurnishing.layer(for: room)]
            glb = FloorPlanGLB.data(for: drawn, textures: textures)
            usdz = FurnishedUSDZ.data(layers: drawn)
                ?? room.assets.usdz.flatMap { usdzFiles[$0] }
        } else if textures.isEmpty {
            glb = FloorPlanGLB.data(for: room.floorPlan, textures: textures)
            usdz = room.assets.usdz.flatMap { usdzFiles[$0] }
        } else {
            glb = FloorPlanGLB.data(for: room.floorPlan, textures: textures)
            usdz = TexturedUSDZ.data(layers: layers, textures: textures)
                ?? room.assets.usdz.flatMap { usdzFiles[$0] }
        }
        return ScanPackage(
            slug: slug,
            title: room.name,
            layoutJSON: try HomeLayoutDocument(home: single).encode(),
            modelGLB: glb,
            modelUSDZ: usdz
        )
    }

    private static func surfaceIDs(in plan: FloorPlan) -> Set<UUID> {
        Set(plan.walls.map(\.id) + plan.floors.map(\.id))
    }

    private static func requireSlug(_ raw: String) throws -> String {
        guard let slug = HomeScannerSlug.accept(raw) else {
            throw HomeLayoutError.unknownFormat(raw)
        }
        return slug
    }
}

public enum MultipartForm {
    public static func body(files: [HomeScannerFile], boundary: String) -> Data {
        var data = Data()
        for file in files {
            data.append(utf8("--\(boundary)\r\n"))
            data.append(utf8("Content-Disposition: form-data; name=\"file\"; filename=\"\(file.filename)\"\r\n"))
            data.append(utf8("Content-Type: \(file.mimeType)\r\n\r\n"))
            data.append(file.data)
            data.append(utf8("\r\n"))
        }
        data.append(utf8("--\(boundary)--\r\n"))
        return data
    }

    private static func utf8(_ text: String) -> Data {
        Data(text.utf8)
    }
}

extension HomeAssistantDecoding {
    static func uploadReceipt(from data: Data, fallbackSlug: String) throws -> HomeScannerUploadReceipt {
        let object = try decodeJSON(data)
        guard let dictionary = object as? [String: Any] else {
            throw HomeAssistantClientError.malformedResponse
        }
        let room = dictionary["room"] as? String ?? fallbackSlug
        let files = dictionary["files"] as? [String] ?? []
        let localPath = dictionary["local_path"] as? String ?? HomeAssistantLinks.localPath(slug: room)
        return HomeScannerUploadReceipt(room: room, files: files, localPath: localPath)
    }

    private static func decodeJSON(_ data: Data) throws -> Any {
        guard !data.isEmpty else { throw HomeAssistantClientError.malformedResponse }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HomeAssistantClientError.malformedResponse
        }
    }
}
