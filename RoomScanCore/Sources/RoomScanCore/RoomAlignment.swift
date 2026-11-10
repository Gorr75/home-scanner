import Foundation

/// A rotation around Y, then a translation. Maps a room's scan coordinates
/// onto the aligned floor. Yaw follows the rest of the model: zero keeps +X,
/// and positive yaw turns toward +Z.
public struct RigidYaw: Equatable, Sendable {
    public var yaw: Double
    public var translation: Vec3

    public init(yaw: Double, translation: Vec3) {
        self.yaw = yaw
        self.translation = translation
    }

    public static let identity = RigidYaw(yaw: 0, translation: .zero)

    public var isNearIdentity: Bool {
        abs(yaw) < 0.02 && abs(translation.y) < 0.05 && translation.horizontalLength < 0.05
    }

    public func applying(_ point: Vec3) -> Vec3 {
        let cosine = Trig.cos(yaw)
        let sine = Trig.sin(yaw)
        return Vec3(
            x: translation.x + point.x * cosine - point.z * sine,
            y: translation.y + point.y,
            z: translation.z + point.x * sine + point.z * cosine
        )
    }

    /// Undoes `applying`. A pin stored in scan space round-trips through this.
    public func inverse() -> RigidYaw {
        let cosine = Trig.cos(yaw)
        let sine = Trig.sin(yaw)
        return RigidYaw(
            yaw: -yaw,
            translation: Vec3(
                x: -(cosine * translation.x + sine * translation.z),
                y: -translation.y,
                z: -(-sine * translation.x + cosine * translation.z)
            )
        )
    }

    /// `self` runs on points that are already in `current`'s output space.
    public func composed(after current: RigidYaw) -> RigidYaw {
        let rotated = RigidYaw(yaw: yaw, translation: .zero).applying(current.translation)
        return RigidYaw(
            yaw: wrapAngle(current.yaw + yaw),
            translation: Vec3(
                x: rotated.x + translation.x,
                y: rotated.y + translation.y,
                z: rotated.z + translation.z
            )
        )
    }

    public static func rotation(around center: Vec3, by yaw: Double) -> RigidYaw {
        let rotated = RigidYaw(yaw: yaw, translation: .zero).applying(center)
        return RigidYaw(
            yaw: yaw,
            translation: Vec3(x: center.x - rotated.x, y: 0, z: center.z - rotated.z)
        )
    }
}

public struct RoomPlacement: Codable, Equatable, Sendable, Identifiable {
    public var roomId: UUID
    public var yaw: Double
    public var translation: Vec3
    public var snapped: Bool

    public init(roomId: UUID, yaw: Double, translation: Vec3, snapped: Bool) {
        self.roomId = roomId
        self.yaw = yaw
        self.translation = translation
        self.snapped = snapped
    }

    public var id: UUID { roomId }

    public var transform: RigidYaw {
        RigidYaw(yaw: yaw, translation: translation)
    }

    public func applying(to pin: DevicePin) -> DevicePin {
        var copy = pin
        copy.position = transform.applying(pin.position)
        return copy
    }
}

public struct RoomOverlap: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// Two scans cover the same footprint, so one copy has to go.
        case duplicate
        /// The footprints still cut through each other after snapping.
        case unresolved
    }

    public var roomIds: [UUID]
    public var kind: Kind
    public var ratio: Double

    public init(roomIds: [UUID], kind: Kind, ratio: Double) {
        self.roomIds = roomIds
        self.kind = kind
        self.ratio = ratio
    }

    public var id: String {
        roomIds.map(\.uuidString).sorted().joined(separator: "/")
    }

    /// Button titles for the two scans. Same names stay distinct ("the earlier Anna").
    public func choices(in home: Home) -> [RoomOverlapChoice] {
        let named: [(id: UUID, name: String)] = roomIds.compactMap { id in
            guard let name = home.room(id: id)?.name else { return nil }
            return (id, name)
        }
        return named.enumerated().map { index, room in
            let sameName = named.filter { $0.name == room.name }.count > 1
            guard sameName else { return RoomOverlapChoice(id: room.id, title: "Keep \(room.name)") }
            let ordinal = named[..<index].filter { $0.name == room.name }.count
            let word = ["earlier", "later", "third"][min(ordinal, 2)]
            return RoomOverlapChoice(id: room.id, title: "Keep the \(word) \(room.name)")
        }
    }
}

public struct RoomOverlapChoice: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String

    public init(id: UUID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct RoomAlignmentResult: Equatable, Sendable {
    public var placements: [RoomPlacement]
    public var overlaps: [RoomOverlap]
    /// The StructureBuilder shell still has the doubled walls, so the viewer
    /// should draw the placed rooms instead of that model.
    public var replacedShell: Bool

    public init(placements: [RoomPlacement], overlaps: [RoomOverlap], replacedShell: Bool) {
        self.placements = placements
        self.overlaps = overlaps
        self.replacedShell = replacedShell
    }

    public static let none = RoomAlignmentResult(placements: [], overlaps: [], replacedShell: false)

    public var hidesMergedModel: Bool {
        replacedShell || !overlaps.isEmpty || placements.contains { $0.snapped }
    }

    public var changesDisplay: Bool {
        guard !placements.isEmpty else { return false }
        return hidesMergedModel || placements.contains { !$0.transform.isNearIdentity }
    }

    public func placement(for roomId: UUID) -> RoomPlacement? {
        placements.first { $0.roomId == roomId }
    }

    /// The later scan in each duplicate pair. The earlier one stays visible.
    public var suppressedRoomIds: [UUID] {
        var hidden: [UUID] = []
        for overlap in overlaps where overlap.kind == .duplicate {
            for id in overlap.roomIds.dropFirst() where !hidden.contains(id) {
                hidden.append(id)
            }
        }
        return hidden
    }
}

extension FloorPlan {
    public func transformed(by rigid: RigidYaw) -> FloorPlan {
        FloorPlan(
            walls: walls.map { wall in
                var copy = wall
                copy.start = rigid.applying(wall.start)
                copy.end = rigid.applying(wall.end)
                return copy
            },
            openings: openings.map { opening in
                var copy = opening
                copy.center = rigid.applying(opening.center)
                copy.yaw = opening.yaw + rigid.yaw
                return copy
            },
            floors: floors.map { floor in
                var copy = floor
                copy.corners = floor.corners.map { rigid.applying($0) }
                return copy
            },
            objects: objects.map { object in
                var copy = object
                copy.center = rigid.applying(object.center)
                copy.yaw = object.yaw + rigid.yaw
                return copy
            }
        )
    }
}

public enum RoomFootprint {
    /// Floor polygon when the scan has one, otherwise the convex hull of the walls.
    public static func polygon(of plan: FloorPlan) -> [Vec3] {
        let floorPoints = plan.floors.flatMap(\.corners)
        let points = floorPoints.count >= 3 ? floorPoints : plan.walls.flatMap { [$0.start, $0.end] }
        return convexHull(points)
    }

    /// Intersection area divided by the smaller footprint. Zero means the rooms
    /// only touch, or miss each other. One means the smaller room sits inside the other.
    public static func overlapRatio(_ a: FloorPlan, _ b: FloorPlan) -> Double {
        let polygonA = polygon(of: a)
        let polygonB = polygon(of: b)
        let areaA = abs(signedArea(polygonA))
        let areaB = abs(signedArea(polygonB))
        let denominator = min(areaA, areaB)
        guard denominator > 1e-4 else { return 0 }
        return intersectionArea(polygonA, polygonB) / denominator
    }

    static func convexHull(_ points: [Vec3]) -> [Vec3] {
        let sorted = unique(points).sorted { lhs, rhs in
            lhs.x == rhs.x ? lhs.z < rhs.z : lhs.x < rhs.x
        }
        guard sorted.count >= 3 else { return sorted }
        func cross(_ origin: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
            (a.x - origin.x) * (b.z - origin.z) - (a.z - origin.z) * (b.x - origin.x)
        }
        var lower: [Vec3] = []
        for point in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 1e-9 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [Vec3] = []
        for point in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 1e-9 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        let hull = lower + upper
        return signedArea(hull) < 0 ? hull.reversed() : hull
    }

    private static func unique(_ points: [Vec3]) -> [Vec3] {
        var kept: [Vec3] = []
        for point in points {
            let seen = kept.contains { hypot(point.x - $0.x, point.z - $0.z) < 1e-6 }
            if !seen { kept.append(point) }
        }
        return kept
    }

    static func signedArea(_ corners: [Vec3]) -> Double {
        guard corners.count >= 3 else { return 0 }
        var sum = 0.0
        for index in corners.indices {
            let next = corners[(index + 1) % corners.count]
            sum += corners[index].x * next.z - next.x * corners[index].z
        }
        return sum / 2
    }

    static func intersectionArea(_ subject: [Vec3], _ clip: [Vec3]) -> Double {
        var output = convexHull(subject)
        let clip = convexHull(clip)
        guard output.count >= 3, clip.count >= 3 else { return 0 }
        for index in clip.indices {
            let start = clip[index]
            let end = clip[(index + 1) % clip.count]
            let input = output
            output = []
            guard let first = input.last else { break }
            var previous = first
            for point in input {
                let pointInside = inside(point, edgeStart: start, edgeEnd: end)
                let previousInside = inside(previous, edgeStart: start, edgeEnd: end)
                if pointInside {
                    if !previousInside, let hit = segmentIntersection(previous, point, start, end) {
                        output.append(hit)
                    }
                    output.append(point)
                } else if previousInside, let hit = segmentIntersection(previous, point, start, end) {
                    output.append(hit)
                }
                previous = point
            }
        }
        return abs(signedArea(output))
    }

    private static func inside(_ point: Vec3, edgeStart: Vec3, edgeEnd: Vec3) -> Bool {
        let cross = (edgeEnd.x - edgeStart.x) * (point.z - edgeStart.z)
            - (edgeEnd.z - edgeStart.z) * (point.x - edgeStart.x)
        return cross >= -1e-7
    }

    private static func segmentIntersection(_ p1: Vec3, _ p2: Vec3, _ q1: Vec3, _ q2: Vec3) -> Vec3? {
        let r = Vec3(x: p2.x - p1.x, y: 0, z: p2.z - p1.z)
        let s = Vec3(x: q2.x - q1.x, y: 0, z: q2.z - q1.z)
        let denominator = r.x * s.z - r.z * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let delta = Vec3(x: q1.x - p1.x, y: 0, z: q1.z - p1.z)
        let t = (delta.x * s.z - delta.z * s.x) / denominator
        return Vec3(x: p1.x + t * r.x, y: p1.y, z: p1.z + t * r.z)
    }
}

/// Places each scan on one floor and reports rooms that still occupy the same footprint.
///
/// StructureBuilder writes one shell. It does not return the rigid move it applied
/// to each scan, and it keeps both copies when two scans are the same room. This
/// type recovers that move from the shell (or from doorways, when the shell never
/// separated the scans) and then either snaps a room onto the shared wall or flags
/// the pair as a duplicate.
public enum RoomAlignment {
    public static func align(
        rooms: [Room],
        placedPlans: [FloorPlan] = [],
        shell: FloorPlan? = nil
    ) -> RoomAlignmentResult {
        guard rooms.count > 1 else { return .none }
        if let placed = match(rooms: rooms, to: placedPlans), placed.meanError < 0.6 {
            if let separated = separatePile(rooms, placed.transforms) {
                return separated
            }
            return resolve(rooms, placed.transforms, markAllSnapped: false)
        }
        if let shell, let matched = match(rooms: rooms, to: [shell]), matched.meanError < 0.5 {
            if let separated = separatePile(rooms, matched.transforms) {
                return separated
            }
            return resolve(rooms, matched.transforms, markAllSnapped: false)
        }
        let identityCount = overlapCount(rooms, identityMap(rooms), minimum: 0.08)
        if var seated = seatByDoors(rooms) {
            for room in rooms where seated[room.id] == nil {
                seated[room.id] = .identity
            }
            if overlapCount(rooms, seated, minimum: 0.08) < identityCount {
                return resolve(rooms, seated, markAllSnapped: true)
            }
        }
        return .none
    }

    /// A pose that stacks every room is only worth keeping when those rooms are
    /// duplicate scans. Different rooms piled on the origin get another try via doorways.
    private static func separatePile(_ rooms: [Room], _ transforms: [UUID: RigidYaw]) -> RoomAlignmentResult? {
        let found = pairs(rooms, transforms)
        let possible = sameFloorPairCount(rooms)
        guard possible > 0, found.count == possible, found.allSatisfy({ $0.ratio >= 0.5 }) else { return nil }
        guard found.contains(where: { !isDuplicate($0) }) else { return nil }
        guard var seated = seatByDoors(rooms) else { return nil }
        for room in rooms where seated[room.id] == nil {
            seated[room.id] = .identity
        }
        guard overlapCount(rooms, seated, minimum: 0.08) < found.filter({ $0.ratio >= 0.08 }).count else { return nil }
        return resolve(rooms, seated, markAllSnapped: true)
    }

    /// Stored placements win. A home combined before placements existed is aligned
    /// from its overview shell so the doubled room is still caught on open.
    /// The shell match is cached per home revision; a view calls this more than once.
    public static func applied(to home: Home) -> RoomAlignmentResult {
        if let structure = home.structure {
            let storedPlacements = structure.placements ?? []
            let storedOverlaps = structure.overlaps ?? []
            if !storedPlacements.isEmpty || !storedOverlaps.isEmpty {
                let snapped = storedPlacements.contains { $0.snapped }
                return RoomAlignmentResult(
                    placements: storedPlacements,
                    overlaps: storedOverlaps,
                    replacedShell: structure.shellWasRebuilt == true || snapped || !storedOverlaps.isEmpty
                )
            }
        }
        guard let shell = home.structure?.overviewFloorPlan, !shell.isEmpty,
              !home.coordinatesAreUnified, home.rooms.count > 1 else {
            return .none
        }
        let key = cacheKey(for: home)
        cacheLock.lock()
        if let cached = inferredCache[key] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()
        let inferred = align(rooms: home.rooms, shell: shell)
        cacheLock.lock()
        inferredCache[key] = inferred
        cacheLock.unlock()
        return inferred
    }

    private static let cacheLock = NSLock()
    private static var inferredCache: [String: RoomAlignmentResult] = [:]

    private static func cacheKey(for home: Home) -> String {
        let rooms = home.rooms.map { room in
            let floor = room.floor.map(String.init) ?? "-"
            return "\(room.id.uuidString):\(floor):\(room.floorPlan.walls.count):\(room.floorPlan.floors.count)"
        }.joined(separator: ",")
        let walls = home.structure?.overviewFloorPlan?.walls.count ?? 0
        return "\(home.id.uuidString)|\(home.updatedAt.timeIntervalSince1970)|\(walls)|\(rooms)"
    }

    private static func resolve(
        _ rooms: [Room],
        _ transforms: [UUID: RigidYaw],
        markAllSnapped: Bool
    ) -> RoomAlignmentResult {
        var current = transforms
        var snapped = Set<UUID>()
        for pair in pairs(rooms, current) where pair.ratio >= 0.05 && !isDuplicate(pair) {
            let moving = pair.later
            let before = current[moving.id] ?? .identity
            guard let adjusted = snap(moving, transform: before, rooms: rooms, transforms: current) else { continue }
            let after = overlapAgainst(moving, transform: adjusted, rooms: rooms, transforms: current)
            if after < min(pair.ratio, 0.12) {
                current[moving.id] = adjusted
                snapped.insert(moving.id)
            }
        }
        var overlaps: [RoomOverlap] = []
        for pair in pairs(rooms, current) where pair.ratio >= 0.08 {
            let kind: RoomOverlap.Kind = isDuplicate(pair) ? .duplicate : .unresolved
            overlaps.append(RoomOverlap(roomIds: [pair.earlier.id, pair.later.id], kind: kind, ratio: pair.ratio))
        }
        let placements = rooms.map { room in
            let transform = current[room.id] ?? .identity
            return RoomPlacement(
                roomId: room.id,
                yaw: transform.yaw,
                translation: transform.translation,
                snapped: markAllSnapped || snapped.contains(room.id)
            )
        }
        return RoomAlignmentResult(
            placements: placements,
            overlaps: overlaps,
            replacedShell: markAllSnapped || !snapped.isEmpty || !overlaps.isEmpty
        )
    }

    private struct Fit {
        var transforms: [UUID: RigidYaw]
        var meanError: Double
    }

    private struct OverlapPair {
        var earlier: Room
        var later: Room
        var ratio: Double
    }

    private static func match(rooms: [Room], to plans: [FloorPlan]) -> Fit? {
        guard !plans.isEmpty, plans.count >= rooms.count || plans.count == 1 else { return nil }
        if plans.count == rooms.count, !plansIdentical(plans) {
            var transforms: [UUID: RigidYaw] = [:]
            var errors: [Double] = []
            var matched = true
            for (room, plan) in zip(rooms, plans) {
                let fit = register(source: room.floorPlan, target: plan)
                if fit.error > 0.85 {
                    matched = false
                    break
                }
                transforms[room.id] = fit.transform
                errors.append(fit.error)
            }
            if matched, errors.count == rooms.count {
                return Fit(transforms: transforms, meanError: mean(errors))
            }
        }
        let targets = plans.count == 1 ? plans : plans
        var transforms: [UUID: RigidYaw] = [:]
        var errors: [Double] = []
        var unused = Array(targets.indices)
        let shareOneShell = targets.count == 1
        for room in rooms {
            var best: (index: Int, transform: RigidYaw, error: Double)?
            let candidates = shareOneShell ? [0] : unused
            for index in candidates {
                let fit = register(source: room.floorPlan, target: targets[index])
                if best == nil || fit.error < best!.error {
                    best = (index, fit.transform, fit.error)
                }
            }
            guard let best, best.error < 0.85 else { return nil }
            if !shareOneShell {
                unused.removeAll { $0 == best.index }
            }
            transforms[room.id] = best.transform
            errors.append(best.error)
        }
        guard errors.count == rooms.count else { return nil }
        return Fit(transforms: transforms, meanError: mean(errors))
    }

    private static func plansIdentical(_ plans: [FloorPlan]) -> Bool {
        guard let first = plans.first else { return false }
        return plans.dropFirst().allSatisfy { $0 == first }
    }

    static func register(source: FloorPlan, target: FloorPlan) -> (transform: RigidYaw, error: Double) {
        let sourceWalls = source.walls.filter { $0.length > 0.25 }
        let targetWalls = target.walls.filter { $0.length > 0.25 }
        guard !sourceWalls.isEmpty, !targetWalls.isEmpty else {
            return (.identity, .greatestFiniteMagnitude)
        }
        var best = (RigidYaw.identity, Double.greatestFiniteMagnitude)
        for sourceWall in sourceWalls {
            for targetWall in targetWalls {
                let delta = wallAngle(targetWall) - wallAngle(sourceWall)
                for extra in [0.0, Double.pi] {
                    let yaw = wrapAngle(delta + extra)
                    let rotated = RigidYaw(yaw: yaw, translation: .zero).applying(midpoint(sourceWall))
                    let targetMid = midpoint(targetWall)
                    let transform = RigidYaw(
                        yaw: yaw,
                        translation: Vec3(x: targetMid.x - rotated.x, y: 0, z: targetMid.z - rotated.z)
                    )
                    let error = wallError(source: source, target: target, transform: transform)
                    if error < best.1 - 1e-6 || (abs(error - best.1) <= 1e-6 && abs(yaw) < abs(best.0.yaw)) {
                        best = (transform, error)
                    }
                }
            }
        }
        return best
    }

    private static func seatByDoors(_ rooms: [Room]) -> [UUID: RigidYaw]? {
        guard let anchor = rooms.first else { return nil }
        var placed: [UUID: RigidYaw] = [anchor.id: .identity]
        var pending = Array(rooms.dropFirst())
        var guardCount = pending.count * max(pending.count, 1) + 2
        while !pending.isEmpty && guardCount > 0 {
            guardCount -= 1
            var best: (index: Int, transform: RigidYaw, overlap: Double)?
            for (index, room) in pending.enumerated() {
                for other in rooms where sameFloor(room, other) {
                    guard let otherTransform = placed[other.id] else { continue }
                    let anchorPlan = other.floorPlan.transformed(by: otherTransform)
                    let anchorCenter = centroid(of: anchorPlan)
                    for anchorOpening in anchorPlan.openings where connects(anchorOpening) {
                        for movingOpening in room.floorPlan.openings where connects(movingOpening) {
                            let transform = join(
                                movingDoor: movingOpening,
                                movingCentroid: centroid(of: room.floorPlan),
                                anchorDoor: anchorOpening,
                                anchorCentroid: anchorCenter
                            )
                            let overlap = overlapAgainst(room, transform: transform, rooms: rooms, transforms: placed)
                            let candidate = (index, transform, overlap)
                            if best == nil || overlap < best!.overlap - 1e-4 {
                                best = candidate
                            }
                        }
                    }
                }
            }
            guard let best, best.overlap < 0.2 else { break }
            placed[pending[best.index].id] = best.transform
            pending.remove(at: best.index)
        }
        guard placed.count > 1 else { return nil }
        return placed
    }

    private static func snap(
        _ moving: Room,
        transform: RigidYaw,
        rooms: [Room],
        transforms: [UUID: RigidYaw]
    ) -> RigidYaw? {
        let movingPlan = moving.floorPlan.transformed(by: transform)
        var best: (score: Double, delta: Double, target: WallSegment, moving: WallSegment, anchor: FloorPlan)?
        for other in rooms where other.id != moving.id && sameFloor(moving, other) {
            guard let otherTransform = transforms[other.id] else { continue }
            let anchor = other.floorPlan.transformed(by: otherTransform)
            for movingWall in movingPlan.walls where movingWall.length > 0.4 {
                for target in anchor.walls where target.length > 0.4 {
                    let parallel = undirectedAngle(movingWall, target)
                    guard parallel < 15 * .pi / 180 else { continue }
                    let gap = lineGap(from: movingWall, to: target)
                    guard gap < 1.3 else { continue }
                    let shared = projectedOverlap(movingWall, target)
                    guard shared > 0.45 else { continue }
                    let score = shared / (gap + 0.05)
                    if best == nil || score > best!.score {
                        best = (score, parallelDelta(movingWall, target), target, movingWall, anchor)
                    }
                }
            }
        }
        guard let best else { return nil }
        let around = centroid(of: movingPlan)
        var corrected = RigidYaw.rotation(around: around, by: best.delta).composed(after: transform)
        guard let alignedWall = moving.floorPlan.transformed(by: corrected).walls.first(where: { $0.id == best.moving.id }) else {
            return nil
        }
        let shift = perpendicular(from: alignedWall, to: best.target)
        corrected.translation = Vec3(
            x: corrected.translation.x - shift.x,
            y: 0,
            z: corrected.translation.z - shift.z
        )
        let settled = moving.floorPlan.transformed(by: corrected)
        let anchorCenter = centroid(of: best.anchor)
        let mid = midpoint(best.target)
        let inward = Vec3(x: anchorCenter.x - mid.x, y: 0, z: anchorCenter.z - mid.z).normalized()
        let movedCenter = centroid(of: settled)
        let side = (movedCenter.x - mid.x) * inward.x + (movedCenter.z - mid.z) * inward.z
        if side > 0.05 {
            corrected = RigidYaw.rotation(around: mid, by: .pi).composed(after: corrected)
        }
        let finalPlan = moving.floorPlan.transformed(by: corrected)
        guard let finalWall = finalPlan.walls.first(where: { $0.id == best.moving.id }) else { return nil }
        guard lineGap(from: finalWall, to: best.target) < 0.35 else { return nil }
        return corrected
    }

    private static func isDuplicate(_ pair: OverlapPair) -> Bool {
        shapeSimilarity(pair.earlier.floorPlan, pair.later.floorPlan) >= 0.8 && pair.ratio >= 0.45
    }

    private static func pairs(_ rooms: [Room], _ transforms: [UUID: RigidYaw]) -> [OverlapPair] {
        var found: [OverlapPair] = []
        for left in rooms.indices {
            for right in rooms.indices where right > left && sameFloor(rooms[left], rooms[right]) {
                let earlier = rooms[left]
                let later = rooms[right]
                let leftPlan = earlier.floorPlan.transformed(by: transforms[earlier.id] ?? .identity)
                let rightPlan = later.floorPlan.transformed(by: transforms[later.id] ?? .identity)
                found.append(OverlapPair(
                    earlier: earlier,
                    later: later,
                    ratio: RoomFootprint.overlapRatio(leftPlan, rightPlan)
                ))
            }
        }
        return found
    }

    private static func sameFloor(_ lhs: Room, _ rhs: Room) -> Bool {
        lhs.floor == rhs.floor
    }

    private static func sameFloorPairCount(_ rooms: [Room]) -> Int {
        var count = 0
        for left in rooms.indices {
            for right in rooms.indices where right > left && sameFloor(rooms[left], rooms[right]) {
                count += 1
            }
        }
        return count
    }

    private static func overlapCount(_ rooms: [Room], _ transforms: [UUID: RigidYaw], minimum: Double) -> Int {
        pairs(rooms, transforms).filter { $0.ratio >= minimum }.count
    }

    private static func overlapAgainst(
        _ room: Room,
        transform: RigidYaw,
        rooms: [Room],
        transforms: [UUID: RigidYaw]
    ) -> Double {
        let plan = room.floorPlan.transformed(by: transform)
        var worst = 0.0
        for other in rooms where other.id != room.id && sameFloor(room, other) {
            guard let otherTransform = transforms[other.id] else { continue }
            let otherPlan = other.floorPlan.transformed(by: otherTransform)
            worst = max(worst, RoomFootprint.overlapRatio(plan, otherPlan))
        }
        return worst
    }

    private static func identityMap(_ rooms: [Room]) -> [UUID: RigidYaw] {
        Dictionary(uniqueKeysWithValues: rooms.map { ($0.id, RigidYaw.identity) })
    }

    private static func shapeSimilarity(_ a: FloorPlan, _ b: FloorPlan) -> Double {
        let areaA = max(abs(RoomFootprint.signedArea(RoomFootprint.polygon(of: a))), 0.01)
        let areaB = max(abs(RoomFootprint.signedArea(RoomFootprint.polygon(of: b))), 0.01)
        let areaScore = 1 - abs(areaA - areaB) / max(areaA, areaB)
        let lengthsA = a.walls.map(\.length).sorted()
        let lengthsB = b.walls.map(\.length).sorted()
        let count = max(lengthsA.count, lengthsB.count, 1)
        var difference = 0.0
        for index in 0..<count {
            let left = index < lengthsA.count ? lengthsA[index] : 0
            let right = index < lengthsB.count ? lengthsB[index] : 0
            difference += abs(left - right)
        }
        let span = max(lengthsA.reduce(0, +), lengthsB.reduce(0, +), 0.01)
        let lengthScore = 1 - min(difference / span, 1)
        return 0.5 * areaScore + 0.5 * lengthScore
    }

    private static func wallError(source: FloorPlan, target: FloorPlan, transform: RigidYaw) -> Double {
        let moved = source.transformed(by: transform).walls.map(midpoint)
        let targets = target.walls.map(midpoint)
        guard !moved.isEmpty, !targets.isEmpty else { return .greatestFiniteMagnitude }
        let total = moved.reduce(0.0) { partial, point in
            partial + (targets.map { hypot(point.x - $0.x, point.z - $0.z) }.min() ?? 0)
        }
        return total / Double(moved.count)
    }

    private static func centroid(of plan: FloorPlan) -> Vec3 {
        let corners = RoomFootprint.polygon(of: plan)
        guard !corners.isEmpty else { return .zero }
        let sum = corners.reduce(Vec3.zero) { $0 + $1 }
        return sum.scaled(1 / Double(corners.count))
    }

    private static func connects(_ opening: Opening) -> Bool {
        opening.kind == .door || opening.kind == .opening
    }

    private static func join(
        movingDoor: Opening,
        movingCentroid: Vec3,
        anchorDoor: Opening,
        anchorCentroid: Vec3
    ) -> RigidYaw {
        let anchorNormal = outwardNormal(of: anchorDoor, centroid: anchorCentroid)
        let movingNormal = outwardNormal(of: movingDoor, centroid: movingCentroid)
        let yaw = wrapAngle(Trig.atan2(anchorNormal.z, anchorNormal.x) + .pi - Trig.atan2(movingNormal.z, movingNormal.x))
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

    private static func wallAngle(_ wall: WallSegment) -> Double {
        Trig.atan2(wall.end.z - wall.start.z, wall.end.x - wall.start.x)
    }

    private static func undirectedAngle(_ a: WallSegment, _ b: WallSegment) -> Double {
        let delta = abs(wrapAngle(wallAngle(a) - wallAngle(b)))
        return min(delta, .pi - delta)
    }

    private static func parallelDelta(_ moving: WallSegment, _ target: WallSegment) -> Double {
        var delta = wrapAngle(wallAngle(target) - wallAngle(moving))
        if delta > .pi / 2 { delta -= .pi }
        if delta < -.pi / 2 { delta += .pi }
        return delta
    }

    private static func midpoint(_ wall: WallSegment) -> Vec3 {
        Vec3(
            x: (wall.start.x + wall.end.x) / 2,
            y: (wall.start.y + wall.end.y) / 2,
            z: (wall.start.z + wall.end.z) / 2
        )
    }

    private static func direction(_ wall: WallSegment) -> Vec3 {
        Vec3(x: wall.end.x - wall.start.x, y: 0, z: wall.end.z - wall.start.z).normalized()
    }

    private static func lineGap(from wall: WallSegment, to target: WallSegment) -> Double {
        let offset = perpendicular(from: wall, to: target)
        return hypot(offset.x, offset.z)
    }

    private static func perpendicular(from wall: WallSegment, to target: WallSegment) -> Vec3 {
        let axis = direction(target)
        let mid = midpoint(wall)
        let relative = Vec3(x: mid.x - target.start.x, y: 0, z: mid.z - target.start.z)
        let along = axis.x * relative.x + axis.z * relative.z
        return Vec3(x: relative.x - axis.x * along, y: 0, z: relative.z - axis.z * along)
    }

    private static func projectedOverlap(_ a: WallSegment, _ b: WallSegment) -> Double {
        let axis = direction(b)
        func span(_ wall: WallSegment) -> (Double, Double) {
            let start = axis.x * wall.start.x + axis.z * wall.start.z
            let end = axis.x * wall.end.x + axis.z * wall.end.z
            return (min(start, end), max(start, end))
        }
        let left = span(a)
        let right = span(b)
        return max(0, min(left.1, right.1) - max(left.0, right.0))
    }

    private static func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

fileprivate func wrapAngle(_ angle: Double) -> Double {
    var value = angle
    let turn = Double.pi * 2
    while value > .pi { value -= turn }
    while value < -.pi { value += turn }
    return value
}
