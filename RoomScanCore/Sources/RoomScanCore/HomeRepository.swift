import Foundation

public enum HomeRepositoryError: Error, Equatable, Sendable {
    case missingHome(UUID)
    case missingRoom(UUID)
    case unsafePath(String)
    case unreadable(String)
}

extension HomeRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingHome:
            return "That home is no longer on this device."
        case .missingRoom:
            return "That room is no longer on this device."
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
            for relative in room.mediaPaths {
                do {
                    try removeFile(homeId: homeId, relative: relative)
                } catch {
                    continue
                }
            }
            for relative in [room.assets.usdz, room.assets.capturedRoom].compactMap({ $0 }) {
                do {
                    try removeFile(homeId: homeId, relative: relative)
                } catch {
                    continue
                }
            }
            removeTextures(homeId: homeId, surfaceIDs: surfaceIDs(in: room.floorPlan))
        }
        let structureIncludedRoom = home.structure?.roomIds.contains(roomId) == true
        home.deleteRoom(id: roomId)
        if structureIncludedRoom {
            clearStructureFiles(homeId: homeId)
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
        placements: [RoomPlacement]? = nil,
        overlaps: [RoomOverlap]? = nil,
        shellWasRebuilt: Bool = false,
        now: Date = Date()
    ) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        let jsonRelative = "structure.captured.json"
        try write(capturedJSON, homeId: homeId, relative: jsonRelative)
        let usdzRelative = "structure.usdz"
        if shellWasRebuilt {
            try? removeFile(homeId: homeId, relative: usdzRelative)
        } else {
            try write(usdz, homeId: homeId, relative: usdzRelative)
        }
        home.structure = StructureLink(
            builtAt: now,
            roomIds: roomIds,
            coordinatesAreUnified: coordinatesAreUnified,
            usdz: shellWasRebuilt ? nil : usdzRelative,
            capturedStructure: jsonRelative,
            overviewFloorPlan: overview,
            placements: placements,
            overlaps: overlaps,
            shellWasRebuilt: shellWasRebuilt ? true : nil
        )
        return try save(home, now: now)
    }

    /// Replaces one room's measured plan and sidecars. The room id, name, and pins stay.
    /// A merged floor that included the room is cleared, because the shell no longer matches.
    @discardableResult
    public func replaceRoom(
        homeId: UUID,
        roomId: UUID,
        floorPlan: FloorPlan,
        capturedJSON: Data?,
        usdz: Data?,
        now: Date = Date()
    ) throws -> Home {
        guard var home = homes.first(where: { $0.id == homeId }) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        guard let index = home.rooms.firstIndex(where: { $0.id == roomId }) else {
            throw HomeRepositoryError.missingRoom(roomId)
        }
        var room = home.rooms[index]
        var assets = room.assets
        if let capturedJSON {
            let relative = assets.capturedRoom ?? "rooms/\(roomId.uuidString).captured.json"
            try write(capturedJSON, homeId: homeId, relative: relative)
            assets.capturedRoom = relative
        }
        if let usdz {
            let relative = assets.usdz ?? "rooms/\(roomId.uuidString).usdz"
            try write(usdz, homeId: homeId, relative: relative)
            assets.usdz = relative
        }
        room.floorPlan = floorPlan
        room.assets = assets
        let objectIDs = Set(floorPlan.objects.map(\.id))
        room.placedFurniture = room.placedFurniture.filter { item in
            guard let replaced = item.replacesObjectId else { return true }
            return objectIDs.contains(replaced)
        }
        home.rooms[index] = room
        if home.structure?.roomIds.contains(roomId) == true {
            clearStructureFiles(homeId: homeId)
            home.structure = nil
        }
        return try save(home, now: now)
    }

    public func textures(homeId: UUID) -> TextureLibrary {
        let relative = "textures.json"
        guard let url = try? fileURL(homeId: homeId, relative: relative),
              fileManager.fileExists(atPath: url.path) else {
            return .empty
        }
        do {
            let data = try Data(contentsOf: url)
            return try TextureLibrary.decode(data)
        } catch {
            return .empty
        }
    }

    public func saveTextures(_ library: TextureLibrary, homeId: UUID) throws {
        let data = try library.encode()
        try write(data, homeId: homeId, relative: "textures.json")
    }

    public func writeTextureImage(homeId: UUID, relative: String, data: Data) throws {
        try write(data, homeId: homeId, relative: relative)
    }

    public func writeMedia(homeId: UUID, relative: String, data: Data) throws {
        try write(data, homeId: homeId, relative: relative)
    }

    public func readMedia(homeId: UUID, relative: String) -> Data? {
        guard let url = try? fileURL(homeId: homeId, relative: relative),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    public func removeMedia(homeId: UUID, relative: String) {
        do {
            try removeFile(homeId: homeId, relative: relative)
        } catch {
            return
        }
    }

    public func removeTextureFile(homeId: UUID, relative: String) {
        do {
            try removeFile(homeId: homeId, relative: relative)
        } catch {
            return
        }
    }

    public func textureData(homeId: UUID, relative: String) -> Data? {
        guard let url = try? fileURL(homeId: homeId, relative: relative),
              fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try? Data(contentsOf: url)
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

    private func surfaceIDs(in plan: FloorPlan) -> Set<UUID> {
        Set(plan.walls.map(\.id) + plan.floors.map(\.id))
    }

    private func removeTextures(homeId: UUID, surfaceIDs: Set<UUID>) {
        guard !surfaceIDs.isEmpty else { return }
        let library = textures(homeId: homeId)
        let removed = library.photos.filter { surfaceIDs.contains($0.surfaceId) }
        guard !removed.isEmpty else { return }
        for photo in removed {
            do {
                try removeFile(homeId: homeId, relative: photo.imagePath)
            } catch {
                continue
            }
        }
        let kept = TextureLibrary(photos: library.photos.filter { !surfaceIDs.contains($0.surfaceId) })
        do {
            try saveTextures(kept, homeId: homeId)
        } catch {
            return
        }
    }

    private func clearStructureFiles(homeId: UUID) {
        for relative in ["structure.usdz", "structure.captured.json"] {
            do {
                try removeFile(homeId: homeId, relative: relative)
            } catch {
                continue
            }
        }
    }

    private func removeFile(homeId: UUID, relative: String) throws {
        let url = try fileURL(homeId: homeId, relative: relative)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
