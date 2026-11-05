import Foundation

/// Drops unmatched Home Assistant entities into rooms.
/// An entity that is already linked to a pin is left alone, so a hand-placed pin stays put.
public enum PinAutoPlace {
    public struct Candidate: Equatable, Sendable {
        public var entityId: String
        public var friendlyName: String?
        public var domain: String
        public var areaName: String?

        public init(entityId: String, friendlyName: String?, domain: String, areaName: String?) {
            self.entityId = entityId
            self.friendlyName = friendlyName
            self.domain = domain
            self.areaName = areaName
        }
    }

    public static func suggestions(
        rooms: [Room],
        candidates: [Candidate],
        existingPins: [DevicePin],
        makeID: () -> UUID = { UUID() }
    ) -> [DevicePin] {
        let linked = Set(existingPins.compactMap { pin -> String? in
            guard let raw = pin.entityId, case .valid(let id) = EntityIDRules.check(raw) else { return nil }
            return id
        })
        var placed: [DevicePin] = []
        let ordered = candidates.sorted { lhs, rhs in
            let left = EntityIDRules.check(lhs.entityId).canonical ?? lhs.entityId
            let right = EntityIDRules.check(rhs.entityId).canonical ?? rhs.entityId
            return left < right
        }
        for candidate in ordered {
            guard EntitySearch.preferredDomains.contains(candidate.domain) else { continue }
            guard case .valid(let entityId) = EntityIDRules.check(candidate.entityId) else { continue }
            guard !linked.contains(entityId) else { continue }
            guard !placed.contains(where: { $0.entityId == entityId }) else { continue }
            guard let room = bestRoom(for: candidate, in: rooms) else { continue }
            let kind = DeviceKind.forHomeAssistantDomain(candidate.domain)
            let occupied = existingPins.filter { $0.roomId == room.id }.map(\.position)
                + placed.filter { $0.roomId == room.id }.map(\.position)
            var slot = occupied.count
            var position = self.position(slot: slot, plan: room.floorPlan, kind: kind)
            while slot < 48 && occupied.contains(where: { near($0, position) }) {
                slot += 1
                position = self.position(slot: slot, plan: room.floorPlan, kind: kind)
            }
            let name = displayName(candidate, kind: kind)
            placed.append(
                DevicePin(
                    id: makeID(),
                    roomId: room.id,
                    name: name,
                    kind: kind,
                    entityId: entityId,
                    position: position
                )
            )
        }
        return placed.sorted { lhs, rhs in
            let leftRoom = rooms.first { $0.id == lhs.roomId }?.name ?? ""
            let rightRoom = rooms.first { $0.id == rhs.roomId }?.name ?? ""
            if leftRoom != rightRoom { return leftRoom < rightRoom }
            return (lhs.entityId ?? "") < (rhs.entityId ?? "")
        }
    }

    /// Grid point inside the room's floor bounds. `slot` walks across, then down.
    public static func position(slot: Int, plan: FloorPlan, kind: DeviceKind) -> Vec3 {
        let box = FloorPlanGeometry.bounds(of: plan)
        let width = max(box.size.x, 0.6)
        let depth = max(box.size.z, 0.6)
        let insetX = min(0.35, width * 0.15)
        let insetZ = min(0.35, depth * 0.15)
        let minX = box.min.x + insetX
        let maxX = box.max.x - insetX
        let minZ = box.min.z + insetZ
        let maxZ = box.max.z - insetZ
        let spanX = max(maxX - minX, 0.2)
        let spanZ = max(maxZ - minZ, 0.2)
        let cols = max(1, Int((spanX / 0.75).rounded(.down)))
        let safeSlot = max(0, slot)
        let col = safeSlot % cols
        let row = safeSlot / cols
        let x = minX + (Double(col) + 0.5) / Double(cols) * spanX
        let z = min(maxZ, minZ + (Double(row) + 0.5) * min(0.75, spanZ))
        return Vec3(x: x, y: kind.defaultHeight, z: z)
    }

    private static func near(_ lhs: Vec3, _ rhs: Vec3) -> Bool {
        let dx = lhs.x - rhs.x
        let dz = lhs.z - rhs.z
        return (dx * dx + dz * dz).squareRoot() < 0.3
    }

    private static func bestRoom(for candidate: Candidate, in rooms: [Room]) -> Room? {
        var best: (room: Room, score: Int)?
        var tied = false
        for room in rooms {
            let score = score(room: room, candidate: candidate)
            guard score > 0 else { continue }
            if let current = best {
                if score > current.score {
                    best = (room, score)
                    tied = false
                } else if score == current.score {
                    tied = true
                }
            } else {
                best = (room, score)
            }
        }
        guard let best, !tied else { return nil }
        return best.room
    }

    private static func score(room: Room, candidate: Candidate) -> Int {
        let roomNorm = normalize(room.name)
        let roomTokens = tokens(room.name)
        guard !roomNorm.isEmpty else { return 0 }
        if let area = candidate.areaName {
            let areaNorm = normalize(area)
            if !areaNorm.isEmpty, areaNorm == roomNorm { return 100 }
            let areaTokens = tokens(area)
            if !roomTokens.isEmpty, roomTokens.allSatisfy({ areaTokens.contains($0) }) { return 80 }
        }
        let haystack = [candidate.friendlyName, objectID(candidate.entityId)]
            .compactMap { $0 }
            .joined(separator: " ")
        let hayTokens = tokens(haystack)
        if !roomTokens.isEmpty, roomTokens.allSatisfy({ hayTokens.contains($0) }) { return 60 }
        if !roomTokens.isEmpty, roomTokens.allSatisfy({ needle in
            needle.count >= 4 && hayTokens.contains { $0.hasPrefix(needle) || needle.hasPrefix($0) }
        }) {
            return 40
        }
        return 0
    }

    private static func displayName(_ candidate: Candidate, kind: DeviceKind) -> String {
        let friendly = candidate.friendlyName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !friendly.isEmpty { return friendly }
        return kind.label
    }

    private static func objectID(_ entityId: String) -> String {
        guard let dot = entityId.firstIndex(of: ".") else { return entityId }
        return String(entityId[entityId.index(after: dot)...])
    }

    private static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init).filter { token in
            token.count >= 2 && !stopWords.contains(token)
        }
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    private static let stopWords: Set<String> = [
        "room", "the", "a", "an", "light", "lights", "lamp", "switch", "sensor", "fan"
    ]
}

private extension EntityIDCheck {
    var canonical: String? {
        if case .valid(let id) = self { return id }
        return nil
    }
}
