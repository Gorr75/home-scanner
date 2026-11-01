import Foundation
import RoomScanCore

@MainActor
enum HomeExportActions {
    static func packages(for home: Home, store: HomeStore) throws -> [ScanPackage] {
        try HomeExport.packages(
            for: home,
            usdzFiles: store.usdzFiles(in: home),
            textures: store.appliedTextures(in: home)
        )
    }

    static func zipURL(for home: Home, store: HomeStore) throws -> URL {
        let data = try HomeExport.zip(
            for: home,
            usdzFiles: store.usdzFiles(in: home),
            textures: store.appliedTextures(in: home)
        )
        var name = home.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Home" }
        name = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).roomscan.zip")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func send(_ home: Home, store: HomeStore, client: HomeAssistantClient) async throws -> [HomeScannerUploadReceipt] {
        let packages = try packages(for: home, store: store)
        var receipts: [HomeScannerUploadReceipt] = []
        for package in packages {
            let receipt = try await client.upload(slug: package.slug, files: package.files)
            receipts.append(receipt)
        }
        return receipts
    }
}
