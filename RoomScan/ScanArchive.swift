import Foundation
import RoomPlan

enum ScanArchiveError: Error {
    case exportFailed
}

extension ScanArchiveError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .exportFailed:
            return "RoomPlan could not write the 3D model."
        }
    }
}

enum ScanArchive {
    static func encodeRoom(_ room: CapturedRoom) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(room)
    }

    static func decodeRoom(_ data: Data) throws -> CapturedRoom {
        try JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    static func encodeStructure(_ structure: CapturedStructure) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(structure)
    }

    static func usdzData(for room: CapturedRoom) throws -> Data {
        try writeUSDZ { url in
            try room.export(to: url)
        }
    }

    static func usdzData(for structure: CapturedStructure) throws -> Data {
        try writeUSDZ { url in
            try structure.export(to: url)
        }
    }

    static func buildStructure(from rooms: [CapturedRoom]) async throws -> CapturedStructure {
        let builder = StructureBuilder(options: [.beautifyObjects])
        return try await builder.capturedStructure(from: rooms)
    }

    private static func writeUSDZ(_ export: (URL) throws -> Void) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).usdz")
        defer { try? FileManager.default.removeItem(at: url) }
        try export(url)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ScanArchiveError.exportFailed
        }
        return try Data(contentsOf: url)
    }
}
