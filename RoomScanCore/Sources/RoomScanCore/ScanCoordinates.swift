import Foundation

/// The archived ARWorldMap for a home. Omitted from `home.json` until a scan saves one,
/// so older files stay valid. The bytes live beside the home, not in the JSON.
public struct ScanWorldMap: Codable, Equatable, Sendable {
    public static let relativePath = "world.arworldmap"

    public var file: String
    public var savedAt: Date
    /// Rooms whose CapturedRoom JSON is in this map's coordinate space.
    public var roomIds: [UUID]
    /// The room whose scan space the map was captured in. Nil when the map is the home's shared space.
    public var anchorRoomId: UUID?

    public init(file: String = ScanWorldMap.relativePath, savedAt: Date, roomIds: [UUID], anchorRoomId: UUID?) {
        self.file = file
        self.savedAt = savedAt
        self.roomIds = roomIds
        self.anchorRoomId = anchorRoomId
    }
}

/// Where a newly captured group sits relative to the rooms already in the home.
public struct ScanFrameJoin: Equatable, Sendable {
    public var placements: [RoomPlacement]
    public var overlaps: [RoomOverlap]
    public var coordinatesAreUnified: Bool
    /// Relocalization did not lock, so the doorway alignment placed the new rooms.
    public var usedAlignmentFallback: Bool
    public var replacedShell: Bool

    public init(
        placements: [RoomPlacement],
        overlaps: [RoomOverlap],
        coordinatesAreUnified: Bool,
        usedAlignmentFallback: Bool,
        replacedShell: Bool
    ) {
        self.placements = placements
        self.overlaps = overlaps
        self.coordinatesAreUnified = coordinatesAreUnified
        self.usedAlignmentFallback = usedAlignmentFallback
        self.replacedShell = replacedShell
    }

    /// Placements worth writing. A fully shared scan stores none, and the home is marked unified.
    public var storedAlignment: RoomAlignmentResult {
        let meaningful = !overlaps.isEmpty || placements.contains { !$0.transform.isNearIdentity }
        if coordinatesAreUnified && !meaningful {
            return .none
        }
        return RoomAlignmentResult(
            placements: placements,
            overlaps: overlaps,
            replacedShell: replacedShell || usedAlignmentFallback || meaningful
        )
    }
}

public enum ScanCoordinates {
    /// Places `incoming` rooms onto the home.
    ///
    /// When `incomingMatchAnchors` is true, each new room was captured in the anchor
    /// room's scan space, so it inherits that room's placement. Pins, furniture,
    /// viewpoints, and plates stay in scan space and move with that same rigid.
    /// When the lock failed, `incomingShareSpace` keeps one ARSession's rooms together
    /// and seats that group with the doorway alignment. Existing rooms keep the
    /// placements they already had.
    public static func join(
        existing: [Room],
        incoming: [Room],
        incomingMatchAnchors: Bool,
        incomingShareSpace: Bool,
        anchorRoomId: UUID?,
        anchorRoomIds: [UUID],
        existingPlacements: [RoomPlacement]
    ) -> ScanFrameJoin {
        if incoming.isEmpty {
            let unified = existing.count <= 1 || existingPlacements.allSatisfy { $0.transform.isNearIdentity }
            return ScanFrameJoin(
                placements: existingPlacements,
                overlaps: [],
                coordinatesAreUnified: unified,
                usedAlignmentFallback: false,
                replacedShell: false
            )
        }
        if incomingMatchAnchors || existing.isEmpty {
            return trustShared(
                existing: existing,
                incoming: incoming,
                anchorRoomId: anchorRoomId,
                anchorRoomIds: anchorRoomIds,
                existingPlacements: existingPlacements
            )
        }
        return fallback(
            existing: existing,
            incoming: incoming,
            incomingShareSpace: incomingShareSpace,
            existingPlacements: existingPlacements
        )
    }

    /// Rotates every listed room around the group's displayed center, then slides
    /// them together. Rooms that share an ARSession keep the gaps between them.
    public static func nudgeGroup(
        placements: [RoomPlacement],
        rooms: [Room],
        yaw: Double,
        translation: Vec3
    ) -> [RoomPlacement] {
        let ids = Set(rooms.map(\.id))
        let center = displayedCenter(of: rooms, placements: placements)
        let spin = RigidYaw.rotation(around: center, by: yaw)
        return placements.map { placement in
            guard ids.contains(placement.roomId) else { return placement }
            let combined = spin.composed(after: placement.transform)
            var result = placement
            result.yaw = combined.yaw
            result.translation = Vec3(
                x: combined.translation.x + translation.x,
                y: combined.translation.y + translation.y,
                z: combined.translation.z + translation.z
            )
            result.snapped = false
            return result
        }
    }

    /// Rotates around the room's footprint center, then slides in world meters.
    /// The center stays put when `translation` is zero, including when the room
    /// already has a placement.
    public static func nudge(
        placement: RoomPlacement,
        plan: FloorPlan,
        yaw: Double,
        translation: Vec3
    ) -> RoomPlacement {
        let scanCenter = FloorPlanGeometry.bounds(of: plan).center
        let displayedCenter = placement.transform.applying(scanCenter)
        let spin = RigidYaw.rotation(around: displayedCenter, by: yaw)
        let combined = spin.composed(after: placement.transform)
        var result = placement
        result.yaw = combined.yaw
        result.translation = Vec3(
            x: combined.translation.x + translation.x,
            y: combined.translation.y + translation.y,
            z: combined.translation.z + translation.z
        )
        result.snapped = false
        return result
    }

    /// One floor plan in display space. Used when RoomPlan's merged shell is not the view to trust.
    public static func overview(rooms: [Room], placements: [RoomPlacement]) -> FloorPlan {
        let map = Dictionary(uniqueKeysWithValues: placements.map { ($0.roomId, $0.transform) })
        var walls: [WallSegment] = []
        var openings: [Opening] = []
        var floors: [FloorPolygon] = []
        var objects: [PlacedObject] = []
        for room in rooms {
            let plan = room.floorPlan.transformed(by: map[room.id] ?? .identity)
            walls.append(contentsOf: plan.walls)
            openings.append(contentsOf: plan.openings)
            floors.append(contentsOf: plan.floors)
            objects.append(contentsOf: plan.objects)
        }
        return FloorPlan(walls: walls, openings: openings, floors: floors, objects: objects)
    }

    private static func trustShared(
        existing: [Room],
        incoming: [Room],
        anchorRoomId: UUID?,
        anchorRoomIds: [UUID],
        existingPlacements: [RoomPlacement]
    ) -> ScanFrameJoin {
        let stored = Dictionary(uniqueKeysWithValues: existingPlacements.map { ($0.roomId, $0) })
        let anchor = anchorTransform(
            anchorRoomId: anchorRoomId,
            anchorRoomIds: anchorRoomIds,
            stored: stored
        )
        var placements: [RoomPlacement] = existing.map { room in
            stored[room.id] ?? RoomPlacement(roomId: room.id, yaw: 0, translation: .zero, snapped: false)
        }
        for room in incoming {
            placements.append(RoomPlacement(
                roomId: room.id,
                yaw: anchor.yaw,
                translation: anchor.translation,
                snapped: false
            ))
        }
        let anchorIDs = Set(anchorRoomIds)
        let incomingFloor = incoming.first?.floor
        let outsiders = existing.filter { room in
            !anchorIDs.isEmpty && !anchorIDs.contains(room.id) && room.floor == incomingFloor
        }
        if !outsiders.isEmpty {
            park(outsiders, beside: existing.filter { anchorIDs.contains($0.id) } + incoming, placements: &placements)
        }
        let overlaps = overlapping(existing + incoming, placements: placements)
        let unified = outsiders.isEmpty && placements.allSatisfy { $0.transform.isNearIdentity }
        return ScanFrameJoin(
            placements: unified ? [] : placements,
            overlaps: overlaps,
            coordinatesAreUnified: unified,
            usedAlignmentFallback: false,
            replacedShell: !overlaps.isEmpty || !outsiders.isEmpty
        )
    }

    /// Slides same-floor rooms that are not in the world map out from under the shared scan.
    /// A room that already sits clear of that scan keeps its placement, including a copied floor.
    private static func park(
        _ outsiders: [Room],
        beside shared: [Room],
        placements: inout [RoomPlacement]
    ) {
        let blocking = shared.filter { room in
            let plan = transformed(room, placements: placements)
            return outsiders.contains { RoomFootprint.overlapRatio(plan, transformed($0, placements: placements)) >= 0.05 }
        }
        guard !blocking.isEmpty else { return }
        var cursor = blocking.map { FloorPlanGeometry.bounds(of: transformed($0, placements: placements)).max.x }.max() ?? 0
        cursor += 0.8
        for room in outsiders {
            let current = placements.first { $0.roomId == room.id }?.transform ?? .identity
            let plan = room.floorPlan.transformed(by: current)
            let hits = blocking.contains { RoomFootprint.overlapRatio(plan, transformed($0, placements: placements)) >= 0.05 }
            guard hits else { continue }
            let box = FloorPlanGeometry.bounds(of: plan)
            let slide = RigidYaw(yaw: 0, translation: Vec3(x: cursor - box.min.x, y: 0, z: 0))
            let combined = slide.composed(after: current)
            if let index = placements.firstIndex(where: { $0.roomId == room.id }) {
                placements[index].yaw = combined.yaw
                placements[index].translation = combined.translation
                placements[index].snapped = false
            }
            cursor += box.size.x + 0.8
        }
    }

    private static func transformed(_ room: Room, placements: [RoomPlacement]) -> FloorPlan {
        let rigid = placements.first { $0.roomId == room.id }?.transform ?? .identity
        return room.floorPlan.transformed(by: rigid)
    }

    private static func fallback(
        existing: [Room],
        incoming: [Room],
        incomingShareSpace: Bool,
        existingPlacements: [RoomPlacement]
    ) -> ScanFrameJoin {
        let stored = Dictionary(uniqueKeysWithValues: existingPlacements.map { ($0.roomId, $0) })
        let baked: [Room] = existing.map { room in
            var copy = room
            copy.floorPlan = room.floorPlan.transformed(by: stored[room.id]?.transform ?? .identity)
            return copy
        }
        let aligned = RoomAlignment.align(rooms: baked + incoming)
        var placements: [RoomPlacement] = existing.map { room in
            stored[room.id] ?? RoomPlacement(roomId: room.id, yaw: 0, translation: .zero, snapped: false)
        }
        if incomingShareSpace, let first = incoming.first {
            let group = transform(for: first, aligned: aligned, existing: existing, stored: stored)
            for room in incoming {
                placements.append(RoomPlacement(
                    roomId: room.id,
                    yaw: group.yaw,
                    translation: group.translation,
                    snapped: !group.isNearIdentity
                ))
            }
        } else {
            for room in incoming {
                let transform = transform(for: room, aligned: aligned, existing: existing, stored: stored)
                placements.append(RoomPlacement(
                    roomId: room.id,
                    yaw: transform.yaw,
                    translation: transform.translation,
                    snapped: !transform.isNearIdentity
                ))
            }
        }
        let overlaps = overlapping(existing + incoming, placements: placements)
        return ScanFrameJoin(
            placements: placements,
            overlaps: overlaps,
            coordinatesAreUnified: false,
            usedAlignmentFallback: true,
            replacedShell: true
        )
    }

    private static func displayedCenter(of rooms: [Room], placements: [RoomPlacement]) -> Vec3 {
        var points: [Vec3] = []
        for room in rooms {
            let rigid = placements.first { $0.roomId == room.id }?.transform ?? .identity
            points.append(FloorPlanGeometry.bounds(of: room.floorPlan.transformed(by: rigid)).center)
        }
        guard !points.isEmpty else { return .zero }
        return points.reduce(Vec3.zero, +).scaled(1 / Double(points.count))
    }

    /// The alignment result when it actually moved the room. Otherwise a doorway
    /// seat against the rooms that are already on the floor, in their display space.
    private static func transform(
        for room: Room,
        aligned: RoomAlignmentResult,
        existing: [Room],
        stored: [UUID: RoomPlacement]
    ) -> RigidYaw {
        let proposed = aligned.placement(for: room.id)?.transform ?? .identity
        if !proposed.isNearIdentity { return proposed }
        return seat(room, against: existing, stored: stored) ?? proposed
    }

    private static func seat(
        _ incoming: Room,
        against existing: [Room],
        stored: [UUID: RoomPlacement]
    ) -> RigidYaw? {
        let movingCentroid = FloorPlanGeometry.bounds(of: incoming.floorPlan).center
        var best: (transform: RigidYaw, overlap: Double)?
        for other in existing where other.floor == incoming.floor {
            let anchorPlan = other.floorPlan.transformed(by: stored[other.id]?.transform ?? .identity)
            let anchorCentroid = FloorPlanGeometry.bounds(of: anchorPlan).center
            for anchorOpening in anchorPlan.openings where anchorOpening.kind == .door || anchorOpening.kind == .opening {
                for movingOpening in incoming.floorPlan.openings where movingOpening.kind == .door || movingOpening.kind == .opening {
                    let transform = doorJoin(
                        movingDoor: movingOpening,
                        movingCentroid: movingCentroid,
                        anchorDoor: anchorOpening,
                        anchorCentroid: anchorCentroid
                    )
                    let overlap = RoomFootprint.overlapRatio(
                        incoming.floorPlan.transformed(by: transform),
                        anchorPlan
                    )
                    if best == nil || overlap < best!.overlap {
                        best = (transform, overlap)
                    }
                }
            }
        }
        guard let best, best.overlap < 0.2 else { return nil }
        return best.transform
    }

    private static func doorJoin(
        movingDoor: Opening,
        movingCentroid: Vec3,
        anchorDoor: Opening,
        anchorCentroid: Vec3
    ) -> RigidYaw {
        let anchorNormal = outwardNormal(of: anchorDoor, centroid: anchorCentroid)
        let movingNormal = outwardNormal(of: movingDoor, centroid: movingCentroid)
        let yaw = wrap(Trig.atan2(anchorNormal.z, anchorNormal.x) + .pi - Trig.atan2(movingNormal.z, movingNormal.x))
        let rotated = RigidYaw(yaw: yaw, translation: .zero).applying(movingDoor.center)
        return RigidYaw(
            yaw: yaw,
            translation: Vec3(x: anchorDoor.center.x - rotated.x, y: 0, z: anchorDoor.center.z - rotated.z)
        )
    }

    private static func outwardNormal(of opening: Opening, centroid: Vec3) -> Vec3 {
        let sine = Trig.sin(opening.yaw)
        let cosine = Trig.cos(opening.yaw)
        let left = Vec3(x: -sine, y: 0, z: cosine)
        let towardCenter = Vec3(x: centroid.x - opening.center.x, y: 0, z: centroid.z - opening.center.z)
        if left.x * towardCenter.x + left.z * towardCenter.z > 0 {
            return Vec3(x: -left.x, y: 0, z: -left.z)
        }
        return left
    }

    private static func wrap(_ angle: Double) -> Double {
        var value = angle
        let turn = Double.pi * 2
        while value > .pi { value -= turn }
        while value < -.pi { value += turn }
        return value
    }

    private static func anchorTransform(
        anchorRoomId: UUID?,
        anchorRoomIds: [UUID],
        stored: [UUID: RoomPlacement]
    ) -> RigidYaw {
        if let anchorRoomId, let placement = stored[anchorRoomId] {
            return placement.transform
        }
        let anchors = anchorRoomIds.compactMap { stored[$0]?.transform }
        if let first = anchors.first, anchors.allSatisfy({ near($0, first) }) {
            return first
        }
        return .identity
    }

    private static func near(_ lhs: RigidYaw, _ rhs: RigidYaw) -> Bool {
        abs(lhs.yaw - rhs.yaw) < 0.02
            && abs(lhs.translation.x - rhs.translation.x) < 0.05
            && abs(lhs.translation.y - rhs.translation.y) < 0.05
            && abs(lhs.translation.z - rhs.translation.z) < 0.05
    }

    private static func overlapping(_ rooms: [Room], placements: [RoomPlacement]) -> [RoomOverlap] {
        let map = Dictionary(uniqueKeysWithValues: placements.map { ($0.roomId, $0.transform) })
        var overlaps: [RoomOverlap] = []
        for left in rooms.indices {
            for right in rooms.indices.dropFirst(left + 1) where rooms[left].floor == rooms[right].floor {
                let earlier = rooms[left]
                let later = rooms[right]
                let leftPlan = earlier.floorPlan.transformed(by: map[earlier.id] ?? .identity)
                let rightPlan = later.floorPlan.transformed(by: map[later.id] ?? .identity)
                let ratio = RoomFootprint.overlapRatio(leftPlan, rightPlan)
                guard ratio >= 0.45 else { continue }
                overlaps.append(RoomOverlap(roomIds: [earlier.id, later.id], kind: .duplicate, ratio: ratio))
            }
        }
        return overlaps
    }
}
