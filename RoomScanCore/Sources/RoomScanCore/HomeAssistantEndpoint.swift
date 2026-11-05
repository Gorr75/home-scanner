import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public extension DeviceKind {
    /// Maps a Home Assistant domain onto the pin type used in the floor plan.
    static func forHomeAssistantDomain(_ domain: String) -> DeviceKind {
        switch domain {
        case "light":
            return .light
        case "switch":
            return .switch
        case "sensor", "binary_sensor":
            return .sensor
        case "climate":
            return .climate
        case "cover":
            return .cover
        case "fan":
            return .fan
        case "media_player":
            return .mediaPlayer
        case "lock":
            return .lock
        default:
            return .other
        }
    }
}

public enum HomeAssistantURL {
    /// Accepts `homeassistant.local:8123` or a full URL and returns the origin only.
    /// A pasted `/api` path is dropped. Userinfo is dropped so a token cannot hide in the URL.
    public static func normalize(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text) else { return nil }
        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return nil
        }
        let path = components.path
        if path.isEmpty || path == "/" || path == "/api" || path == "/api/" {
            components.path = ""
        } else if path.hasPrefix("/") {
            components.path = ""
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

public struct HomeAssistantEndpoint: Equatable, Sendable {
    public var baseURL: URL
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    public var webSocketURL: URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            return nil
        }
        components.path = "/api/websocket"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public func url(path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let encoded = segments.map { segment -> String in
            segment.addingPercentEncoding(withAllowedCharacters: Self.pathCharacters) ?? segment
        }
        components.path = "/" + encoded.joined(separator: "/")
        if path.hasSuffix("/"), !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    public func request(path: String, method: String = "GET", body: Data? = nil, contentType: String? = nil) -> URLRequest? {
        guard let url = url(path: path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        return request
    }

    private static let pathCharacters: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/")
        return set
    }()
}

public enum HomeAssistantAPI {
    /// Status route. Home Assistant registers this view as `/api/` and answers
    /// `GET /api` with `{"message":"404: Not Found"}`.
    public static let root = "/api/"
    public static let config = "/api/config"
    public static let states = "/api/states"
    public static let integrationHealth = "/api/home_scanner/health"

    public static func state(_ entityId: String) -> String {
        "/api/states/\(entityId)"
    }

    public static func service(domain: String, action: String) -> String {
        "/api/services/\(domain)/\(action)"
    }
}

public struct HAEntityRecord: Equatable, Sendable, Identifiable {
    public var entityId: String
    public var state: String
    public var domain: String
    public var friendlyName: String?
    public var unit: String?

    public init(
        entityId: String,
        state: String,
        domain: String,
        friendlyName: String? = nil,
        unit: String? = nil
    ) {
        self.entityId = entityId
        self.state = state
        self.domain = domain
        self.friendlyName = friendlyName
        self.unit = unit
    }

    public var id: String { entityId }

    public var snapshot: EntitySnapshot {
        EntitySnapshot(
            entityId: entityId,
            state: state,
            domain: domain,
            unit: unit,
            friendlyName: friendlyName
        )
    }

    public var suggestedKind: DeviceKind {
        DeviceKind.forHomeAssistantDomain(domain)
    }
}

public struct HomeAssistantProbe: Equatable, Sendable {
    public var message: String
    public var locationName: String?
    public var version: String?
    public var uploadEndpointInstalled: Bool

    public init(
        message: String,
        locationName: String? = nil,
        version: String? = nil,
        uploadEndpointInstalled: Bool
    ) {
        self.message = message
        self.locationName = locationName
        self.version = version
        self.uploadEndpointInstalled = uploadEndpointInstalled
    }
}

public enum HomeAssistantClientError: Error, Equatable, Sendable {
    case emptyToken
    case invalidBaseURL
    case unauthorized
    case httpStatus(Int, String)
    case malformedResponse
    case transport(String)
}

extension HomeAssistantClientError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyToken:
            return "Add a Home Assistant long-lived access token in Settings."
        case .invalidBaseURL:
            return "The Home Assistant address needs a host, for example http://homeassistant.local:8123."
        case .unauthorized:
            return "Home Assistant rejected the token. Create a new long-lived access token and save it in Settings."
        case .httpStatus(let code, let detail):
            if detail.isEmpty {
                return "Home Assistant returned HTTP \(code)."
            }
            return "Home Assistant returned HTTP \(code). \(detail)"
        case .malformedResponse:
            return "Home Assistant returned a response this app could not read."
        case .transport(let detail):
            return detail.isEmpty ? "Home Assistant could not be reached." : detail
        }
    }
}

public enum EntitySearch {
    public static let preferredDomains: Set<String> = [
        "light", "switch", "sensor", "binary_sensor", "climate", "cover", "fan", "media_player", "lock"
    ]

    public static func rank(_ records: [HAEntityRecord], query: String, limit: Int = 20) -> [HAEntityRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool: [HAEntityRecord]
        if needle.isEmpty {
            pool = records.filter { preferredDomains.contains($0.domain) }
        } else {
            pool = records.filter { record in
                record.entityId.lowercased().contains(needle)
                    || (record.friendlyName?.lowercased().contains(needle) ?? false)
            }
        }
        let ranked = pool.sorted { lhs, rhs in
            let leftScore = score(lhs, needle: needle)
            let rightScore = score(rhs, needle: needle)
            if leftScore != rightScore { return leftScore > rightScore }
            return lhs.entityId < rhs.entityId
        }
        if limit <= 0 { return [] }
        return Array(ranked.prefix(limit))
    }

    private static func score(_ record: HAEntityRecord, needle: String) -> Int {
        guard !needle.isEmpty else {
            return preferredDomains.contains(record.domain) ? 1 : 0
        }
        let id = record.entityId.lowercased()
        if id == needle { return 5 }
        if id.hasPrefix(needle) { return 4 }
        if record.friendlyName?.lowercased().hasPrefix(needle) == true { return 3 }
        if id.contains(needle) { return 2 }
        return 1
    }
}

enum HomeAssistantDecoding {
    static func entity(from dictionary: [String: Any]) -> HAEntityRecord? {
        record(from: dictionary)
    }

    static func records(from data: Data) throws -> [HAEntityRecord] {
        let object = try jsonObject(data)
        if let list = object as? [Any] {
            return list.compactMap { item in
                guard let dictionary = item as? [String: Any] else { return nil }
                return record(from: dictionary)
            }
        }
        if let dictionary = object as? [String: Any], let record = record(from: dictionary) {
            return [record]
        }
        throw HomeAssistantClientError.malformedResponse
    }

    static func probe(apiData: Data, configData: Data?, uploadInstalled: Bool) throws -> HomeAssistantProbe {
        let api = try jsonObject(apiData)
        let message: String
        if let dictionary = api as? [String: Any], let text = dictionary["message"] as? String, !text.isEmpty {
            message = text
        } else {
            message = "API running."
        }
        var location: String?
        var version: String?
        if let configData, let config = try? jsonObject(configData) as? [String: Any] {
            location = config["location_name"] as? String
            version = config["version"] as? String
        }
        return HomeAssistantProbe(
            message: message,
            locationName: location,
            version: version,
            uploadEndpointInstalled: uploadInstalled
        )
    }

    static func detail(from data: Data) -> String {
        guard let object = try? jsonObject(data) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return String(text.prefix(180))
        }
        if let dictionary = object as? [String: Any] {
            if let message = dictionary["message"] as? String { return String(message.prefix(180)) }
            if let error = dictionary["error"] as? String { return String(error.prefix(180)) }
        }
        return ""
    }

    private static func record(from dictionary: [String: Any]) -> HAEntityRecord? {
        guard let entityId = dictionary["entity_id"] as? String, !entityId.isEmpty else { return nil }
        let state = stateString(dictionary["state"])
        let attributes = dictionary["attributes"] as? [String: Any]
        let friendly = attributes?["friendly_name"] as? String
        let unit = attributes?["unit_of_measurement"] as? String
        let domain = entityId.split(separator: ".").first.map(String.init) ?? "unknown"
        return HAEntityRecord(
            entityId: entityId,
            state: state,
            domain: domain,
            friendlyName: friendly,
            unit: unit
        )
    }

    private static func stateString(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return "unknown"
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        guard !data.isEmpty else { throw HomeAssistantClientError.malformedResponse }
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw HomeAssistantClientError.malformedResponse
        }
    }
}
