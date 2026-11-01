import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Equatable, Sendable {
    public var statusCode: Int
    public var data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HomeAssistantClientError.transport("The server did not return an HTTP response.")
            }
            return HTTPResponse(statusCode: http.statusCode, data: data)
        } catch let error as HomeAssistantClientError {
            throw error
        } catch {
            throw HomeAssistantClientError.transport(error.localizedDescription)
        }
    }
}

/// REST client for Home Assistant. The long-lived token is supplied by the caller
/// (the app keeps it in the Keychain) and is never written into a home file.
public actor HomeAssistantClient: HomeStateProvider {
    public let endpoint: HomeAssistantEndpoint
    private let transport: any HTTPTransport

    public init(endpoint: HomeAssistantEndpoint, transport: any HTTPTransport = URLSessionHTTPTransport()) {
        self.endpoint = endpoint
        self.transport = transport
    }

    public func probe() async throws -> HomeAssistantProbe {
        let api = try await send(path: HomeAssistantAPI.root)
        var configData: Data?
        if let configResponse = try? await send(path: HomeAssistantAPI.config) {
            configData = configResponse.data
        }
        let health = try? await send(path: HomeAssistantAPI.integrationHealth)
        let installed = health?.statusCode == 200
        return try HomeAssistantDecoding.probe(
            apiData: api.data,
            configData: configData,
            uploadInstalled: installed
        )
    }

    public func listEntities() async throws -> [HAEntityRecord] {
        let response = try await send(path: HomeAssistantAPI.states)
        return try HomeAssistantDecoding.records(from: response.data)
    }

    public func snapshot(for entityId: String) async throws -> EntitySnapshot {
        let id = try requireID(entityId)
        let response = try await send(path: HomeAssistantAPI.state(id))
        let records = try HomeAssistantDecoding.records(from: response.data)
        guard let record = records.first(where: { $0.entityId == id }) ?? records.first else {
            throw HomeAssistantClientError.malformedResponse
        }
        return record.snapshot
    }

    public func snapshots(for entityIds: [String]) async throws -> [EntitySnapshot] {
        let wanted = try entityIds.map(requireID)
        let records = try await listEntities()
        var byID: [String: EntitySnapshot] = [:]
        for record in records {
            byID[record.entityId] = record.snapshot
        }
        return wanted.map { id in
            if let found = byID[id] { return found }
            let domain = id.split(separator: ".").first.map(String.init) ?? "unknown"
            return EntitySnapshot(entityId: id, state: "unavailable", domain: domain)
        }
    }

    public func upload(slug: String, files: [HomeScannerFile]) async throws -> HomeScannerUploadReceipt {
        guard let slug = HomeScannerSlug.accept(slug) else {
            throw HomeAssistantClientError.httpStatus(400, "That folder name cannot be used on the server.")
        }
        guard files.contains(where: { $0.filename == "layout.json" }) else {
            throw HomeAssistantClientError.malformedResponse
        }
        let boundary = "HomeScanner\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body = MultipartForm.body(files: files, boundary: boundary)
        let response = try await send(
            path: "/api/home_scanner/upload/\(slug)",
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        return try HomeAssistantDecoding.uploadReceipt(from: response.data, fallbackSlug: slug)
    }

    public func perform(_ action: EntityAction, entityId: String) async throws -> EntitySnapshot {
        let id = try requireID(entityId)
        let current = try await snapshot(for: id)
        guard current.isToggleable else {
            throw HomeStateError.notToggleable(current.entityId)
        }
        let body = try JSONSerialization.data(withJSONObject: ["entity_id": id])
        let response = try await send(
            path: HomeAssistantAPI.service(domain: current.domain, action: action.rawValue),
            method: "POST",
            body: body,
            contentType: "application/json"
        )
        if let records = try? HomeAssistantDecoding.records(from: response.data),
           let match = records.first(where: { $0.entityId == id }) {
            return match.snapshot
        }
        return try await snapshot(for: id)
    }

    @discardableResult
    func send(
        path: String,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> HTTPResponse {
        let token = endpoint.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw HomeAssistantClientError.emptyToken }
        guard let request = endpoint.request(path: path, method: method, body: body, contentType: contentType) else {
            throw HomeAssistantClientError.invalidBaseURL
        }
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch let error as HomeAssistantClientError {
            throw error
        } catch {
            throw HomeAssistantClientError.transport(error.localizedDescription)
        }
        if response.statusCode == 401 {
            throw HomeAssistantClientError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw HomeAssistantClientError.httpStatus(
                response.statusCode,
                HomeAssistantDecoding.detail(from: response.data)
            )
        }
        return response
    }

    private func requireID(_ raw: String) throws -> String {
        switch EntityIDRules.check(raw) {
        case .valid(let id):
            return id
        case .unset, .invalid:
            throw HomeStateError.invalidEntityId(raw)
        }
    }
}
