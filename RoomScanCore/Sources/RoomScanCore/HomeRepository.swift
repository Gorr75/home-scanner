import Foundation

public enum HomeRepositoryError: Error, Equatable, Sendable {
    case missingHome(UUID)
    case unsafePath(String)
    case unreadable(String)
}

extension HomeRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingHome:
            return "That home is no longer on this device."
        case .unsafePath(let path):
            return "Refused to use the path \(path)."
        case .unreadable(let name):
            return "Could not read \(name)."
        }
    }
}

/// On-device homes. Each home is a folder of `home.json` plus USDZ and CapturedRoom sidecars.
public final class HomeRepository {
    public let root: URL
    public private(set) var homes: [Home] = []
    public private(set) var warnings: [String] = []

    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try reload()
    }

    public func reload() throws {
        let entries = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var loaded: [Home] = []
        var notes: [String] = []
        for entry in entries {
            guard isDirectory(entry) else { continue }
            let manifest = entry.appendingPathComponent("home.json")
            guard fileManager.fileExists(atPath: manifest.path) else { continue }
            do {
                let data = try Data(contentsOf: manifest)
                let document = try HomeLayoutDocument.decode(data)
                loaded.append(document.home)
            } catch {
                notes.append("Skipped \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        homes = loaded.sorted { $0.updatedAt > $1.updatedAt }
        warnings = notes
    }

    @discardableResult
    public func createHome(named name: String, now: Date = Date()) throws -> Home {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let home = Home(
            id: UUID(),
            name: trimmed.isEmpty ? "Untitled home" : trimmed,
            createdAt: now,
            updatedAt: now,
            rooms: [],
            pins: [],
            structure: nil
        )
        return try save(home, touch: false)
    }

    @discardableResult
    public func save(_ home: Home, touch: Bool = true, now: Date = Date()) throws -> Home {
        var stored = home
        if touch {
            stored.updatedAt = now
        }
        let folder = folderURL(for: stored.id)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try HomeLayoutDocument(home: stored).encode()
        try data.write(to: folder.appendingPathComponent("home.json"), options: .atomic)
        if let index = homes.firstIndex(where: { $0.id == stored.id }) {
            homes[index] = stored
        } else {
            homes.append(stored)
        }
        homes.sort { $0.updatedAt > $1.updatedAt }
        return stored
    }

    public func deleteHome(id: UUID) throws {
        let folder = folderURL(for: id)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
        homes.removeAll { $0.id == id }
    }

    public func fileURL(homeId: UUID, relative: String) throws -> URL {
        guard let url = RelativePath.resolve(homeDirectory: folderURL(for: homeId), relative: relative) else {
            throw HomeRepositoryError.unsafePath(relative)
        }
        return url
    }

    @discardableResult
    public func addRoom(
        homeId: UUID,
        name: String,
        floorPlan: FloorPlan,
        capturedJSON: Data?,
        usdz: Data?,
        now: Date = Date()
    ) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        let roomId = UUID()
        var assets = RoomAssets()
        if let capturedJSON {
            let relative = "rooms/\(roomId.uuidString).captured.json"
            try write(capturedJSON, homeId: homeId, relative: relative)
            assets.capturedRoom = relative
        }
        if let usdz {
            let relative = "rooms/\(roomId.uuidString).usdz"
            try write(usdz, homeId: homeId, relative: relative)
            assets.usdz = relative
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = Room(
            id: roomId,
            name: trimmed.isEmpty ? "Room" : trimmed,
            createdAt: now,
            floorPlan: floorPlan,
            assets: assets
        )
        home.rooms.append(room)
        return try save(home, now: now)
    }

    @discardableResult
    public func deleteRoom(homeId: UUID, roomId: UUID, now: Date = Date()) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        if let room = home.room(id: roomId) {
            for relative in [room.assets.usdz, room.assets.capturedRoom].compactMap({ $0 }) {
                try? removeFile(homeId: homeId, relative: relative)
            }
        }
        let structureIncludedRoom = home.structure?.roomIds.contains(roomId) == true
        home.deleteRoom(id: roomId)
        if structureIncludedRoom {
            try? removeFile(homeId: homeId, relative: "structure.usdz")
            try? removeFile(homeId: homeId, relative: "structure.captured.json")
            home.structure = nil
        }
        return try save(home, now: now)
    }

    @discardableResult
    public func attachStructure(
        homeId: UUID,
        capturedJSON: Data,
        usdz: Data,
        overview: FloorPlan,
        roomIds: [UUID],
        coordinatesAreUnified: Bool = false,
        now: Date = Date()
    ) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        let jsonRelative = "structure.captured.json"
        let usdzRelative = "structure.usdz"
        try write(capturedJSON, homeId: homeId, relative: jsonRelative)
        try write(usdz, homeId: homeId, relative: usdzRelative)
        home.structure = StructureLink(
            builtAt: now,
            roomIds: roomIds,
            coordinatesAreUnified: coordinatesAreUnified,
            usdz: usdzRelative,
            capturedStructure: jsonRelative,
            overviewFloorPlan: overview
        )
        return try save(home, now: now)
    }

    public func capturedPayloads(in home: Home) throws -> [(room: Room, data: Data)] {
        var payloads: [(Room, Data)] = []
        for room in home.rooms {
            guard let relative = room.assets.capturedRoom else { continue }
            let url = try fileURL(homeId: home.id, relative: relative)
            guard fileManager.fileExists(atPath: url.path) else {
                throw HomeRepositoryError.unreadable(room.name)
            }
            payloads.append((room, try Data(contentsOf: url)))
        }
        return payloads
    }

    /// Installs the bundled sample once. A second call returns the copy already on disk.
    @discardableResult
    public func installSampleApartment(usdz: Data?) throws -> Home {
        if let existing = homes.first(where: { $0.id == SampleApartment.homeID }) {
            if let usdz, let relative = existing.structure?.usdz {
                let url = try fileURL(homeId: existing.id, relative: relative)
                if !fileManager.fileExists(atPath: url.path) {
                    try write(usdz, homeId: existing.id, relative: relative)
                }
            }
            return existing
        }
        var home = SampleApartment.make()
        if usdz == nil {
            home.structure?.usdz = nil
        }
        let stored = try save(home, touch: false)
        if let usdz, let relative = stored.structure?.usdz {
            try write(usdz, homeId: stored.id, relative: relative)
        }
        return homes.first(where: { $0.id == stored.id }) ?? stored
    }

    @discardableResult
    public func addOutdoorZone(
        homeId: UUID,
        name: String,
        kind: OutdoorKind,
        mesh: TriangleMesh,
        now: Date = Date()
    ) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        let clipped = MeshRange.clipped(mesh)
        let shape = MeshRange.footprint(clipped)
        let zoneID = UUID()
        let relative = "outdoor/\(zoneID.uuidString).obj"
        let text = MeshOBJ.encode(clipped)
        guard let data = text.data(using: .utf8) else {
            throw HomeRepositoryError.unreadable(name)
        }
        try write(data, homeId: homeId, relative: relative)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = OutdoorZone(
            id: zoneID,
            name: trimmed.isEmpty ? kind.label : trimmed,
            kind: kind,
            createdAt: now,
            footprint: shape.corners,
            height: shape.height,
            meshVertexCount: clipped.vertices.count,
            assets: OutdoorAssets(obj: relative)
        )
        home.outdoorZones.append(zone)
        return try save(home, now: now)
    }

    @discardableResult
    public func deleteOutdoorZone(homeId: UUID, zoneId: UUID, now: Date = Date()) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        if let zone = home.outdoorZone(id: zoneId), let relative = zone.assets.obj {
            try? removeFile(homeId: homeId, relative: relative)
        }
        home.deleteOutdoorZone(id: zoneId)
        return try save(home, now: now)
    }

    @discardableResult
    public func importUnderlay(
        homeId: UUID,
        image: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        widthMeters: Double,
        georeference: Georeference? = nil,
        now: Date = Date()
    ) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        let relative = "site/underlay.jpg"
        try write(image, homeId: homeId, relative: relative)
        let safeWidth = max(widthMeters, 0.1)
        let aspect = pixelWidth > 0 ? Double(pixelHeight) / Double(pixelWidth) : 1
        var site = home.site ?? Site()
        let previous = site.underlay
        site.underlay = SiteUnderlay(
            image: relative,
            pixelWidth: max(pixelWidth, 1),
            pixelHeight: max(pixelHeight, 1),
            widthMeters: safeWidth,
            heightMeters: safeWidth * aspect,
            center: previous?.center ?? .zero,
            yaw: previous?.yaw ?? 0,
            georeference: georeference ?? previous?.georeference
        )
        home.site = site
        return try save(home, now: now)
    }

    @discardableResult
    public func updateSite(homeId: UUID, now: Date = Date(), _ body: (inout Site) -> Void) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        var site = home.site ?? Site()
        body(&site)
        home.site = site
        return try save(home, now: now)
    }

    /// Adds the bundled shed mesh and, when image bytes are provided, a site underlay.
    /// Existing rooms are placed on the site if they are not already placed.
    @discardableResult
    public func installSampleSite(homeId: UUID, image: Data?, pixelWidth: Int, pixelHeight: Int, now: Date = Date()) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        if home.outdoorZone(id: SampleSite.patioID) == nil {
            let mesh = SampleSite.shedMesh()
            let relative = "outdoor/\(SampleSite.patioID.uuidString).obj"
            guard let data = MeshOBJ.encode(mesh).data(using: .utf8) else {
                throw HomeRepositoryError.unreadable("shed")
            }
            try write(data, homeId: homeId, relative: relative)
            var zone = SampleSite.shedZone(createdAt: now)
            zone.assets.obj = relative
            home.outdoorZones.append(zone)
        }
        if let image {
            let relative = "site/underlay.jpg"
            try write(image, homeId: homeId, relative: relative)
            let width = 40.0
            let aspect = pixelWidth > 0 ? Double(pixelHeight) / Double(pixelWidth) : 1
            var site = home.site ?? Site()
            site.underlay = SiteUnderlay(
                image: relative,
                pixelWidth: max(pixelWidth, 1),
                pixelHeight: max(pixelHeight, 1),
                widthMeters: width,
                heightMeters: width * aspect,
                georeference: Georeference(latitude: 59.3293, longitude: 18.0686, headingDegrees: 12)
            )
            home.site = site
        }
        if home.site?.placements.isEmpty != false {
            var site = home.site ?? Site()
            site.placements = SiteLayout.defaultPlacements(rooms: home.rooms, zones: home.outdoorZones)
            home.site = site
        }
        return try save(home, now: now)
    }

    public func exportLayoutFile(for home: Home) throws -> URL {
        let data = try HomeLayoutDocument(home: home).encode()
        var name = home.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Home" }
        name = name.replacingOccurrences(of: "/", with: "-")
        let url = fileManager.temporaryDirectory.appendingPathComponent("\(name).roomscan.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func isDirectory(_ url: URL) -> Bool {
        if let value = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return value
        }
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func folderURL(for homeId: UUID) -> URL {
        root.appendingPathComponent(homeId.uuidString, isDirectory: true)
    }

    private func write(_ data: Data, homeId: UUID, relative: String) throws {
        let url = try fileURL(homeId: homeId, relative: relative)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func removeFile(homeId: UUID, relative: String) throws {
        let url = try fileURL(homeId: homeId, relative: relative)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
