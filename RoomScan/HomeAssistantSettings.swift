import Foundation
import Observation
import RoomScanCore

/// Base URL in UserDefaults, long-lived token in the Keychain.
@MainActor
@Observable
final class HomeAssistantSettings {
    static let baseURLDefaultsKey = "se.jansson.homescan.homeassistant.baseURL"

    var baseURLText: String
    private(set) var hasToken: Bool
    private(set) var generation: Int
    private(set) var catalogError: String?
    private var token: String
    private var cachedRecords: [HAEntityRecord] = []
    private var cacheTime: Date?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        let storedURL = defaults.string(forKey: Self.baseURLDefaultsKey) ?? ""
        let storedToken = KeychainTokenStore.read() ?? ""
        self.defaults = defaults
        baseURLText = storedURL
        token = storedToken
        hasToken = !storedToken.isEmpty
        generation = 0
        catalogError = nil
    }

    var isConfigured: Bool { endpoint != nil }

    var endpoint: HomeAssistantEndpoint? {
        guard let url = HomeAssistantURL.normalize(baseURLText), !token.isEmpty else { return nil }
        return HomeAssistantEndpoint(baseURL: url, token: token)
    }

    var serverLabel: String {
        endpoint?.baseURL.absoluteString ?? "Home Assistant is not connected."
    }

    func makeClient() -> HomeAssistantClient? {
        guard let endpoint else { return nil }
        return HomeAssistantClient(endpoint: endpoint)
    }

    func makeProvider() -> any HomeStateProvider {
        if let client = makeClient() {
            return client
        }
        return MockHomeStateProvider()
    }

    func save(baseURL: String, token newToken: String?) throws {
        let normalized = HomeAssistantURL.normalize(baseURL)
        let storedURL = normalized?.absoluteString ?? baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURLText = storedURL
        defaults.set(storedURL, forKey: Self.baseURLDefaultsKey)
        if let newToken {
            let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try KeychainTokenStore.delete()
                token = ""
            } else {
                try KeychainTokenStore.save(trimmed)
                token = trimmed
            }
        }
        hasToken = !token.isEmpty
        cachedRecords = []
        cacheTime = nil
        catalogError = nil
        generation += 1
    }

    func clearConnection() throws {
        try KeychainTokenStore.delete()
        token = ""
        hasToken = false
        baseURLText = ""
        defaults.removeObject(forKey: Self.baseURLDefaultsKey)
        cachedRecords = []
        cacheTime = nil
        catalogError = nil
        generation += 1
    }

    func probe() async throws -> HomeAssistantProbe {
        guard let client = makeClient() else {
            if HomeAssistantURL.normalize(baseURLText) == nil {
                throw HomeAssistantClientError.invalidBaseURL
            }
            throw HomeAssistantClientError.emptyToken
        }
        return try await client.probe()
    }

    func searchEntities(matching query: String) async -> [HAEntityRecord] {
        let records = await loadRecords()
        return EntitySearch.rank(records, query: query)
    }

    func refreshEntities() async {
        cachedRecords = []
        cacheTime = nil
        _ = await loadRecords()
    }

    private func loadRecords() async -> [HAEntityRecord] {
        if let cacheTime, Date().timeIntervalSince(cacheTime) < 30, !cachedRecords.isEmpty {
            return cachedRecords
        }
        guard let client = makeClient() else { return [] }
        do {
            let records = try await client.listEntities()
            cachedRecords = records
            cacheTime = Date()
            catalogError = nil
            return records
        } catch {
            catalogError = error.localizedDescription
            return cachedRecords
        }
    }
}
