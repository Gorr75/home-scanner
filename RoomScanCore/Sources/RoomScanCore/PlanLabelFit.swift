import Foundation

/// Decides which room names fit on a small plan preview.
///
/// A name is kept when its measured size sits inside the room, with a margin,
/// and does not overlap a name already kept. Larger rooms are considered first
/// so a living room keeps its name ahead of a closet drawn on top of it.
public enum PlanLabelFit {
    public struct Span: Equatable, Sendable {
        public var minX: Double
        public var minY: Double
        public var maxX: Double
        public var maxY: Double

        public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
            self.minX = minX
            self.minY = minY
            self.maxX = maxX
            self.maxY = maxY
        }

        public var width: Double { maxX - minX }
        public var height: Double { maxY - minY }
        public var area: Double { max(0, width) * max(0, height) }
    }

    public struct LabelSize: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    /// Indices into `rooms` / `labelSizes`, in ascending order.
    /// Extra entries past the shorter array are ignored.
    public static func accepted(
        rooms: [Span],
        labelSizes: [LabelSize],
        margin: Double = 4,
        gap: Double = 4
    ) -> [Int] {
        let inset = max(0, margin)
        let separation = max(0, gap)
        let count = min(rooms.count, labelSizes.count)
        var fitting: [(index: Int, label: Span, area: Double)] = []
        fitting.reserveCapacity(count)
        for index in 0..<count {
            let room = rooms[index]
            let size = labelSizes[index]
            guard size.width > 0, size.height > 0 else { continue }
            guard size.width <= room.width - inset * 2, size.height <= room.height - inset * 2 else { continue }
            let midX = (room.minX + room.maxX) / 2
            let midY = (room.minY + room.maxY) / 2
            let label = Span(
                minX: midX - size.width / 2,
                minY: midY - size.height / 2,
                maxX: midX + size.width / 2,
                maxY: midY + size.height / 2
            )
            fitting.append((index, label, room.area))
        }
        fitting.sort { lhs, rhs in
            if lhs.area == rhs.area { return lhs.index < rhs.index }
            return lhs.area > rhs.area
        }
        var occupied: [Span] = []
        var kept: [Int] = []
        for entry in fitting {
            if occupied.contains(where: { overlaps(entry.label, $0, gap: separation) }) { continue }
            occupied.append(entry.label)
            kept.append(entry.index)
        }
        return kept.sorted()
    }

    private static func overlaps(_ a: Span, _ b: Span, gap: Double) -> Bool {
        a.minX < b.maxX + gap
            && b.minX < a.maxX + gap
            && a.minY < b.maxY + gap
            && b.minY < a.maxY + gap
    }
}
