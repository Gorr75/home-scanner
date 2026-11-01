import Foundation

public struct HeatSample: Equatable, Sendable {
    public var x: Double
    public var z: Double
    public var value: Double

    public init(x: Double, z: Double, value: Double) {
        self.x = x
        self.z = z
        self.value = value
    }
}

public enum Heatmap {
    /// Inverse-distance weighting on the floor. One sample paints the whole plan with that value.
    public static func value(atX x: Double, z: Double, samples: [HeatSample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        if samples.count == 1 { return samples[0].value }
        var numerator = 0.0
        var denominator = 0.0
        for sample in samples {
            let dx = x - sample.x
            let dz = z - sample.z
            let distanceSquared = dx * dx + dz * dz
            if distanceSquared < 0.0025 {
                return sample.value
            }
            let weight = 1 / distanceSquared
            numerator += weight * sample.value
            denominator += weight
        }
        guard denominator > 0 else { return nil }
        return numerator / denominator
    }

    public static func grid(
        samples: [HeatSample],
        bounds: AABB,
        columns: Int = 16,
        rows: Int = 16
    ) -> [[Double?]] {
        let columnCount = max(columns, 1)
        let rowCount = max(rows, 1)
        var cells: [[Double?]] = []
        for row in 0..<rowCount {
            var line: [Double?] = []
            let z = bounds.min.z + (Double(row) + 0.5) / Double(rowCount) * max(bounds.size.z, 0.001)
            for column in 0..<columnCount {
                let x = bounds.min.x + (Double(column) + 0.5) / Double(columnCount) * max(bounds.size.x, 0.001)
                line.append(value(atX: x, z: z, samples: samples))
            }
            cells.append(line)
        }
        return cells
    }

    public static func range(of samples: [HeatSample]) -> (min: Double, max: Double)? {
        guard let first = samples.first else { return nil }
        return samples.reduce((first.value, first.value)) { partial, sample in
            (Swift.min(partial.0, sample.value), Swift.max(partial.1, sample.value))
        }
    }
}
