import Foundation
import Observation
import RoomScanCore

@MainActor
@Observable
final class PinBoard {
    private var provider: any HomeStateProvider
    @ObservationIgnored private var endpoint: HomeAssistantEndpoint?
    @ObservationIgnored private var watched: [DevicePin] = []
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var socketTask: Task<Void, Never>?

    private(set) var snapshots: [String: EntitySnapshot] = [:]
    private(set) var banner = "States are sample data on this iPhone. Home Assistant is not connected."
    private(set) var lastError: String?
    private(set) var isLive = false
    private(set) var socketConnected = false

    init(provider: any HomeStateProvider = MockHomeStateProvider()) {
        self.provider = provider
    }

    func use(provider: any HomeStateProvider, live: Bool, endpoint: HomeAssistantEndpoint?) {
        pollTask?.cancel()
        socketTask?.cancel()
        pollTask = nil
        socketTask = nil
        self.provider = provider
        self.endpoint = endpoint
        isLive = live
        socketConnected = false
        snapshots = [:]
        lastError = nil
        banner = live
            ? "Connecting to Home Assistant."
            : "States are sample data on this iPhone. Home Assistant is not connected."
        guard live, let endpoint else { return }
        let watchedPins = watched
        socketTask = Task { [weak self] in
            await self?.runSocket(endpoint)
        }
        pollTask = Task { [weak self] in
            await self?.runPoll(initialPins: watchedPins)
        }
    }

    func refresh(pins: [DevicePin]) async {
        watched = pins
        let ids = linkedIDs(in: pins)
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
            lastError = nil
            updateBanner(hasLinks: true)
        } catch {
            lastError = error.localizedDescription
            updateBanner(hasLinks: true)
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

    func apply(_ snapshot: EntitySnapshot) {
        snapshots[snapshot.entityId] = snapshot
        lastError = nil
        socketConnected = true
        updateBanner(hasLinks: true)
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

    func captions(for pins: [DevicePin]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for pin in pins {
            guard let snapshot = snapshot(for: pin) else { continue }
            map[pin.id] = snapshot.displayState
        }
        return map
    }

    func states(for pins: [DevicePin]) -> [UUID: String] {
        var map: [UUID: String] = [:]
        for pin in pins {
            guard let snapshot = snapshot(for: pin) else { continue }
            map[pin.id] = snapshot.state
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

    private func runPoll(initialPins: [DevicePin]) async {
        if !initialPins.isEmpty {
            await refresh(pins: initialPins)
        }
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 8_000_000_000)
            } catch {
                break
            }
            if Task.isCancelled { break }
            let pins = watched
            if !pins.isEmpty {
                await refresh(pins: pins)
            }
        }
    }

    private func runSocket(_ endpoint: HomeAssistantEndpoint) async {
        let stream = HomeAssistantEventStream(endpoint: endpoint)
        do {
            for try await update in stream.updates() {
                switch update {
                case .ready:
                    self.socketConnected = true
                    self.updateBanner(hasLinks: true)
                case .state(let snapshot):
                    self.apply(snapshot)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            socketConnected = false
            lastError = error.localizedDescription
            updateBanner(hasLinks: !linkedIDs(in: watched).isEmpty)
        }
    }

    private func updateBanner(hasLinks: Bool) {
        guard hasLinks else {
            banner = "No linked devices yet. Add an entity id such as light.kitchen."
            return
        }
        if !isLive {
            banner = "States are sample data on this iPhone. Home Assistant is not connected."
            return
        }
        if socketConnected {
            banner = "Live from Home Assistant."
            return
        }
        banner = "Home Assistant states refresh every few seconds."
    }

    private func linkedIDs(in pins: [DevicePin]) -> [String] {
        Array(Set(pins.compactMap { pin -> String? in
            guard let raw = pin.entityId else { return nil }
            if case .valid(let id) = EntityIDRules.check(raw) { return id }
            return nil
        }))
    }
}
