import Foundation
import RoomScanCore

enum DeviceAutoPlace {
    static let confirmDetail = "They drop into rooms that match a Home Assistant area, the device name, or the entity id. Pins you already linked stay where you put them."

    static func propose(home: Home, roomID: UUID?, client: HomeAssistantClient) async throws -> [DevicePin] {
        let records = try await client.listEntities()
        let areas = (try? await client.areaNamesByEntity()) ?? [:]
        let rooms = home.rooms.filter { roomID == nil || $0.id == roomID }
        let candidates = records.map { record in
            let canonical: String
            if case .valid(let id) = EntityIDRules.check(record.entityId) {
                canonical = id
            } else {
                canonical = record.entityId
            }
            return PinAutoPlace.Candidate(
                entityId: record.entityId,
                friendlyName: record.friendlyName,
                domain: record.domain,
                areaName: areas[canonical]
            )
        }
        return PinAutoPlace.suggestions(rooms: rooms, candidates: candidates, existingPins: home.pins)
    }
}
