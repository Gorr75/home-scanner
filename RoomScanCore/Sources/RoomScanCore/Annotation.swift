import Foundation

public enum AnnotationKind: String, Codable, Sendable {
    case note
    case measurement
}

/// Two points of a saved distance. Both stay in the room's scan space.
public struct AnnotationMeasurement: Codable, Equatable, Sendable {
    public var start: Vec3
    public var end: Vec3

    public init(start: Vec3, end: Vec3) {
        self.start = start
        self.end = end
    }

    public var distance: Double {
        (end - start).length
    }

    public var midpoint: Vec3 {
        Vec3(
            x: (start.x + end.x) / 2,
            y: (start.y + end.y) / 2,
            z: (start.z + end.z) / 2
        )
    }

    public func transformed(by rigid: RigidYaw) -> AnnotationMeasurement {
        AnnotationMeasurement(start: rigid.applying(start), end: rigid.applying(end))
    }
}

/// A pin on a wall, floor, or object. Photos and audio are relative paths beside the home.
public struct RoomAnnotation: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var position: Vec3
    /// Relative path, for example `notes/<id>.jpg`.
    public var photo: String?
    /// Relative path, for example `notes/<id>.m4a`.
    public var audio: String?
    public var transcript: String?
    public var kind: AnnotationKind
    public var measurement: AnnotationMeasurement?

    public init(
        id: UUID,
        createdAt: Date,
        text: String,
        position: Vec3,
        photo: String? = nil,
        audio: String? = nil,
        transcript: String? = nil,
        kind: AnnotationKind = .note,
        measurement: AnnotationMeasurement? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.position = position
        self.photo = photo
        self.audio = audio
        self.transcript = transcript
        self.kind = kind
        self.measurement = measurement
    }

    public static func note(at position: Vec3, text: String, now: Date = Date(), id: UUID = UUID()) -> RoomAnnotation {
        RoomAnnotation(id: id, createdAt: now, text: text, position: position, kind: .note)
    }

    public static func measurement(from start: Vec3, to end: Vec3, text: String? = nil, now: Date = Date(), id: UUID = UUID()) -> RoomAnnotation {
        let span = AnnotationMeasurement(start: start, end: end)
        return RoomAnnotation(
            id: id,
            createdAt: now,
            text: text ?? MeasureSnap.label(from: start, to: end),
            position: span.midpoint,
            kind: .measurement,
            measurement: span
        )
    }

    /// The same rigid move the align step applies to a pin or a piece of furniture.
    public func transformed(by rigid: RigidYaw) -> RoomAnnotation {
        var copy = self
        copy.position = rigid.applying(position)
        copy.measurement = measurement?.transformed(by: rigid)
        return copy
    }
}

extension RoomAnnotation: Codable {
    enum CodingKeys: String, CodingKey {
        case id, createdAt, text, position, photo, audio, transcript, kind, measurement
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        position = try container.decode(Vec3.self, forKey: .position)
        photo = try container.decodeIfPresent(String.self, forKey: .photo)
        audio = try container.decodeIfPresent(String.self, forKey: .audio)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript)
        if let raw = try container.decodeIfPresent(String.self, forKey: .kind) {
            kind = AnnotationKind(rawValue: raw) ?? .note
        } else {
            kind = .note
        }
        measurement = try container.decodeIfPresent(AnnotationMeasurement.self, forKey: .measurement)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(text, forKey: .text)
        try container.encode(position, forKey: .position)
        try container.encodeIfPresent(photo, forKey: .photo)
        try container.encodeIfPresent(audio, forKey: .audio)
        try container.encodeIfPresent(transcript, forKey: .transcript)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(measurement, forKey: .measurement)
    }
}

public enum MediaPaths {
    public static func annotationPhoto(_ id: UUID) -> String {
        "notes/\(id.uuidString).jpg"
    }

    public static func annotationAudio(_ id: UUID) -> String {
        "notes/\(id.uuidString).m4a"
    }

    public static func inventoryPhoto(_ id: UUID, index: Int) -> String {
        "inventory/\(id.uuidString)-\(index).jpg"
    }

    public static func inventoryReceipt(_ id: UUID) -> String {
        "inventory/\(id.uuidString)-receipt.jpg"
    }
}

extension Room {
    public var roomAnnotations: [RoomAnnotation] {
        get { annotations ?? [] }
        set { annotations = newValue.isEmpty ? nil : newValue }
    }

    /// Photo and audio paths referenced by this room's notes and inventory.
    public var mediaPaths: [String] {
        var paths: [String] = []
        for note in roomAnnotations {
            if let photo = note.photo { paths.append(photo) }
            if let audio = note.audio { paths.append(audio) }
        }
        for item in inventoryItems {
            paths.append(contentsOf: item.photos)
            if let receipt = item.receipt { paths.append(receipt) }
        }
        return paths
    }
}

extension Home {
    public func annotations(in roomID: UUID) -> [RoomAnnotation] {
        room(id: roomID)?.roomAnnotations ?? []
    }

    public func annotation(id: UUID) -> (roomID: UUID, note: RoomAnnotation)? {
        for room in rooms {
            if let note = room.roomAnnotations.first(where: { $0.id == id }) {
                return (room.id, note)
            }
        }
        return nil
    }

    public mutating func upsertAnnotation(_ note: RoomAnnotation, in roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        var notes = rooms[index].roomAnnotations
        if let existing = notes.firstIndex(where: { $0.id == note.id }) {
            notes[existing] = note
        } else {
            notes.append(note)
        }
        rooms[index].roomAnnotations = notes
    }

    public mutating func deleteAnnotation(id: UUID, in roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        var notes = rooms[index].roomAnnotations
        notes.removeAll { $0.id == id }
        rooms[index].roomAnnotations = notes
    }
}
