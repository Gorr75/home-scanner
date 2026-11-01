import Foundation
import Observation
import RoomScanCore

@MainActor
@Observable
final class PinBoard {
    private let provider: any HomeStateProvider
    private(set) var snapshots: [String: EntitySnapshot] = [:]
    private(set) var banner = "States are sample data on this iPhone. Home Assistant is not connected."
    private(set) var lastError: String?

    init(provider: any HomeStateProvider = MockHomeStateProvider()) {
        self.provider = provider
    }

    func refresh(pins: [DevicePin]) async {
        let ids = Array(Set(pins.compactMap { pin -> String? in
            guard let raw = pin.entityId else { return nil }
            if case .valid(let id) = EntityIDRules.check(raw) { return id }
            return nil
        }))
        guard !ids.isEmpty else {
            snapshots = [:]
            banner = "No linked devices yet. Add an entity id such as light.kitchen."
            lastError = nil
            return
        }
        do {
            let loaded = try await provider.snapshots(for: ids)
            var map: [String: EntitySnapshot] = [:]
            for item in loaded {
                map[item.entityId] = item
            }
            snapshots = map
            banner = "States are sample data on this iPhone. Home Assistant is not connected."
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggle(_ pin: DevicePin) async {
        guard let raw = pin.entityId, case .valid(let id) = EntityIDRules.check(raw) else { return }
        do {
            let updated = try await provider.perform(.toggle, entityId: id)
            snapshots[updated.entityId] = updated
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stateMap(for pins: [DevicePin]) -> [String: String] {
        var map: [String: String] = [:]
        for pin in pins {
            guard let snapshot = snapshot(for: pin) else { continue }
            map[snapshot.entityId] = snapshot.state
            if let raw = pin.entityId {
                map[raw] = snapshot.state
            }
        }
        return map
    }

    func snapshot(for pin: DevicePin) -> EntitySnapshot? {
        guard let raw = pin.entityId else { return nil }
        if let exact = snapshots[raw] { return exact }
        if case .valid(let id) = EntityIDRules.check(raw) {
            return snapshots[id]
        }
        return nil
    }
}
