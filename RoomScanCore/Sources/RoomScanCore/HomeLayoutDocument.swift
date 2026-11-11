import Foundation

public enum HomeLayoutError: Error, Equatable, Sendable {
    case unknownFormat(String)
    case unsupportedVersion(Int)
}

extension HomeLayoutError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownFormat(let format):
            return "This file is \(format), not a Home Scanner layout."
        case .unsupportedVersion(let version):
            return "This Home Scanner layout uses format version \(version), which this app does not read."
        }
    }
}

/// The on-device manifest and the file a future Home Assistant integration would import.
/// See `docs/home-assistant.md`.
public struct HomeLayoutDocument: Codable, Equatable, Sendable {
    public static let formatIdentifier = "roomscan.home"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var home: Home

    public init(home: Home) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.home = home
    }

    public init(format: String, version: Int, home: Home) {
        self.format = format
        self.version = version
        self.home = home
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> HomeLayoutDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let document = try decoder.decode(HomeLayoutDocument.self, from: data)
        guard document.format == formatIdentifier else {
            throw HomeLayoutError.unknownFormat(document.format)
        }
        guard document.version == currentVersion else {
            throw HomeLayoutError.unsupportedVersion(document.version)
        }
        return document
    }
}
