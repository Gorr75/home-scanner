import Foundation

public enum ObjectLabels {
    /// RoomPlan category token to a short label. Unknown tokens are shown with spaces.
    public static func title(for category: String) -> String {
        switch category {
        case "storage": return "Storage"
        case "refrigerator": return "Refrigerator"
        case "stove": return "Stove"
        case "bed": return "Bed"
        case "sink": return "Sink"
        case "washer_dryer": return "Washer / dryer"
        case "toilet": return "Toilet"
        case "bathtub": return "Bathtub"
        case "oven": return "Oven"
        case "dishwasher": return "Dishwasher"
        case "table": return "Table"
        case "sofa": return "Sofa"
        case "chair": return "Chair"
        case "fireplace": return "Fireplace"
        case "television": return "Television"
        case "stairs": return "Stairs"
        case "unknown", "": return "Object"
        default:
            return category
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    /// Width × height × depth, in meters.
    public static func size(_ object: PlacedObject) -> String {
        "\(meters(object.dimensions.x)) × \(meters(object.dimensions.y)) × \(meters(object.dimensions.z)) m"
    }

    /// Floor footprint, width × depth.
    public static func footprint(_ object: PlacedObject) -> String {
        "\(meters(object.dimensions.x)) × \(meters(object.dimensions.z)) m"
    }

    public static func meters(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
}
