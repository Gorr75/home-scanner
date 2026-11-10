import Foundation

/// Pixel size of a photo plate. The card sizes its stage to this aspect ratio.
public enum PlateLayout {
    public static let width = 960
    public static let height = 540
    public static var aspect: Double { Double(width) / Double(height) }
}

/// Which pre-rendered set the card shows. Night is the daylight phase `night`; every other phase uses day.
public enum PlateVariant: String, Codable, Equatable, Sendable {
    case day
    case night

    public static func forPhase(_ phase: DaylightPhase) -> PlateVariant {
        phase == .night ? .night : .day
    }
}

/// Filenames under `/local/home_scanner/<id>/`. The integration accepts these and rejects anything else.
public enum PlatePaths {
    public static let manifest = "plates/manifest.json"

    public static func base(_ variant: PlateVariant) -> String {
        "plates/\(variant.rawValue)/base.jpg"
    }

    public static func light(_ pinId: UUID, _ variant: PlateVariant) -> String {
        "plates/\(variant.rawValue)/\(pinId.uuidString).png"
    }

    public static func isUploadName(_ name: String) -> Bool {
        if name == "layout.json" || name == "model.glb" || name == "model.usdz" || name == manifest {
            return true
        }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "plates" else { return false }
        guard parts[1] == "day" || parts[1] == "night" else { return false }
        if parts[2] == "base.jpg" { return true }
        let file = String(parts[2])
        guard file.hasSuffix(".png"), file.count > 4 else { return false }
        return UUID(uuidString: String(file.dropLast(4))) != nil
    }
}

public struct PlateRegion: Codable, Equatable, Sendable {
    @Quantized public var x: Double
    @Quantized public var y: Double
    @Quantized public var radius: Double

    public init(x: Double, y: Double, radius: Double) {
        self.x = x
        self.y = y
        self.radius = radius
    }
}

public struct LightPlate: Codable, Equatable, Sendable {
    public var pinId: UUID
    public var entityId: String?
    public var file: String
    public var region: PlateRegion?

    public init(pinId: UUID, entityId: String?, file: String, region: PlateRegion?) {
        self.pinId = pinId
        self.entityId = entityId
        self.file = file
        self.region = region
    }
}

public struct PlateSet: Codable, Equatable, Sendable {
    public var base: String
    public var lights: [LightPlate]

    public init(base: String, lights: [LightPlate]) {
        self.base = base
        self.lights = lights
    }
}

/// `plates/manifest.json`. Version 1. The card refuses any other format or version.
public struct PlateManifest: Codable, Equatable, Sendable {
    public static let formatIdentifier = "home_scanner.plates"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var roomId: UUID
    public var width: Int
    public var height: Int
    public var viewpoint: CameraViewpoint
    public var day: PlateSet
    public var night: PlateSet

    public init(
        format: String = formatIdentifier,
        version: Int = currentVersion,
        roomId: UUID,
        width: Int,
        height: Int,
        viewpoint: CameraViewpoint,
        day: PlateSet,
        night: PlateSet
    ) {
        self.format = format
        self.version = version
        self.roomId = roomId
        self.width = width
        self.height = height
        self.viewpoint = viewpoint
        self.day = day
        self.night = night
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> PlateManifest {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let manifest = try decoder.decode(PlateManifest.self, from: data)
        guard manifest.format == formatIdentifier else {
            throw HomeLayoutError.unknownFormat(manifest.format)
        }
        guard manifest.version == currentVersion else {
            throw HomeLayoutError.unsupportedVersion(manifest.version)
        }
        return manifest
    }
}

public enum PlateCatalog {
    public static func viewpoint(for room: Room) -> CameraViewpoint {
        room.viewpoint ?? .framed(on: room.floorPlan)
    }

    public static func manifest(for room: Room, pins: [DevicePin]) -> PlateManifest {
        let camera = viewpoint(for: room)
        let lights = pins.filter { $0.kind == .light && ($0.roomId == nil || $0.roomId == room.id) }
        return PlateManifest(
            roomId: room.id,
            width: PlateLayout.width,
            height: PlateLayout.height,
            viewpoint: camera,
            day: set(.day, camera: camera, lights: lights),
            night: set(.night, camera: camera, lights: lights)
        )
    }

    /// No files when either base image is missing. Light images that did not render are left out of the manifest.
    public static func files(for room: Room, pins: [DevicePin], images: [String: Data]) throws -> [HomeScannerFile] {
        let dayName = PlatePaths.base(.day)
        let nightName = PlatePaths.base(.night)
        guard let dayBase = images[dayName], !dayBase.isEmpty,
              let nightBase = images[nightName], !nightBase.isEmpty else {
            return []
        }
        var manifest = manifest(for: room, pins: pins)
        manifest.day.lights = manifest.day.lights.filter { image($0.file, in: images) }
        manifest.night.lights = manifest.night.lights.filter { image($0.file, in: images) }
        var files = [
            HomeScannerFile(filename: PlatePaths.manifest, mimeType: "application/json", data: try manifest.encode()),
            HomeScannerFile(filename: dayName, mimeType: "image/jpeg", data: dayBase),
            HomeScannerFile(filename: nightName, mimeType: "image/jpeg", data: nightBase)
        ]
        var seen = Set<String>()
        for light in manifest.day.lights + manifest.night.lights {
            guard seen.insert(light.file).inserted, let data = images[light.file], !data.isEmpty else { continue }
            guard PlatePaths.isUploadName(light.file) else { continue }
            files.append(HomeScannerFile(filename: light.file, mimeType: "image/png", data: data))
        }
        return files
    }

    private static func image(_ name: String, in images: [String: Data]) -> Bool {
        guard let data = images[name], !data.isEmpty else { return false }
        return PlatePaths.isUploadName(name)
    }

    private static func set(_ variant: PlateVariant, camera: CameraViewpoint, lights: [DevicePin]) -> PlateSet {
        PlateSet(
            base: PlatePaths.base(variant),
            lights: lights.map { pin in
                LightPlate(
                    pinId: pin.id,
                    entityId: pin.entityId,
                    file: PlatePaths.light(pin.id, variant),
                    region: camera.region(of: pin.position, aspect: PlateLayout.aspect)
                )
            }
        )
    }
}
