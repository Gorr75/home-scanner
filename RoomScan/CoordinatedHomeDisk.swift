import Foundation
import RoomScanCore

/// Home library IO through `NSFileCoordinator`. iCloud Drive expects every read and write
/// in the ubiquity container to be coordinated. The same path is safe for a local folder.
final class CoordinatedHomeDisk: HomeDisk {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func createDirectory(at url: URL) throws {
        try coordinate(writing: url) { target in
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try coordinate(reading: url) { target in
            try fileManager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        }
    }

    func isDirectory(_ url: URL) -> Bool {
        if let value = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return value
        }
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func read(from url: URL) throws -> Data {
        try coordinate(reading: url) { target in
            try Data(contentsOf: target)
        }
    }

    func write(_ data: Data, to url: URL) throws {
        try coordinate(writing: url) { target in
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
        }
    }

    func removeItem(at url: URL) throws {
        try coordinate(writing: url, options: .forDeleting) { target in
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
        }
    }

    func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    func setModificationDate(_ date: Date, of url: URL) throws {
        try coordinate(writing: url) { target in
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: target.path)
        }
    }

    private func coordinate<T>(reading url: URL, body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try body(readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try value(result, url: url)
    }

    private func coordinate<T>(
        writing url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        body: (URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { writeURL in
            result = Result { try body(writeURL) }
        }
        if let coordinationError { throw coordinationError }
        return try value(result, url: url)
    }

    private func value<T>(_ result: Result<T, Error>?, url: URL) throws -> T {
        switch result {
        case .success(let value):
            return value
        case .failure(let error):
            throw error
        case .none:
            throw HomeLibraryError.unreadable(url.lastPathComponent)
        }
    }
}
