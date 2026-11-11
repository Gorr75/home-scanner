import Foundation

public enum InventorySource: String, Codable, Sendable {
    /// A RoomPlan box.
    case detected
    /// A catalog item placed in the room.
    case catalog
    /// Typed in by hand.
    case manual
}

/// One insured or tracked thing in a room. Photos and the receipt are relative file paths.
public struct InventoryItem: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var category: String
    public var brand: String?
    public var model: String?
    public var purchaseDate: Date?
    /// Amount in the currency the household uses. The file does not store a currency code.
    public var price: Double?
    public var serial: String?
    public var photos: [String]
    public var receipt: String?
    public var notes: String?
    /// Meters in the room's scan space. Nil until the item is linked to a spot.
    public var position: Vec3?
    public var furnitureId: UUID?
    public var objectId: UUID?
    public var source: InventorySource

    public init(
        id: UUID,
        name: String,
        category: String,
        brand: String? = nil,
        model: String? = nil,
        purchaseDate: Date? = nil,
        price: Double? = nil,
        serial: String? = nil,
        photos: [String] = [],
        receipt: String? = nil,
        notes: String? = nil,
        position: Vec3? = nil,
        furnitureId: UUID? = nil,
        objectId: UUID? = nil,
        source: InventorySource = .manual
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.brand = brand
        self.model = model
        self.purchaseDate = purchaseDate
        self.price = price
        self.serial = serial
        self.photos = photos
        self.receipt = receipt
        self.notes = notes
        self.position = position
        self.furnitureId = furnitureId
        self.objectId = objectId
        self.source = source
    }

    public func transformed(by rigid: RigidYaw) -> InventoryItem {
        var copy = self
        copy.position = position.map { rigid.applying($0) }
        return copy
    }
}

extension InventoryItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, category, brand, model, purchaseDate, price, serial
        case photos, receipt, notes, position, furnitureId, objectId, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        brand = try container.decodeIfPresent(String.self, forKey: .brand)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        purchaseDate = try container.decodeIfPresent(Date.self, forKey: .purchaseDate)
        price = try container.decodeIfPresent(Double.self, forKey: .price)
        serial = try container.decodeIfPresent(String.self, forKey: .serial)
        photos = try container.decodeIfPresent([String].self, forKey: .photos) ?? []
        receipt = try container.decodeIfPresent(String.self, forKey: .receipt)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        position = try container.decodeIfPresent(Vec3.self, forKey: .position)
        furnitureId = try container.decodeIfPresent(UUID.self, forKey: .furnitureId)
        objectId = try container.decodeIfPresent(UUID.self, forKey: .objectId)
        if let raw = try container.decodeIfPresent(String.self, forKey: .source) {
            source = InventorySource(rawValue: raw) ?? .manual
        } else {
            source = .manual
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encodeIfPresent(brand, forKey: .brand)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(purchaseDate, forKey: .purchaseDate)
        if let price {
            try container.encode(InventoryMath.quantize(price), forKey: .price)
        }
        try container.encodeIfPresent(serial, forKey: .serial)
        if !photos.isEmpty {
            try container.encode(photos, forKey: .photos)
        }
        try container.encodeIfPresent(receipt, forKey: .receipt)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(position, forKey: .position)
        try container.encodeIfPresent(furnitureId, forKey: .furnitureId)
        try container.encodeIfPresent(objectId, forKey: .objectId)
        try container.encode(source, forKey: .source)
    }
}

public struct InventoryTotals: Equatable, Sendable {
    public var count: Int
    public var pricedCount: Int
    public var totalPrice: Double

    public init(count: Int, pricedCount: Int, totalPrice: Double) {
        self.count = count
        self.pricedCount = pricedCount
        self.totalPrice = totalPrice
    }
}

public struct InventoryRoomTotal: Equatable, Sendable {
    public var roomID: UUID
    public var name: String
    public var totals: InventoryTotals

    public init(roomID: UUID, name: String, totals: InventoryTotals) {
        self.roomID = roomID
        self.name = name
        self.totals = totals
    }
}

public enum InventoryMath {
    public static func quantize(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 100).rounded() / 100
    }

    public static func totals(of items: [InventoryItem]) -> InventoryTotals {
        let prices = items.compactMap(\.price).filter(\.isFinite)
        return InventoryTotals(
            count: items.count,
            pricedCount: prices.count,
            totalPrice: quantize(prices.reduce(0, +))
        )
    }

    public static func rooms(in home: Home) -> [InventoryRoomTotal] {
        home.rooms.map { room in
            InventoryRoomTotal(roomID: room.id, name: room.name, totals: totals(of: room.inventoryItems))
        }
    }

    public static func homeTotal(in home: Home) -> InventoryTotals {
        totals(of: home.rooms.flatMap(\.inventoryItems))
    }

    /// One row per item. Fields that contain a comma or a quote are quoted.
    public static func csv(for home: Home) -> String {
        var lines = ["room,name,category,brand,model,purchase_date,price,serial,notes,source,position_x,position_y,position_z,furniture_id,object_id,photos,receipt"]
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        for room in home.rooms {
            for item in room.inventoryItems {
                lines.append(csvRow(room: room, item: item, stamp: stamp))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvRow(room: Room, item: InventoryItem, stamp: ISO8601DateFormatter) -> String {
        var fields: [String] = []
        fields.append(room.name)
        fields.append(item.name)
        fields.append(item.category)
        fields.append(item.brand ?? "")
        fields.append(item.model ?? "")
        if let date = item.purchaseDate {
            fields.append(stamp.string(from: date))
        } else {
            fields.append("")
        }
        if let price = item.price {
            fields.append(coordinate("%.2f", quantize(price)))
        } else {
            fields.append("")
        }
        fields.append(item.serial ?? "")
        fields.append(item.notes ?? "")
        fields.append(item.source.rawValue)
        if let position = item.position {
            fields.append(coordinate("%.4f", Vec3.quantize(position.x)))
            fields.append(coordinate("%.4f", Vec3.quantize(position.y)))
            fields.append(coordinate("%.4f", Vec3.quantize(position.z)))
        } else {
            fields.append("")
            fields.append("")
            fields.append("")
        }
        fields.append(item.furnitureId?.uuidString ?? "")
        fields.append(item.objectId?.uuidString ?? "")
        fields.append(item.photos.joined(separator: " "))
        fields.append(item.receipt ?? "")
        return fields.map(csvField).joined(separator: ",")
    }

    private static func coordinate(_ format: String, _ value: Double) -> String {
        String(format: format, locale: Locale(identifier: "en_US_POSIX"), value)
    }

    public static func csvField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    /// Items whose name, category, brand, model, serial, notes, or room name contain `query`.
    public static func matching(_ query: String, in home: Home) -> [(room: Room, item: InventoryItem)] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [(Room, InventoryItem)] = []
        for room in home.rooms {
            for item in room.inventoryItems {
                if needle.isEmpty || contains(needle, room: room, item: item) {
                    rows.append((room, item))
                }
            }
        }
        return rows
    }

    private static func contains(_ needle: String, room: Room, item: InventoryItem) -> Bool {
        let haystack = [
            room.name, item.name, item.category, item.brand ?? "", item.model ?? "", item.serial ?? "", item.notes ?? ""
        ].joined(separator: "\n")
        return haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

public enum InventoryCatalog {
    /// Adds RoomPlan objects and catalog furniture that are not already linked.
    /// A scan box hidden by a catalog item is not listed twice.
    public static func merge(existing: [InventoryItem], room: Room, now: Date = Date()) -> [InventoryItem] {
        var items = existing
        var objectIDs = Set(items.compactMap(\.objectId))
        var furnitureIDs = Set(items.compactMap(\.furnitureId))
        let hidden = room.replacedObjectIDs
        for object in room.floorPlan.objects where !hidden.contains(object.id) && !objectIDs.contains(object.id) {
            items.append(InventoryItem(
                id: UUID(),
                name: ObjectLabels.title(for: object.category),
                category: object.category,
                position: object.center,
                objectId: object.id,
                source: .detected
            ))
            objectIDs.insert(object.id)
        }
        for piece in room.placedFurniture where !furnitureIDs.contains(piece.id) {
            let catalog = FurnitureCatalog.item(id: piece.catalogId)
            items.append(InventoryItem(
                id: UUID(),
                name: catalog?.name ?? piece.catalogId,
                category: piece.catalogId,
                position: piece.position,
                furnitureId: piece.id,
                source: .catalog
            ))
            furnitureIDs.insert(piece.id)
        }
        _ = now
        return items
    }
}

extension Room {
    public var inventoryItems: [InventoryItem] {
        get { inventory ?? [] }
        set { inventory = newValue.isEmpty ? nil : newValue }
    }
}

extension Home {
    public func inventory(in roomID: UUID) -> [InventoryItem] {
        room(id: roomID)?.inventoryItems ?? []
    }

    public func inventoryItem(id: UUID) -> (roomID: UUID, item: InventoryItem)? {
        for room in rooms {
            if let item = room.inventoryItems.first(where: { $0.id == id }) {
                return (room.id, item)
            }
        }
        return nil
    }

    public mutating func upsertInventory(_ item: InventoryItem, in roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        var items = rooms[index].inventoryItems
        if let existing = items.firstIndex(where: { $0.id == item.id }) {
            items[existing] = item
        } else {
            items.append(item)
        }
        rooms[index].inventoryItems = items
    }

    public mutating func deleteInventory(id: UUID, in roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        var items = rooms[index].inventoryItems
        items.removeAll { $0.id == id }
        rooms[index].inventoryItems = items
    }

    public mutating func mergeInventorySuggestions(in roomID: UUID) {
        guard let index = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        rooms[index].inventoryItems = InventoryCatalog.merge(existing: rooms[index].inventoryItems, room: rooms[index])
    }
}
