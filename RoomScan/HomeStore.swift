import Foundation
import Observation
import RoomScanCore

@MainActor
@Observable
final class HomeStore {
    private let repository: HomeRepository
    private(set) var homes: [Home]
    private(set) var warnings: [String]
    var loadError: String?

    init(repository: HomeRepository) {
        self.repository = repository
        homes = repository.homes
        warnings = repository.warnings
    }

    convenience init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let root = documents.appendingPathComponent("Homes", isDirectory: true)
        if let repository = try? HomeRepository(root: root) {
            self.init(repository: repository)
            return
        }
        let emergency = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeScannerHomes", isDirectory: true)
        guard let repository = try? HomeRepository(root: emergency) else {
            fatalError("Home Scanner could not create a folder for saved homes.")
        }
        self.init(repository: repository)
        loadError = "Homes could not be stored in Documents, so this session is using a temporary folder."
    }

    func home(id: UUID) -> Home? {
        homes.first { $0.id == id }
    }

    @discardableResult
    func createHome(named name: String) throws -> Home {
        let home = try repository.createHome(named: name)
        refresh()
        return home
    }

    @discardableResult
    func save(_ home: Home) throws -> Home {
        let stored = try repository.save(home)
        refresh()
        return stored
    }

    func update(homeId: UUID, _ body: (inout Home) -> Void) throws {
        guard var home = home(id: homeId) else {
            throw HomeRepositoryError.missingHome(homeId)
        }
        body(&home)
        try save(home)
    }

    func deleteHome(id: UUID) throws {
        try repository.deleteHome(id: id)
        refresh()
    }

    func deleteRoom(homeId: UUID, roomId: UUID) throws {
        try repository.deleteRoom(homeId: homeId, roomId: roomId)
        refresh()
    }

    @discardableResult
    func addCapturedRoom(
        homeId: UUID,
        name: String,
        floorPlan: FloorPlan,
        capturedJSON: Data,
        usdz: Data
    ) throws -> Home {
        let home = try repository.addRoom(
            homeId: homeId,
            name: name,
            floorPlan: floorPlan,
            capturedJSON: capturedJSON,
            usdz: usdz
        )
        refresh()
        return home
    }

    @discardableResult
    func replaceCapturedRoom(
        homeId: UUID,
        roomId: UUID,
        floorPlan: FloorPlan,
        capturedJSON: Data,
        usdz: Data
    ) throws -> Home {
        let home = try repository.replaceRoom(
            homeId: homeId,
            roomId: roomId,
            floorPlan: floorPlan,
            capturedJSON: capturedJSON,
            usdz: usdz
        )
        refresh()
        return home
    }

    @discardableResult
    func attachStructure(
        homeId: UUID,
        capturedJSON: Data,
        usdz: Data,
        overview: FloorPlan,
        roomIds: [UUID]
    ) throws -> Home {
        let home = try repository.attachStructure(
            homeId: homeId,
            capturedJSON: capturedJSON,
            usdz: usdz,
            overview: overview,
            roomIds: roomIds,
            coordinatesAreUnified: false
        )
        refresh()
        return home
    }

    @discardableResult
    func installSample(usdz: Data?) throws -> Home {
        let home = try repository.installSampleApartment(usdz: usdz)
        refresh()
        return home
    }

    func fileURL(homeId: UUID, relative: String) throws -> URL {
        try repository.fileURL(homeId: homeId, relative: relative)
    }

    func capturedPayloads(in home: Home) throws -> [(room: Room, data: Data)] {
        try repository.capturedPayloads(in: home)
    }

    func exportLayout(for home: Home) throws -> URL {
        try repository.exportLayoutFile(for: home)
    }

    func existingFile(homeId: UUID, relative: String?) -> URL? {
        guard let relative, let url = try? fileURL(homeId: homeId, relative: relative) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func textureLibrary(homeId: UUID) -> TextureLibrary {
        repository.textures(homeId: homeId)
    }

    func saveTextures(_ library: TextureLibrary, homeId: UUID) throws {
        try repository.saveTextures(library, homeId: homeId)
    }

    func writeTextureImage(homeId: UUID, relative: String, data: Data) throws {
        try repository.writeTextureImage(homeId: homeId, relative: relative, data: data)
    }

    func removeTextureFile(homeId: UUID, relative: String) {
        repository.removeTextureFile(homeId: homeId, relative: relative)
    }

    func installScanFrames(
        _ frames: [(id: UUID, jpeg: Data, pose: ScanCameraPose)],
        plan: FloorPlan,
        homeId: UUID
    ) throws {
        let assigned = TextureProjection.assign(photos: frames.map { ($0.id, $0.pose) }, plan: plan)
        guard !assigned.isEmpty else { return }
        var library = repository.textures(homeId: homeId)
        for frame in frames {
            guard let surfaceId = assigned[frame.id],
                  let wall = plan.walls.first(where: { $0.id == surfaceId }),
                  let corners = TextureProjection.suggestCorners(wall: wall, pose: frame.pose) else {
                continue
            }
            let relative = "textures/\(frame.id.uuidString).jpg"
            try writeTextureImage(homeId: homeId, relative: relative, data: frame.jpeg)
            library.photos.removeAll { $0.surfaceId == surfaceId }
            library.photos.append(
                SurfaceTexture(
                    id: frame.id,
                    surfaceId: surfaceId,
                    kind: .wall,
                    imagePath: relative,
                    corners: corners,
                    pose: frame.pose
                )
            )
        }
        try saveTextures(library, homeId: homeId)
    }

    func textureData(homeId: UUID, relative: String) -> Data? {
        repository.textureData(homeId: homeId, relative: relative)
    }

    func appliedTextures(in home: Home) -> [AppliedTexture] {
        repository.textures(homeId: home.id).photos.compactMap { photo in
            guard photo.corners.count == 4, let jpeg = repository.textureData(homeId: home.id, relative: photo.imagePath) else {
                return nil
            }
            return AppliedTexture(surfaceId: photo.surfaceId, jpeg: jpeg, corners: photo.corners)
        }
    }

    func usdzFiles(in home: Home) -> [String: Data] {
        var files: [String: Data] = [:]
        let paths = home.rooms.compactMap(\.assets.usdz) + [home.structure?.usdz].compactMap { $0 }
        for relative in paths {
            guard let url = existingFile(homeId: home.id, relative: relative) else { continue }
            do {
                files[relative] = try Data(contentsOf: url)
            } catch {
                continue
            }
        }
        return files
    }

    func structureModelURL(in home: Home) -> URL? {
        existingFile(homeId: home.id, relative: home.structure?.usdz)
    }

    func roomModelURL(in home: Home, room: Room) -> URL? {
        existingFile(homeId: home.id, relative: room.assets.usdz)
    }

    private func refresh() {
        homes = repository.homes
        warnings = repository.warnings
    }
}

enum SampleBundle {
    static func usdzData() -> Data? {
        let bundle = Bundle.main
        let urls = [
            bundle.url(forResource: "SampleApartment", withExtension: "usdz", subdirectory: "Resources"),
            bundle.url(forResource: "SampleApartment", withExtension: "usdz")
        ]
        for url in urls.compactMap({ $0 }) {
            if let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }
}
