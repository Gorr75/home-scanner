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
            .appendingPathComponent("RoomScanHomes", isDirectory: true)
        guard let repository = try? HomeRepository(root: emergency) else {
            fatalError("RoomScan could not create a folder for saved homes.")
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
