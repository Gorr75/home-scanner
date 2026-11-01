import Foundation
import Observation
import RoomScanCore
import UIKit

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

    @discardableResult
    func addOutdoorZone(homeId: UUID, name: String, kind: OutdoorKind, mesh: TriangleMesh) throws -> Home {
        let home = try repository.addOutdoorZone(homeId: homeId, name: name, kind: kind, mesh: mesh)
        refresh()
        return home
    }

    func deleteOutdoorZone(homeId: UUID, zoneId: UUID) throws {
        try repository.deleteOutdoorZone(homeId: homeId, zoneId: zoneId)
        refresh()
    }

    @discardableResult
    func importUnderlay(
        homeId: UUID,
        image: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        widthMeters: Double,
        heightMeters: Double? = nil,
        yaw: Double? = nil,
        center: Vec3? = nil,
        georeference: Georeference?
    ) throws -> Home {
        let home = try repository.importUnderlay(
            homeId: homeId,
            image: image,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            widthMeters: widthMeters,
            heightMeters: heightMeters,
            yaw: yaw,
            center: center,
            georeference: georeference
        )
        refresh()
        return home
    }

    @discardableResult
    func importDroneOverlay(
        homeId: UUID,
        id: UUID = UUID(),
        image: Data,
        fileExtension: String,
        pixelWidth: Int,
        pixelHeight: Int,
        center: Vec3,
        yaw: Double,
        widthMeters: Double,
        heightMeters: Double,
        georeference: Georeference?,
        altitudeMeters: Double?,
        relativeAltitudeMeters: Double?,
        focalLengthMillimeters: Double?,
        focalLength35mm: Double?,
        headingDegrees: Double?,
        pitchDegrees: Double?,
        note: String?
    ) throws -> Home {
        let home = try repository.importDroneOverlay(
            homeId: homeId,
            id: id,
            image: image,
            fileExtension: fileExtension,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            center: center,
            yaw: yaw,
            widthMeters: widthMeters,
            heightMeters: heightMeters,
            georeference: georeference,
            altitudeMeters: altitudeMeters,
            relativeAltitudeMeters: relativeAltitudeMeters,
            focalLengthMillimeters: focalLengthMillimeters,
            focalLength35mm: focalLength35mm,
            headingDegrees: headingDegrees,
            pitchDegrees: pitchDegrees,
            note: note
        )
        refresh()
        return home
    }

    func deleteDroneOverlay(homeId: UUID, overlayId: UUID) throws {
        try repository.deleteDroneOverlay(homeId: homeId, overlayId: overlayId)
        refresh()
    }

    @discardableResult
    func setFacadeTexture(
        homeId: UUID,
        zoneId: UUID,
        wallId: UUID,
        imageRelativePath: String,
        pixelWidth: Int,
        pixelHeight: Int,
        corners: [UVPoint],
        imageData: Data? = nil
    ) throws -> Home {
        let home = try repository.setFacadeTexture(
            homeId: homeId,
            zoneId: zoneId,
            wallId: wallId,
            imageRelativePath: imageRelativePath,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            corners: corners,
            imageData: imageData
        )
        refresh()
        return home
    }

    func updateSite(homeId: UUID, _ body: (inout Site) -> Void) throws {
        try repository.updateSite(homeId: homeId, body)
        refresh()
    }

    @discardableResult
    func installSampleSite(
        homeId: UUID,
        image: Data?,
        pixelWidth: Int,
        pixelHeight: Int,
        facade: Data? = nil,
        facadePixelWidth: Int = 0,
        facadePixelHeight: Int = 0
    ) throws -> Home {
        let home = try repository.installSampleSite(
            homeId: homeId,
            image: image,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            facade: facade,
            facadePixelWidth: facadePixelWidth,
            facadePixelHeight: facadePixelHeight
        )
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

    static func siteImage() -> (data: Data, width: Int, height: Int)? {
        imageResource(name: "SampleSite")
    }

    static func facadeImage() -> (data: Data, width: Int, height: Int)? {
        imageResource(name: "SampleFacade")
    }

    private static func imageResource(name: String) -> (data: Data, width: Int, height: Int)? {
        let bundle = Bundle.main
        let urls = [
            bundle.url(forResource: name, withExtension: "png", subdirectory: "Resources"),
            bundle.url(forResource: name, withExtension: "png")
        ]
        for url in urls.compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { continue }
            let width = Int(image.size.width * image.scale)
            let height = Int(image.size.height * image.scale)
            return (data, max(width, 1), max(height, 1))
        }
        return nil
    }
}
