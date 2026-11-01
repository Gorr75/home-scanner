import Foundation

public struct ObjectChange: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case added
        case removed
        /// Horizontal distance in meters.
        case moved(Double)
        case unchanged
    }

    public var kind: Kind
    public var object: PlacedObject
    public var matched: PlacedObject?

    public init(kind: Kind, object: PlacedObject, matched: PlacedObject? = nil) {
        self.kind = kind
        self.object = object
        self.matched = matched
    }

    public var id: UUID { object.id }

    public var summary: String {
        let name = ObjectLabels.title(for: object.category)
        switch kind {
        case .added:
            return "Added \(name)"
        case .removed:
            return "Removed \(name)"
        case .moved(let distance):
            return "Moved \(name) \(ObjectLabels.meters(distance)) m"
        case .unchanged:
            return name
        }
    }
}

public enum ScanDiff {
    /// Pair objects that share a RoomPlan category. The nearest previous object wins.
    /// A pair farther than `moveThreshold` meters on the floor is marked moved.
    public static func compare(
        previous: FloorPlan,
        current: FloorPlan,
        moveThreshold: Double = 0.25
    ) -> [ObjectChange] {
        var unused = previous.objects
        var changes: [ObjectChange] = []
        for object in current.objects {
            let bestIndex = unused.indices
                .filter { unused[$0].category == object.category }
                .min { distance(unused[$0], object) < distance(unused[$1], object) }
            if let bestIndex {
                let previousObject = unused.remove(at: bestIndex)
                let meters = distance(previousObject, object)
                if meters > moveThreshold {
                    changes.append(ObjectChange(kind: .moved(meters), object: object, matched: previousObject))
                } else {
                    changes.append(ObjectChange(kind: .unchanged, object: object, matched: previousObject))
                }
            } else {
                changes.append(ObjectChange(kind: .added, object: object, matched: nil))
            }
        }
        for object in unused {
            changes.append(ObjectChange(kind: .removed, object: object, matched: nil))
        }
        return changes
    }

    public static func counts(_ changes: [ObjectChange]) -> (added: Int, removed: Int, moved: Int) {
        var added = 0
        var removed = 0
        var moved = 0
        for change in changes {
            switch change.kind {
            case .added: added += 1
            case .removed: removed += 1
            case .moved: moved += 1
            case .unchanged: break
            }
        }
        return (added, removed, moved)
    }

    private static func distance(_ lhs: PlacedObject, _ rhs: PlacedObject) -> Double {
        let dx = lhs.center.x - rhs.center.x
        let dz = lhs.center.z - rhs.center.z
        return (dx * dx + dz * dz).squareRoot()
    }
}
