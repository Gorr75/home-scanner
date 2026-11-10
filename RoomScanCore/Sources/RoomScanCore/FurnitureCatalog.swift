import Foundation

public enum FurnitureShape: String, Equatable, Sendable {
    case box
    case cylinder
}

public struct FurnitureMaterial: Equatable, Sendable {
    public var name: String
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    public var roughness: Double
    public var metallic: Double

    public init(
        name: String,
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1,
        roughness: Double = 0.8,
        metallic: Double = 0
    ) {
        self.name = name
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
        self.roughness = roughness
        self.metallic = metallic
    }

    public var rgba: [Double] { [red, green, blue, alpha] }
}

public struct FurniturePart: Equatable, Sendable {
    public var shape: FurnitureShape
    /// Center relative to the item origin. The origin is the center of the bottom face.
    public var center: Vec3
    /// Box width, height, and depth. A cylinder uses `x` as its diameter and `y` as its height.
    public var size: Vec3
    public var material: FurnitureMaterial

    public init(shape: FurnitureShape, center: Vec3, size: Vec3, material: FurnitureMaterial) {
        self.shape = shape
        self.center = center
        self.size = size
        self.material = material
    }
}

public struct FurnitureCatalogItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// RoomPlan category this item stands in for, when the scan has a matching box.
    public var roomPlanCategory: String?
    /// Width, height, and depth at scale 1. Parts stay inside this box.
    public var nominalSize: Vec3
    public var parts: [FurniturePart]

    public init(
        id: String,
        name: String,
        roomPlanCategory: String?,
        nominalSize: Vec3,
        parts: [FurniturePart]
    ) {
        self.id = id
        self.name = name
        self.roomPlanCategory = roomPlanCategory
        self.nominalSize = nominalSize
        self.parts = parts
    }
}

/// A catalog item dropped into a room. Positions are meters in that room's scan space.
/// The origin is the center of the bottom face, so a plan tap lands on the floor.
public struct PlacedFurniture: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var catalogId: String
    public var position: Vec3
    @Quantized public var yaw: Double
    public var scale: Vec3
    /// RoomPlan object this item replaces. The scan box stays in the plan and is hidden while this is set.
    public var replacesObjectId: UUID?

    public init(
        id: UUID,
        catalogId: String,
        position: Vec3,
        yaw: Double,
        scale: Vec3 = Vec3(x: 1, y: 1, z: 1),
        replacesObjectId: UUID? = nil
    ) {
        self.id = id
        self.catalogId = catalogId
        self.position = position
        self.yaw = yaw
        self.scale = Self.clamped(scale)
        self.replacesObjectId = replacesObjectId
    }

    /// Moves a catalog item with the room. Yaw is added; scale stays put.
    public func transformed(by rigid: RigidYaw) -> PlacedFurniture {
        var copy = self
        copy.position = rigid.applying(position)
        copy.yaw += rigid.yaw
        return copy
    }

    public static func placed(catalogId: String, x: Double, z: Double, y: Double = 0) -> PlacedFurniture {
        PlacedFurniture(
            id: UUID(),
            catalogId: catalogId,
            position: Vec3(x: x, y: y, z: z),
            yaw: 0,
            scale: Vec3(x: 1, y: 1, z: 1)
        )
    }

    /// Match a scan box. Scale maps the catalog item onto the recognised dimensions.
    public static func replacing(
        _ object: PlacedObject,
        with item: FurnitureCatalogItem,
        id: UUID = UUID()
    ) -> PlacedFurniture {
        let nominal = item.nominalSize
        let scale = Vec3(
            x: object.dimensions.x / max(nominal.x, 0.05),
            y: object.dimensions.y / max(nominal.y, 0.05),
            z: object.dimensions.z / max(nominal.z, 0.05)
        )
        return PlacedFurniture(
            id: id,
            catalogId: item.id,
            position: Vec3(
                x: object.center.x,
                y: object.center.y - object.dimensions.y / 2,
                z: object.center.z
            ),
            yaw: object.yaw,
            scale: scale,
            replacesObjectId: object.id
        )
    }

    public func moved(x: Double, z: Double) -> PlacedFurniture {
        var copy = self
        copy.position = Vec3(x: x, y: position.y, z: z)
        return copy
    }

    public func rotated(by delta: Double) -> PlacedFurniture {
        var copy = self
        copy.yaw = yaw + delta
        return copy
    }

    public func scaled(by factor: Double) -> PlacedFurniture {
        var copy = self
        copy.scale = Self.clamped(
            Vec3(x: scale.x * factor, y: scale.y * factor, z: scale.z * factor)
        )
        return copy
    }

    private static func clamped(_ scale: Vec3) -> Vec3 {
        Vec3(
            x: min(5, max(0.15, scale.x)),
            y: min(5, max(0.15, scale.y)),
            z: min(5, max(0.15, scale.z))
        )
    }
}

public struct ResolvedFurniturePart: Equatable, Sendable {
    public var shape: FurnitureShape
    public var center: Vec3
    public var size: Vec3
    /// World yaw around Y, including the placement yaw.
    public var yaw: Double
    public var material: FurnitureMaterial
}

public enum FurnitureCatalog {
    public static let minimumScale = 0.15
    public static let maximumScale = 5.0

    public static let all: [FurnitureCatalogItem] = [
        sofa, armchair, diningChair, diningTable, coffeeTable, sideTable, desk,
        bed, bookshelf, lowShelf, wardrobe, floorLamp, tableLamp,
        plant, largePlant, rug, television, mediaConsole, ottoman, stool
    ]

    public static func item(id: String) -> FurnitureCatalogItem? {
        all.first { $0.id == id }
    }

    /// Preferred stand-in for a RoomPlan category, when the catalog has one.
    public static func match(for category: String) -> FurnitureCatalogItem? {
        switch category {
        case "sofa": return item(id: "sofa")
        case "chair": return item(id: "dining_chair")
        case "table": return item(id: "dining_table")
        case "bed": return item(id: "bed")
        case "television": return item(id: "television")
        case "storage": return item(id: "wardrobe")
        default: return nil
        }
    }

    /// Every part sits inside the nominal box, which is how a replacement lines up with a scan box.
    public static func partsFit(_ item: FurnitureCatalogItem, tolerance: Double = 0.001) -> Bool {
        let halfX = item.nominalSize.x / 2
        let halfZ = item.nominalSize.z / 2
        let top = item.nominalSize.y
        for part in item.parts {
            let extent = partExtent(part)
            let minX = part.center.x - extent.x
            let maxX = part.center.x + extent.x
            let minY = part.center.y - extent.y
            let maxY = part.center.y + extent.y
            let minZ = part.center.z - extent.z
            let maxZ = part.center.z + extent.z
            if minX < -halfX - tolerance || maxX > halfX + tolerance { return false }
            if minZ < -halfZ - tolerance || maxZ > halfZ + tolerance { return false }
            if minY < -tolerance || maxY > top + tolerance { return false }
        }
        return !item.parts.isEmpty
    }

    private static func partExtent(_ part: FurniturePart) -> Vec3 {
        switch part.shape {
        case .box:
            return Vec3(x: part.size.x / 2, y: part.size.y / 2, z: part.size.z / 2)
        case .cylinder:
            let radius = part.size.x / 2
            return Vec3(x: radius, y: part.size.y / 2, z: radius)
        }
    }

    private static func box(
        _ x: Double, _ y: Double, _ z: Double,
        _ w: Double, _ h: Double, _ d: Double,
        _ material: FurnitureMaterial
    ) -> FurniturePart {
        FurniturePart(
            shape: .box,
            center: Vec3(x: x, y: y, z: z),
            size: Vec3(x: w, y: h, z: d),
            material: material
        )
    }

    private static func cylinder(
        _ x: Double, _ y: Double, _ z: Double,
        diameter: Double, height: Double,
        _ material: FurnitureMaterial
    ) -> FurniturePart {
        FurniturePart(
            shape: .cylinder,
            center: Vec3(x: x, y: y, z: z),
            size: Vec3(x: diameter, y: height, z: diameter),
            material: material
        )
    }

    private static let fabric = FurnitureMaterial(name: "fabric", red: 0.33, green: 0.40, blue: 0.44, roughness: 0.88)
    private static let fabricDeep = FurnitureMaterial(name: "fabric_deep", red: 0.22, green: 0.26, blue: 0.30, roughness: 0.9)
    private static let wood = FurnitureMaterial(name: "wood", red: 0.55, green: 0.38, blue: 0.24, roughness: 0.55)
    private static let woodDark = FurnitureMaterial(name: "wood_dark", red: 0.32, green: 0.22, blue: 0.14, roughness: 0.5)
    private static let metal = FurnitureMaterial(name: "metal", red: 0.72, green: 0.71, blue: 0.68, roughness: 0.28, metallic: 0.85)
    private static let ceramic = FurnitureMaterial(name: "ceramic", red: 0.86, green: 0.84, blue: 0.78, roughness: 0.35)
    private static let foliage = FurnitureMaterial(name: "foliage", red: 0.27, green: 0.46, blue: 0.30, roughness: 0.82)
    private static let foliageDark = FurnitureMaterial(name: "foliage_dark", red: 0.16, green: 0.32, blue: 0.20, roughness: 0.86)
    private static let linen = FurnitureMaterial(name: "linen", red: 0.90, green: 0.87, blue: 0.80, roughness: 0.92)
    private static let rugWool = FurnitureMaterial(name: "rug", red: 0.55, green: 0.29, blue: 0.25, roughness: 0.96)
    private static let screen = FurnitureMaterial(name: "screen", red: 0.07, green: 0.08, blue: 0.10, roughness: 0.12, metallic: 0.25)
    private static let glass = FurnitureMaterial(name: "glass", red: 0.62, green: 0.75, blue: 0.80, alpha: 0.45, roughness: 0.05, metallic: 0.05)

    // Sofa 2.10 × 0.84 × 0.92. Origin at the floor, centered in XZ.
    private static let sofa = FurnitureCatalogItem(
        id: "sofa",
        name: "Sofa",
        roomPlanCategory: "sofa",
        nominalSize: Vec3(x: 2.10, y: 0.84, z: 0.92),
        parts: [
            cylinder(-0.86, 0.04, -0.30, diameter: 0.06, height: 0.08, woodDark),
            cylinder(0.86, 0.04, -0.30, diameter: 0.06, height: 0.08, woodDark),
            cylinder(-0.86, 0.04, 0.30, diameter: 0.06, height: 0.08, woodDark),
            cylinder(0.86, 0.04, 0.30, diameter: 0.06, height: 0.08, woodDark),
            box(0, 0.24, -0.02, 1.90, 0.28, 0.76, woodDark),
            box(0, 0.44, 0.06, 1.78, 0.14, 0.62, fabric),
            box(0, 0.62, -0.36, 1.90, 0.36, 0.16, fabricDeep),
            box(-0.96, 0.50, 0.02, 0.14, 0.32, 0.70, fabricDeep),
            box(0.96, 0.50, 0.02, 0.14, 0.32, 0.70, fabricDeep)
        ]
    )

    private static let armchair = FurnitureCatalogItem(
        id: "armchair",
        name: "Armchair",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.86, y: 0.84, z: 0.88),
        parts: [
            cylinder(-0.30, 0.04, -0.28, diameter: 0.06, height: 0.08, woodDark),
            cylinder(0.30, 0.04, -0.28, diameter: 0.06, height: 0.08, woodDark),
            cylinder(-0.30, 0.04, 0.28, diameter: 0.06, height: 0.08, woodDark),
            cylinder(0.30, 0.04, 0.28, diameter: 0.06, height: 0.08, woodDark),
            box(0, 0.24, 0, 0.70, 0.26, 0.70, woodDark),
            box(0, 0.44, 0.06, 0.58, 0.14, 0.58, fabric),
            box(0, 0.64, -0.32, 0.70, 0.34, 0.14, fabricDeep),
            box(-0.36, 0.50, 0.02, 0.12, 0.30, 0.66, fabricDeep),
            box(0.36, 0.50, 0.02, 0.12, 0.30, 0.66, fabricDeep)
        ]
    )

    private static let diningChair = FurnitureCatalogItem(
        id: "dining_chair",
        name: "Dining chair",
        roomPlanCategory: "chair",
        nominalSize: Vec3(x: 0.46, y: 0.92, z: 0.50),
        parts: [
            cylinder(-0.16, 0.20, -0.16, diameter: 0.035, height: 0.40, wood),
            cylinder(0.16, 0.20, -0.16, diameter: 0.035, height: 0.40, wood),
            cylinder(-0.16, 0.20, 0.16, diameter: 0.035, height: 0.40, wood),
            cylinder(0.16, 0.20, 0.16, diameter: 0.035, height: 0.40, wood),
            box(0, 0.44, 0, 0.42, 0.05, 0.42, wood),
            box(0, 0.48, 0.02, 0.40, 0.04, 0.38, fabric),
            box(0, 0.70, -0.20, 0.40, 0.40, 0.04, wood)
        ]
    )

    private static let diningTable = FurnitureCatalogItem(
        id: "dining_table",
        name: "Dining table",
        roomPlanCategory: "table",
        nominalSize: Vec3(x: 1.60, y: 0.75, z: 0.90),
        parts: [
            box(0, 0.71, 0, 1.60, 0.05, 0.90, wood),
            cylinder(-0.68, 0.34, -0.34, diameter: 0.06, height: 0.68, woodDark),
            cylinder(0.68, 0.34, -0.34, diameter: 0.06, height: 0.68, woodDark),
            cylinder(-0.68, 0.34, 0.34, diameter: 0.06, height: 0.68, woodDark),
            cylinder(0.68, 0.34, 0.34, diameter: 0.06, height: 0.68, woodDark)
        ]
    )

    private static let coffeeTable = FurnitureCatalogItem(
        id: "coffee_table",
        name: "Coffee table",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 1.20, y: 0.40, z: 0.60),
        parts: [
            box(0, 0.36, 0, 1.20, 0.04, 0.60, wood),
            box(0, 0.16, 0, 1.00, 0.03, 0.42, woodDark),
            cylinder(-0.50, 0.16, -0.22, diameter: 0.04, height: 0.32, metal),
            cylinder(0.50, 0.16, -0.22, diameter: 0.04, height: 0.32, metal),
            cylinder(-0.50, 0.16, 0.22, diameter: 0.04, height: 0.32, metal),
            cylinder(0.50, 0.16, 0.22, diameter: 0.04, height: 0.32, metal)
        ]
    )

    private static let sideTable = FurnitureCatalogItem(
        id: "side_table",
        name: "Side table",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.46, y: 0.55, z: 0.46),
        parts: [
            box(0, 0.52, 0, 0.46, 0.04, 0.46, wood),
            cylinder(0, 0.25, 0, diameter: 0.04, height: 0.48, metal),
            cylinder(0, 0.03, 0, diameter: 0.28, height: 0.04, metal)
        ]
    )

    private static let desk = FurnitureCatalogItem(
        id: "desk",
        name: "Desk",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 1.40, y: 0.75, z: 0.70),
        parts: [
            box(0, 0.72, 0, 1.40, 0.04, 0.70, wood),
            box(-0.55, 0.36, 0, 0.04, 0.70, 0.60, woodDark),
            box(0.55, 0.36, 0, 0.04, 0.70, 0.60, woodDark),
            box(0.42, 0.40, 0.10, 0.36, 0.16, 0.42, wood),
            box(0.42, 0.22, 0.10, 0.36, 0.12, 0.42, wood)
        ]
    )

    private static let bed = FurnitureCatalogItem(
        id: "bed",
        name: "Bed",
        roomPlanCategory: "bed",
        nominalSize: Vec3(x: 1.60, y: 0.95, z: 2.10),
        parts: [
            box(0, 0.16, 0.05, 1.56, 0.28, 1.90, woodDark),
            box(0, 0.38, 0.08, 1.50, 0.18, 1.80, linen),
            box(0, 0.52, -0.78, 1.50, 0.12, 0.42, linen),
            box(-0.28, 0.56, -0.86, 0.50, 0.10, 0.28, fabric),
            box(0.28, 0.56, -0.86, 0.50, 0.10, 0.28, fabric),
            box(0, 0.62, -0.98, 1.60, 0.62, 0.08, wood)
        ]
    )

    private static let bookshelf = FurnitureCatalogItem(
        id: "bookshelf",
        name: "Bookshelf",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.90, y: 1.80, z: 0.32),
        parts: [
            box(0, 0.90, 0, 0.90, 1.80, 0.32, wood),
            box(0, 0.46, 0.02, 0.78, 0.02, 0.24, woodDark),
            box(0, 0.90, 0.02, 0.78, 0.02, 0.24, woodDark),
            box(0, 1.34, 0.02, 0.78, 0.02, 0.24, woodDark),
            box(-0.18, 0.68, 0.04, 0.28, 0.22, 0.16, fabricDeep),
            box(0.16, 1.12, 0.04, 0.30, 0.20, 0.16, fabric)
        ]
    )

    private static let lowShelf = FurnitureCatalogItem(
        id: "low_shelf",
        name: "Low shelf",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 1.20, y: 0.50, z: 0.40),
        parts: [
            box(0, 0.25, 0, 1.20, 0.50, 0.40, wood),
            box(0, 0.26, 0.02, 1.08, 0.02, 0.28, woodDark)
        ]
    )

    private static let wardrobe = FurnitureCatalogItem(
        id: "wardrobe",
        name: "Wardrobe",
        roomPlanCategory: "storage",
        nominalSize: Vec3(x: 1.20, y: 2.05, z: 0.60),
        parts: [
            box(0, 1.02, 0, 1.20, 2.02, 0.58, wood),
            box(-0.28, 1.05, 0.28, 0.50, 1.70, 0.02, woodDark),
            box(0.28, 1.05, 0.28, 0.50, 1.70, 0.02, woodDark),
            cylinder(-0.08, 1.00, 0.28, diameter: 0.03, height: 0.08, metal),
            cylinder(0.08, 1.00, 0.28, diameter: 0.03, height: 0.08, metal)
        ]
    )

    private static let floorLamp = FurnitureCatalogItem(
        id: "floor_lamp",
        name: "Floor lamp",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.36, y: 1.60, z: 0.36),
        parts: [
            cylinder(0, 0.02, 0, diameter: 0.24, height: 0.04, metal),
            cylinder(0, 0.72, 0, diameter: 0.03, height: 1.36, metal),
            cylinder(0, 1.46, 0, diameter: 0.30, height: 0.26, linen)
        ]
    )

    private static let tableLamp = FurnitureCatalogItem(
        id: "table_lamp",
        name: "Table lamp",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.24, y: 0.42, z: 0.24),
        parts: [
            cylinder(0, 0.03, 0, diameter: 0.12, height: 0.04, ceramic),
            cylinder(0, 0.12, 0, diameter: 0.04, height: 0.14, ceramic),
            cylinder(0, 0.28, 0, diameter: 0.20, height: 0.18, linen)
        ]
    )

    private static let plant = FurnitureCatalogItem(
        id: "plant",
        name: "Plant",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.40, y: 0.85, z: 0.40),
        parts: [
            cylinder(0, 0.10, 0, diameter: 0.20, height: 0.20, ceramic),
            cylinder(0, 0.36, 0, diameter: 0.32, height: 0.26, foliageDark),
            cylinder(0, 0.58, 0, diameter: 0.24, height: 0.22, foliage),
            cylinder(0, 0.74, 0, diameter: 0.14, height: 0.16, foliage)
        ]
    )

    private static let largePlant = FurnitureCatalogItem(
        id: "large_plant",
        name: "Large plant",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.55, y: 1.50, z: 0.55),
        parts: [
            cylinder(0, 0.16, 0, diameter: 0.28, height: 0.32, ceramic),
            cylinder(0, 0.55, 0, diameter: 0.46, height: 0.36, foliageDark),
            cylinder(0, 0.90, 0, diameter: 0.38, height: 0.34, foliage),
            cylinder(0, 1.22, 0, diameter: 0.24, height: 0.28, foliage)
        ]
    )

    private static let rug = FurnitureCatalogItem(
        id: "rug",
        name: "Rug",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 2.00, y: 0.02, z: 1.40),
        parts: [
            box(0, 0.01, 0, 2.00, 0.02, 1.40, rugWool)
        ]
    )

    private static let television = FurnitureCatalogItem(
        id: "television",
        name: "Television",
        roomPlanCategory: "television",
        nominalSize: Vec3(x: 1.10, y: 0.64, z: 0.08),
        parts: [
            box(0, 0.32, -0.01, 1.10, 0.64, 0.05, metal),
            box(0, 0.32, 0.025, 1.00, 0.54, 0.015, screen)
        ]
    )

    private static let mediaConsole = FurnitureCatalogItem(
        id: "media_console",
        name: "Media console",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 1.40, y: 0.46, z: 0.42),
        parts: [
            box(0, 0.20, 0, 1.40, 0.36, 0.40, woodDark),
            box(0, 0.42, 0, 1.40, 0.04, 0.42, wood),
            box(-0.34, 0.20, 0.20, 0.40, 0.22, 0.02, wood),
            box(0.34, 0.20, 0.20, 0.40, 0.22, 0.02, wood)
        ]
    )

    private static let ottoman = FurnitureCatalogItem(
        id: "ottoman",
        name: "Ottoman",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.70, y: 0.42, z: 0.70),
        parts: [
            cylinder(-0.26, 0.04, -0.26, diameter: 0.05, height: 0.08, woodDark),
            cylinder(0.26, 0.04, -0.26, diameter: 0.05, height: 0.08, woodDark),
            cylinder(-0.26, 0.04, 0.26, diameter: 0.05, height: 0.08, woodDark),
            cylinder(0.26, 0.04, 0.26, diameter: 0.05, height: 0.08, woodDark),
            box(0, 0.24, 0, 0.66, 0.28, 0.66, fabric)
        ]
    )

    private static let stool = FurnitureCatalogItem(
        id: "stool",
        name: "Stool",
        roomPlanCategory: nil,
        nominalSize: Vec3(x: 0.40, y: 0.46, z: 0.40),
        parts: [
            cylinder(0, 0.20, 0, diameter: 0.04, height: 0.40, wood),
            cylinder(0, 0.43, 0, diameter: 0.34, height: 0.05, wood),
            cylinder(0, 0.03, 0, diameter: 0.22, height: 0.04, metal)
        ]
    )
}

public enum FurnitureGeometry {
    public static func worldSize(of placement: PlacedFurniture) -> Vec3 {
        let nominal = FurnitureCatalog.item(id: placement.catalogId)?.nominalSize
            ?? Vec3(x: 0.5, y: 0.5, z: 0.5)
        return Vec3(
            x: nominal.x * placement.scale.x,
            y: nominal.y * placement.scale.y,
            z: nominal.z * placement.scale.z
        )
    }

    /// Floor corners after yaw. Same winding as a scan object: local +X follows `(cos yaw, 0, sin yaw)`.
    public static func footprint(of placement: PlacedFurniture) -> [Vec3] {
        let size = worldSize(of: placement)
        let halfX = size.x / 2
        let halfZ = size.z / 2
        let cosine = Trig.cos(placement.yaw)
        let sine = Trig.sin(placement.yaw)
        let local = [
            Vec3(x: -halfX, y: 0, z: -halfZ),
            Vec3(x: halfX, y: 0, z: -halfZ),
            Vec3(x: halfX, y: 0, z: halfZ),
            Vec3(x: -halfX, y: 0, z: halfZ)
        ]
        return local.map { point in
            Vec3(
                x: placement.position.x + point.x * cosine - point.z * sine,
                y: placement.position.y,
                z: placement.position.z + point.x * sine + point.z * cosine
            )
        }
    }

    public static func contains(x: Double, z: Double, placement: PlacedFurniture) -> Bool {
        contains(x: x, z: z, corners: footprint(of: placement))
    }

    public static func contains(x: Double, z: Double, corners: [Vec3]) -> Bool {
        guard corners.count >= 3 else { return false }
        var inside = false
        var previous = corners[corners.count - 1]
        for corner in corners {
            let intersects = ((corner.z > z) != (previous.z > z))
                && (x < (previous.x - corner.x) * (z - corner.z) / (previous.z - corner.z + 0) + corner.x)
            if intersects { inside.toggle() }
            previous = corner
        }
        return inside
    }

    public static func parts(of placement: PlacedFurniture) -> [ResolvedFurniturePart] {
        let item = FurnitureCatalog.item(id: placement.catalogId)
        let cosine = Trig.cos(placement.yaw)
        let sine = Trig.sin(placement.yaw)
        let source = item?.parts ?? [
            FurniturePart(
                shape: .box,
                center: Vec3(x: 0, y: 0.25, z: 0),
                size: Vec3(x: 0.5, y: 0.5, z: 0.5),
                material: FurnitureMaterial(name: "missing", red: 0.55, green: 0.46, blue: 0.36)
            )
        ]
        return source.map { part in
            let local = Vec3(
                x: part.center.x * placement.scale.x,
                y: part.center.y * placement.scale.y,
                z: part.center.z * placement.scale.z
            )
            let center = Vec3(
                x: placement.position.x + local.x * cosine - local.z * sine,
                y: placement.position.y + local.y,
                z: placement.position.z + local.x * sine + local.z * cosine
            )
            let diameter = part.size.x * max(placement.scale.x, placement.scale.z)
            let size: Vec3
            switch part.shape {
            case .box:
                size = Vec3(
                    x: part.size.x * placement.scale.x,
                    y: part.size.y * placement.scale.y,
                    z: part.size.z * placement.scale.z
                )
            case .cylinder:
                size = Vec3(x: diameter, y: part.size.y * placement.scale.y, z: diameter)
            }
            return ResolvedFurniturePart(
                shape: part.shape,
                center: center,
                size: size,
                yaw: placement.yaw,
                material: part.material
            )
        }
    }
}

extension Room {
    public var placedFurniture: [PlacedFurniture] {
        get { furniture ?? [] }
        set { furniture = newValue.isEmpty ? nil : newValue }
    }

    public var replacedObjectIDs: Set<UUID> {
        Set(placedFurniture.compactMap(\.replacesObjectId))
    }

    public var visibleObjects: [PlacedObject] {
        let hidden = replacedObjectIDs
        return floorPlan.objects.filter { !hidden.contains($0.id) }
    }
}

extension Home {
    public func furnitureItem(id: UUID) -> (roomID: UUID, item: PlacedFurniture)? {
        for room in rooms {
            if let item = room.placedFurniture.first(where: { $0.id == id }) {
                return (room.id, item)
            }
        }
        return nil
    }

    @discardableResult
    public mutating func upsertFurniture(_ item: PlacedFurniture, in roomID: UUID) -> PlacedFurniture? {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return nil }
        var items = rooms[index].placedFurniture
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            items[existing] = item
        } else if let replaced = item.replacesObjectId,
                  let existing = items.firstIndex(where: { $0.replacesObjectId == replaced }) {
            var kept = item
            kept.id = items[existing].id
            items[existing] = kept
        } else {
            items.append(item)
        }
        rooms[index].placedFurniture = items
        return rooms[index].placedFurniture.first { $0.id == item.id || $0.replacesObjectId == item.replacesObjectId }
    }

    public mutating func removeFurniture(id: UUID) {
        for index in rooms.indices {
            var items = rooms[index].placedFurniture
            let before = items.count
            items.removeAll { $0.id == id }
            if items.count != before {
                rooms[index].placedFurniture = items
            }
        }
    }

    public mutating func moveFurniture(id: UUID, x: Double, z: Double) {
        updateFurniture(id: id) { $0.moved(x: x, z: z) }
    }

    public mutating func rotateFurniture(id: UUID, by radians: Double) {
        updateFurniture(id: id) { $0.rotated(by: radians) }
    }

    public mutating func scaleFurniture(id: UUID, by factor: Double) {
        updateFurniture(id: id) { $0.scaled(by: factor) }
    }

    @discardableResult
    public mutating func replaceObject(
        id objectID: UUID,
        in roomID: UUID,
        with catalogID: String
    ) -> PlacedFurniture? {
        guard let room = room(id: roomID),
              let object = room.floorPlan.objects.first(where: { $0.id == objectID }),
              let item = FurnitureCatalog.item(id: catalogID) else { return nil }
        let placed = PlacedFurniture.replacing(object, with: item)
        return upsertFurniture(placed, in: roomID)
    }

    public mutating func setFlooring(_ material: FlooringMaterial?, roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].flooring = material
    }

    /// Copies the highest numbered storey onto the next `floor` index.
    /// When no room has a floor yet, the existing rooms become floor 0 and the copy is floor 1,
    /// which is the same optional integer the card already groups on.
    @discardableResult
    public mutating func addCopiedFloor(now: Date = Date(), makeID: () -> UUID = { UUID() }) -> [Room] {
        guard !rooms.isEmpty else { return [] }
        let sourceFloor = rooms.compactMap(\.floor).max()
        if sourceFloor == nil {
            for index in rooms.indices {
                rooms[index].floor = 0
            }
        }
        let source = sourceFloor ?? 0
        let copies = FloorStack.copiedRooms(
            from: rooms.filter { $0.floor == source },
            floor: source + 1,
            createdAt: now,
            makeID: makeID
        )
        rooms.append(contentsOf: copies)
        updatedAt = now
        return copies
    }

    @discardableResult
    public mutating func addFootprintFloor(now: Date = Date(), makeID: () -> UUID = { UUID() }) -> Room? {
        guard !rooms.isEmpty else { return nil }
        let sourceFloor = rooms.compactMap(\.floor).max()
        if sourceFloor == nil {
            for index in rooms.indices {
                rooms[index].floor = 0
            }
        }
        let source = sourceFloor ?? 0
        guard let room = FloorStack.footprintRoom(
            from: rooms.filter { $0.floor == source },
            unified: coordinatesAreUnified,
            floor: source + 1,
            createdAt: now,
            makeID: makeID
        ) else { return nil }
        rooms.append(room)
        updatedAt = now
        return room
    }

    private mutating func updateFurniture(id: UUID, _ body: (PlacedFurniture) -> PlacedFurniture) {
        for index in rooms.indices {
            guard let itemIndex = rooms[index].placedFurniture.firstIndex(where: { $0.id == id }) else { continue }
            var items = rooms[index].placedFurniture
            items[itemIndex] = body(items[itemIndex])
            rooms[index].placedFurniture = items
            return
        }
    }
}
