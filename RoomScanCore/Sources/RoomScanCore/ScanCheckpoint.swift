import Foundation

/// How this capture pass is meant to grow the home.
public enum ScanCheckpointMode: String, Codable, Sendable, Equatable {
    /// One room, then the name screen.
    case singleRoom
    /// One ARSession, room after room, until the person taps Done.
    case wholeFloor
    /// A room added to a home that already has a saved world map.
    case extendHome
}

/// What the file on disk says about the session that wrote it.
public enum ScanCheckpointPhase: String, Codable, Sendable, Equatable {
    /// The session was running when this file was written.
    case scanning
    /// The app backgrounded, or the process died before the next launch.
    case interrupted
    case saved
    case discarded
}

/// One room's CapturedRoom JSON inside a checkpoint folder.
public struct ScanCheckpointSection: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Path relative to the checkpoint folder, for example `sections/<id>.captured.json`.
    public var capturedRoom: String
    public var finished: Bool
    public var floor: Int?
    /// Rooms that share a `spaceId` were captured on one ARSession.
    public var spaceId: UUID
    /// The section was captured after the saved world map locked, so it shares that space.
    public var sharesHomeMap: Bool

    public init(
        id: UUID,
        name: String,
        capturedRoom: String,
        finished: Bool,
        floor: Int? = nil,
        spaceId: UUID,
        sharesHomeMap: Bool = false
    ) {
        self.id = id
        self.name = name
        self.capturedRoom = capturedRoom
        self.finished = finished
        self.floor = floor
        self.spaceId = spaceId
        self.sharesHomeMap = sharesHomeMap
    }

    enum CodingKeys: String, CodingKey {
        case id, name, capturedRoom, finished, floor, spaceId, sharesHomeMap
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        capturedRoom = try container.decode(String.self, forKey: .capturedRoom)
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        floor = try container.decodeIfPresent(Int.self, forKey: .floor)
        spaceId = try container.decodeIfPresent(UUID.self, forKey: .spaceId) ?? id
        sharesHomeMap = try container.decodeIfPresent(Bool.self, forKey: .sharesHomeMap) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(capturedRoom, forKey: .capturedRoom)
        try container.encode(finished, forKey: .finished)
        try container.encodeIfPresent(floor, forKey: .floor)
        try container.encode(spaceId, forKey: .spaceId)
        try container.encode(sharesHomeMap, forKey: .sharesHomeMap)
    }
}

/// A scan that is still on disk because it had not been saved or discarded.
/// CapturedRoom JSON and the ARWorldMap are sibling files. This manifest is written last.
public struct ScanCheckpoint: Codable, Equatable, Sendable, Identifiable {
    public static let formatIdentifier = "roomscan.checkpoint"
    public static let currentVersion = 1
    public static let worldMapFilename = "worldmap.arworldmap"

    public var format: String
    public var version: Int
    public var id: UUID
    public var homeId: UUID
    public var mode: ScanCheckpointMode
    public var phase: ScanCheckpointPhase
    public var startedAt: Date
    public var updatedAt: Date
    public var floor: Int?
    public var replacingRoomId: UUID?
    public var sections: [ScanCheckpointSection]
    /// Relative path of the archived ARWorldMap, when one has been written.
    public var worldMap: String?
    public var relocalized: Bool
    public var roomNameDraft: String?

    public init(
        id: UUID,
        homeId: UUID,
        mode: ScanCheckpointMode,
        phase: ScanCheckpointPhase,
        startedAt: Date,
        updatedAt: Date,
        floor: Int? = nil,
        replacingRoomId: UUID? = nil,
        sections: [ScanCheckpointSection] = [],
        worldMap: String? = nil,
        relocalized: Bool = false,
        roomNameDraft: String? = nil
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.id = id
        self.homeId = homeId
        self.mode = mode
        self.phase = phase
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.floor = floor
        self.replacingRoomId = replacingRoomId
        self.sections = sections
        self.worldMap = worldMap
        self.relocalized = relocalized
        self.roomNameDraft = roomNameDraft
    }

    public var hasCapturedRoom: Bool {
        sections.contains { !$0.capturedRoom.isEmpty }
    }

    /// A file left behind by a session that is no longer running.
    public var needsRecovery: Bool {
        switch phase {
        case .scanning, .interrupted:
            return hasCapturedRoom || worldMap != nil
        case .saved, .discarded:
            return false
        }
    }

    public func encode() throws -> Data {
        try ScanJSON.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> ScanCheckpoint {
        let checkpoint = try ScanJSON.decoder.decode(ScanCheckpoint.self, from: data)
        guard checkpoint.format == formatIdentifier else {
            throw ScanCheckpointError.unknownFormat(checkpoint.format)
        }
        guard checkpoint.version == currentVersion else {
            throw ScanCheckpointError.unsupportedVersion(checkpoint.version)
        }
        return checkpoint
    }

    enum CodingKeys: String, CodingKey {
        case format, version, id, homeId, mode, phase, startedAt, updatedAt, floor
        case replacingRoomId, sections, worldMap, relocalized, roomNameDraft
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UUID.self, forKey: .id)
        homeId = try container.decode(UUID.self, forKey: .homeId)
        mode = try container.decode(ScanCheckpointMode.self, forKey: .mode)
        phase = try container.decode(ScanCheckpointPhase.self, forKey: .phase)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        floor = try container.decodeIfPresent(Int.self, forKey: .floor)
        replacingRoomId = try container.decodeIfPresent(UUID.self, forKey: .replacingRoomId)
        sections = try container.decodeIfPresent([ScanCheckpointSection].self, forKey: .sections) ?? []
        worldMap = try container.decodeIfPresent(String.self, forKey: .worldMap)
        relocalized = try container.decodeIfPresent(Bool.self, forKey: .relocalized) ?? false
        roomNameDraft = try container.decodeIfPresent(String.self, forKey: .roomNameDraft)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(id, forKey: .id)
        try container.encode(homeId, forKey: .homeId)
        try container.encode(mode, forKey: .mode)
        try container.encode(phase, forKey: .phase)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(floor, forKey: .floor)
        try container.encodeIfPresent(replacingRoomId, forKey: .replacingRoomId)
        try container.encode(sections, forKey: .sections)
        try container.encodeIfPresent(worldMap, forKey: .worldMap)
        try container.encode(relocalized, forKey: .relocalized)
        try container.encodeIfPresent(roomNameDraft, forKey: .roomNameDraft)
    }
}

public enum ScanCheckpointError: Error, Equatable, Sendable {
    case unknownFormat(String)
    case unsupportedVersion(Int)
    case unsafePath(String)
    case missingCheckpoint(UUID)
}

extension ScanCheckpointError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let format):
            return "This file is \(format), not a scan checkpoint."
        case .unsupportedVersion(let version):
            return "This scan checkpoint uses version \(version), which this app does not read."
        case .unsafePath(let path):
            return "Refused to use the path \(path)."
        case .missingCheckpoint:
            return "That scan checkpoint is no longer on this device."
        }
    }
}

/// The choice offered when a checkpoint is still on disk at launch.
public struct ScanRecoveryOffer: Equatable, Sendable, Identifiable {
    public var checkpoint: ScanCheckpoint
    public var homeName: String?
    public var summary: String

    public var id: UUID { checkpoint.id }

    public var canResume: Bool {
        homeName != nil && (checkpoint.worldMap != nil || checkpoint.hasCapturedRoom)
    }

    public var canSave: Bool {
        homeName != nil && checkpoint.hasCapturedRoom
    }

    public init(checkpoint: ScanCheckpoint, homeName: String?, summary: String) {
        self.checkpoint = checkpoint
        self.homeName = homeName
        self.summary = summary
    }
}

public enum ScanRecovery {
    /// The newest checkpoint that still needs a person. Saved and discarded files are ignored.
    public static func offer(
        from checkpoints: [ScanCheckpoint],
        homeName: (UUID) -> String?
    ) -> ScanRecoveryOffer? {
        let candidates = checkpoints
            .filter(\.needsRecovery)
            .sorted { $0.updatedAt > $1.updatedAt }
        guard let latest = candidates.first else { return nil }
        let name = homeName(latest.homeId)
        return ScanRecoveryOffer(
            checkpoint: latest,
            homeName: name,
            summary: summary(checkpoint: latest, homeName: name)
        )
    }

    public static func summary(checkpoint: ScanCheckpoint, homeName: String?) -> String {
        guard let homeName else {
            return "A scan was interrupted, and that home is no longer on this iPhone."
        }
        let count = checkpoint.sections.count
        let rooms: String
        if count == 0 {
            rooms = "The place lock is saved."
        } else if count == 1 {
            rooms = "One room snapshot is on this iPhone."
        } else {
            rooms = "\(count) room snapshots are on this iPhone."
        }
        return "A scan of \(homeName) was still open. \(rooms)"
    }
}

/// Phone heat, battery, and free space, with no UIKit types so tests can drive it.
public enum ThermalBand: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

public struct ScanConditions: Equatable, Sendable {
    public var thermal: ThermalBand
    /// 0...1. Nil when the system has not reported a level.
    public var batteryFraction: Double?
    public var isCharging: Bool
    public var freeBytes: Int64?

    public init(
        thermal: ThermalBand,
        batteryFraction: Double?,
        isCharging: Bool,
        freeBytes: Int64?
    ) {
        self.thermal = thermal
        self.batteryFraction = batteryFraction
        self.isCharging = isCharging
        self.freeBytes = freeBytes
    }
}

public struct ScanGuardAdvice: Equatable, Sendable {
    public enum Level: String, Sendable, Equatable {
        case ok
        case caution
        case stop
    }

    public static let lowStorageBytes: Int64 = 250 * 1024 * 1024
    public static let lowBatteryFraction = 0.20
    public static let criticalBatteryFraction = 0.10

    public static let storageMessage = "This iPhone is low on storage. The scan saves as it goes, and it still needs room for the model."
    public static let hotMessage = "The phone is getting hot. The scan is being saved so it can be resumed."
    public static let tooHotMessage = "The phone is too hot. Stop and let it cool. What you scanned is already saved."
    public static let batteryMessage = "The battery is low. The scan is being saved in case the phone turns off."
    public static let batteryEmptyMessage = "The battery is almost empty. Stop soon. What you scanned is already saved."

    public var level: Level
    public var message: String?
    public var checkpointNow: Bool
    /// Shown before a scan starts. The scan can still begin.
    public var storageWarning: String?

    public init(level: Level, message: String?, checkpointNow: Bool, storageWarning: String?) {
        self.level = level
        self.message = message
        self.checkpointNow = checkpointNow
        self.storageWarning = storageWarning
    }

    public static func evaluate(_ conditions: ScanConditions) -> ScanGuardAdvice {
        var level: Level = .ok
        var parts: [String] = []
        switch conditions.thermal {
        case .critical:
            level = .stop
            parts.append(tooHotMessage)
        case .serious:
            level = .caution
            parts.append(hotMessage)
        case .nominal, .fair:
            break
        }
        if !conditions.isCharging, let battery = conditions.batteryFraction {
            if battery <= criticalBatteryFraction {
                level = .stop
                parts.append(batteryEmptyMessage)
            } else if battery <= lowBatteryFraction {
                if level == .ok { level = .caution }
                parts.append(batteryMessage)
            }
        }
        let storage: String?
        if let free = conditions.freeBytes, free < lowStorageBytes {
            storage = storageMessage
        } else {
            storage = nil
        }
        let message = parts.isEmpty ? nil : parts.joined(separator: " ")
        return ScanGuardAdvice(
            level: level,
            message: message,
            checkpointNow: level != .ok || storage != nil,
            storageWarning: storage
        )
    }
}

enum ScanJSON {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// On-device scan checkpoints, outside the home folder so a torn write cannot replace `home.json`.
public final class ScanCheckpointStore {
    public let root: URL
    public private(set) var warnings: [String] = []
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) throws {
        self.root = root
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func loadAll() -> [ScanCheckpoint] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            warnings = []
            return []
        }
        var loaded: [ScanCheckpoint] = []
        var notes: [String] = []
        for entry in entries {
            guard isDirectory(entry) else { continue }
            let manifest = entry.appendingPathComponent("checkpoint.json")
            guard fileManager.fileExists(atPath: manifest.path) else { continue }
            do {
                let data = try Data(contentsOf: manifest)
                loaded.append(try ScanCheckpoint.decode(data))
            } catch {
                notes.append("Skipped scan \(entry.lastPathComponent): \(error.localizedDescription)")
            }
        }
        warnings = notes
        return loaded.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Drops sections whose JSON is missing and a world map path that was never written,
    /// so recovery does not offer a save that has nothing to read.
    public func verified(_ checkpoint: ScanCheckpoint) -> ScanCheckpoint {
        var copy = checkpoint
        copy.sections.removeAll { section in
            guard RelativePath.isSafe(section.capturedRoom) else { return true }
            guard let url = fileURL(checkpoint.id, relative: section.capturedRoom) else { return true }
            return !fileManager.fileExists(atPath: url.path)
        }
        if let map = copy.worldMap {
            let exists = RelativePath.isSafe(map)
                && fileURL(checkpoint.id, relative: map).map { fileManager.fileExists(atPath: $0.path) } == true
            if !exists { copy.worldMap = nil }
        }
        return copy
    }

    public func recoveryOffer(
        homeName: (UUID) -> String?,
        ignoring activeID: UUID? = nil
    ) -> ScanRecoveryOffer? {
        let checkpoints = loadAll()
            .filter { $0.id != activeID }
            .map(verified)
        return ScanRecovery.offer(from: checkpoints, homeName: homeName)
    }

    @discardableResult
    public func save(_ checkpoint: ScanCheckpoint, payloads: [String: Data] = [:]) throws -> ScanCheckpoint {
        for (relative, data) in payloads {
            try writePayload(checkpoint.id, relative: relative, data: data)
        }
        let manifest = try checkpoint.encode()
        let url = folderURL(checkpoint.id).appendingPathComponent("checkpoint.json")
        try AtomicFile.write(manifest, to: url, fileManager: fileManager)
        return checkpoint
    }

    public func writePayload(_ id: UUID, relative: String, data: Data) throws {
        guard let url = fileURL(id, relative: relative) else {
            throw ScanCheckpointError.unsafePath(relative)
        }
        try AtomicFile.write(data, to: url, fileManager: fileManager)
    }

    public func data(_ id: UUID, relative: String) throws -> Data {
        guard let url = fileURL(id, relative: relative) else {
            throw ScanCheckpointError.unsafePath(relative)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            throw ScanCheckpointError.missingCheckpoint(id)
        }
        return try Data(contentsOf: url)
    }

    public func discard(_ id: UUID) throws {
        let folder = folderURL(id)
        if fileManager.fileExists(atPath: folder.path) {
            try fileManager.removeItem(at: folder)
        }
    }

    public func discardAll(homeId: UUID) {
        for checkpoint in loadAll() where checkpoint.homeId == homeId {
            try? discard(checkpoint.id)
        }
    }

    private func folderURL(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func fileURL(_ id: UUID, relative: String) -> URL? {
        RelativePath.resolve(homeDirectory: folderURL(id), relative: relative)
    }

    private func isDirectory(_ url: URL) -> Bool {
        if let value = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return value
        }
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
