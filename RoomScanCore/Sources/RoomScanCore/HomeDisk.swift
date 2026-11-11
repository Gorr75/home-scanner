import Foundation

/// File access for a home library. The app uses a coordinating implementation for the
/// iCloud Drive container. Tests and the offline library use `LocalHomeDisk`.
public protocol HomeDisk: AnyObject {
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func isDirectory(_ url: URL) -> Bool
    func fileExists(at url: URL) -> Bool
    func read(from url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func removeItem(at url: URL) throws
    func modificationDate(of url: URL) -> Date?
    func setModificationDate(_ date: Date, of url: URL) throws
}

public final class LocalHomeDisk: HomeDisk {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
    }

    public func isDirectory(_ url: URL) -> Bool {
        if let value = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory {
            return value
        }
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    public func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func removeItem(at url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func modificationDate(of url: URL) -> Date? {
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            return date
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    public func setModificationDate(_ date: Date, of url: URL) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
