import Foundation

public enum HomeLibraryError: Error, Equatable, Sendable {
    case unsafePath(String)
    case unreadable(String)
}

extension HomeLibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            return "Refused to use the path \(path)."
        case .unreadable(let name):
            return "Could not read \(name)."
        }
    }
}

/// iCloud Drive container for this app. The folder iCloud shows is `Documents/Homes`.
public enum ICloudLibrary {
    public static let containerIdentifier = "iCloud.se.jansson.homescan"
    public static let documentsFolderName = "Documents"
    public static let homesFolderName = "Homes"

    public static func homesRoot(inContainer container: URL) -> URL {
        container
            .appendingPathComponent(documentsFolderName, isDirectory: true)
            .appendingPathComponent(homesFolderName, isDirectory: true)
    }
}

/// Folders that live inside one home and therefore travel with the iCloud copy.
public enum HomeLibraryFolder {
    public static let conflicts = "conflicts"
    public static let rooms = "rooms"
    public static let plates = "plates"
    public static let textures = "textures"
    public static let worldMaps = "worldmaps"
    public static let annotations = "annotations"
}

public enum ICloudSyncPreference {
    public static let enabledKey = "homeScanner.iCloudSync.enabled"

    /// A missing preference is on when an iCloud account is available, and off otherwise.
    public static func isEnabled(stored: Bool?, accountAvailable: Bool) -> Bool {
        guard let stored else { return accountAvailable }
        return stored
    }
}

public enum ICloudSyncPhase: String, Equatable, Sendable {
    case synced
    case uploading
    case offline
    case notSignedIn

    public var label: String {
        switch self {
        case .synced: return "Synced"
        case .uploading: return "Uploading"
        case .offline: return "Offline"
        case .notSignedIn: return "Not signed in"
        }
    }
}

public struct ICloudSyncSignals: Equatable, Sendable {
    public var accountAvailable: Bool
    public var networkAvailable: Bool
    /// False when the account exists but the ubiquity container cannot be opened yet.
    public var driveAvailable: Bool
    public var uploadingCount: Int
    public var pendingUploadCount: Int
    public var downloadingCount: Int

    public init(
        accountAvailable: Bool,
        networkAvailable: Bool,
        driveAvailable: Bool = true,
        uploadingCount: Int = 0,
        pendingUploadCount: Int = 0,
        downloadingCount: Int = 0
    ) {
        self.accountAvailable = accountAvailable
        self.networkAvailable = networkAvailable
        self.driveAvailable = driveAvailable
        self.uploadingCount = uploadingCount
        self.pendingUploadCount = pendingUploadCount
        self.downloadingCount = downloadingCount
    }

    /// Downloads during a restore use the same Uploading state. The indicator has these four labels.
    public var phase: ICloudSyncPhase {
        if !accountAvailable { return .notSignedIn }
        if !networkAvailable || !driveAvailable { return .offline }
        if uploadingCount > 0 || pendingUploadCount > 0 || downloadingCount > 0 {
            return .uploading
        }
        return .synced
    }
}

public struct RoomFileSnapshot: Equatable, Sendable {
    public var relativePath: String
    public var modifiedAt: Date
    public var contents: Data

    public init(relativePath: String, modifiedAt: Date, contents: Data) {
        self.relativePath = relativePath
        self.modifiedAt = modifiedAt
        self.contents = contents
    }
}

public struct RoomFileResolution: Equatable, Sendable {
    public var relativePath: String
    public var winner: RoomFileSnapshot
    public var loser: RoomFileSnapshot?
    public var conflictCopyRelativePath: String?

    public init(
        relativePath: String,
        winner: RoomFileSnapshot,
        loser: RoomFileSnapshot?,
        conflictCopyRelativePath: String?
    ) {
        self.relativePath = relativePath
        self.winner = winner
        self.loser = loser
        self.conflictCopyRelativePath = conflictCopyRelativePath
    }
}

public enum RoomFileConflictResolver {
    /// Newer modification date wins. Equal dates keep `current`. Identical bytes are not a conflict.
    /// The loser's bytes are named under `conflicts/` so the home can offer that copy later.
    public static func choose(current: RoomFileSnapshot, incoming: RoomFileSnapshot) -> RoomFileResolution {
        let path = current.relativePath
        if current.contents == incoming.contents {
            let winner = current.modifiedAt >= incoming.modifiedAt ? current : incoming
            return RoomFileResolution(
                relativePath: path,
                winner: winner,
                loser: nil,
                conflictCopyRelativePath: nil
            )
        }
        let currentWins = current.modifiedAt >= incoming.modifiedAt
        let winner = currentWins ? current : incoming
        let loser = currentWins ? incoming : current
        let copy = "\(HomeLibraryFolder.conflicts)/\(path).\(stamp(loser.modifiedAt))"
        return RoomFileResolution(
            relativePath: path,
            winner: winner,
            loser: loser,
            conflictCopyRelativePath: copy
        )
    }

    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}

public struct ConflictCopy: Codable, Equatable, Sendable, Identifiable {
    public var homeFolder: String
    public var originalRelativePath: String
    public var copyRelativePath: String
    public var winnerModifiedAt: Date
    public var loserModifiedAt: Date
    public var recordedAt: Date

    public var id: String { "\(homeFolder)/\(copyRelativePath)" }

    public init(
        homeFolder: String,
        originalRelativePath: String,
        copyRelativePath: String,
        winnerModifiedAt: Date,
        loserModifiedAt: Date,
        recordedAt: Date
    ) {
        self.homeFolder = homeFolder
        self.originalRelativePath = originalRelativePath
        self.copyRelativePath = copyRelativePath
        self.winnerModifiedAt = winnerModifiedAt
        self.loserModifiedAt = loserModifiedAt
        self.recordedAt = recordedAt
    }
}

public struct HomeLibraryMigrationReport: Equatable, Sendable {
    public var copied: [String]
    public var unchanged: [String]
    public var conflicts: [String]

    public init(copied: [String] = [], unchanged: [String] = [], conflicts: [String] = []) {
        self.copied = copied
        self.unchanged = unchanged
        self.conflicts = conflicts
    }
}

public enum HomeLibraryMigrator {
    /// Copies each home from `source` into `destination`, one file at a time.
    /// The file already in `destination` is the current version. The file in `source` is incoming.
    /// A newer file replaces the older one. The older bytes stay under that home's `conflicts/` folder.
    /// Files that exist on only one side are kept. Running this again does not duplicate a conflict
    /// whose bytes were already saved.
    public static func migrate(
        from source: URL,
        to destination: URL,
        disk: HomeDisk = LocalHomeDisk(),
        now: Date = Date()
    ) throws -> HomeLibraryMigrationReport {
        try disk.createDirectory(at: destination)
        guard disk.fileExists(at: source) else {
            return HomeLibraryMigrationReport()
        }
        var report = HomeLibraryMigrationReport()
        for home in try homeDirectories(at: source, disk: disk) {
            let folder = home.lastPathComponent
            let destinationHome = destination.appendingPathComponent(folder, isDirectory: true)
            try disk.createDirectory(at: destinationHome)
            for file in try roomFiles(in: home, disk: disk) {
                let key = "\(folder)/\(file.relative)"
                let outcome = try mergeFile(
                    sourceURL: file.url,
                    relativePath: file.relative,
                    homeFolder: folder,
                    destinationHome: destinationHome,
                    disk: disk,
                    now: now
                )
                switch outcome {
                case .copied: report.copied.append(key)
                case .unchanged: report.unchanged.append(key)
                case .conflict: report.conflicts.append(key)
                }
            }
            try copyMissingConflictArchive(from: home, to: destinationHome, homeFolder: folder, disk: disk)
        }
        report.copied.sort()
        report.unchanged.sort()
        report.conflicts.sort()
        return report
    }

    /// Merges one incoming file into a home that is already in `libraryRoot`.
    /// Used for an iCloud conflict version as well as a single-file backup.
    /// Returns true when the older bytes were kept as a conflict copy.
    @discardableResult
    public static func absorb(
        incoming: URL,
        relativePath: String,
        homeFolder: String,
        libraryRoot: URL,
        disk: HomeDisk = LocalHomeDisk(),
        now: Date = Date()
    ) throws -> Bool {
        let destinationHome = try homeDirectory(homeFolder, in: libraryRoot)
        try disk.createDirectory(at: destinationHome)
        let outcome = try mergeFile(
            sourceURL: incoming,
            relativePath: relativePath,
            homeFolder: homeFolder,
            destinationHome: destinationHome,
            disk: disk,
            now: now
        )
        return outcome == .conflict
    }

    public static func conflictCopies(in libraryRoot: URL, disk: HomeDisk = LocalHomeDisk()) throws -> [ConflictCopy] {
        guard disk.fileExists(at: libraryRoot) else { return [] }
        var listed: [ConflictCopy] = []
        for home in try homeDirectories(at: libraryRoot, disk: disk) {
            let folder = home.lastPathComponent
            var index = loadIndex(in: home, disk: disk)
            let kept = index.copies.filter { copy in
                guard let url = try? resolve(home: home, relative: copy.copyRelativePath) else { return false }
                return disk.fileExists(at: url)
            }
            if kept.count != index.copies.count {
                index.copies = kept
                try saveIndex(index, in: home, disk: disk)
            }
            listed.append(contentsOf: kept.map { copy in
                var stored = copy
                stored.homeFolder = folder
                return stored
            })
        }
        return listed.sorted { $0.id < $1.id }
    }

    /// Replaces the room file with the saved conflict and removes the conflict copy.
    /// The file's modification date becomes `now`, so this device is the last writer.
    public static func adopt(
        _ copy: ConflictCopy,
        in libraryRoot: URL,
        disk: HomeDisk = LocalHomeDisk(),
        now: Date = Date()
    ) throws {
        let home = try homeDirectory(copy.homeFolder, in: libraryRoot)
        let original = try resolve(home: home, relative: copy.originalRelativePath)
        let saved = try resolve(home: home, relative: copy.copyRelativePath)
        guard disk.fileExists(at: saved) else {
            throw HomeLibraryError.unreadable(copy.copyRelativePath)
        }
        let data = try disk.read(from: saved)
        try disk.write(data, to: original)
        try disk.setModificationDate(now, of: original)
        try disk.removeItem(at: saved)
        var index = loadIndex(in: home, disk: disk)
        index.copies.removeAll { $0.copyRelativePath == copy.copyRelativePath }
        try saveIndex(index, in: home, disk: disk)
    }

    /// Keeps the room file that is already in the home and deletes the conflict copy.
    public static func discard(
        _ copy: ConflictCopy,
        in libraryRoot: URL,
        disk: HomeDisk = LocalHomeDisk()
    ) throws {
        let home = try homeDirectory(copy.homeFolder, in: libraryRoot)
        let saved = try resolve(home: home, relative: copy.copyRelativePath)
        try disk.removeItem(at: saved)
        var index = loadIndex(in: home, disk: disk)
        index.copies.removeAll { $0.copyRelativePath == copy.copyRelativePath }
        try saveIndex(index, in: home, disk: disk)
    }

    /// Removes home folders inside a library root. The root itself stays.
    public static func removeHomeFolders(at libraryRoot: URL, fileManager: FileManager = .default) throws {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: libraryRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        let entries = try fileManager.contentsOfDirectory(
            at: libraryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entry in entries {
            var entryIsDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory), entryIsDirectory.boolValue else {
                continue
            }
            try fileManager.removeItem(at: entry)
        }
    }

    private enum MergeOutcome {
        case copied
        case unchanged
        case conflict
    }

    private struct ConflictIndex: Codable, Equatable {
        var copies: [ConflictCopy]
    }

    private static func mergeFile(
        sourceURL: URL,
        relativePath: String,
        homeFolder: String,
        destinationHome: URL,
        disk: HomeDisk,
        now: Date
    ) throws -> MergeOutcome {
        let destinationURL = try resolve(home: destinationHome, relative: relativePath)
        let sourceData = try disk.read(from: sourceURL)
        let sourceDate = disk.modificationDate(of: sourceURL) ?? now
        guard disk.fileExists(at: destinationURL) else {
            try disk.write(sourceData, to: destinationURL)
            try disk.setModificationDate(sourceDate, of: destinationURL)
            return .copied
        }
        let destinationData = try disk.read(from: destinationURL)
        if destinationData == sourceData {
            return .unchanged
        }
        let destinationDate = disk.modificationDate(of: destinationURL) ?? .distantPast
        let resolution = RoomFileConflictResolver.choose(
            current: RoomFileSnapshot(relativePath: relativePath, modifiedAt: destinationDate, contents: destinationData),
            incoming: RoomFileSnapshot(relativePath: relativePath, modifiedAt: sourceDate, contents: sourceData)
        )
        if destinationData != resolution.winner.contents {
            try disk.write(resolution.winner.contents, to: destinationURL)
            try disk.setModificationDate(resolution.winner.modifiedAt, of: destinationURL)
        }
        guard let loser = resolution.loser else { return .unchanged }
        try storeConflict(
            loser: loser,
            winner: resolution.winner,
            suggestedRelativePath: resolution.conflictCopyRelativePath,
            homeFolder: homeFolder,
            destinationHome: destinationHome,
            disk: disk,
            now: now
        )
        return .conflict
    }

    private static func storeConflict(
        loser: RoomFileSnapshot,
        winner: RoomFileSnapshot,
        suggestedRelativePath: String?,
        homeFolder: String,
        destinationHome: URL,
        disk: HomeDisk,
        now: Date
    ) throws {
        var index = loadIndex(in: destinationHome, disk: disk)
        for existing in index.copies where existing.originalRelativePath == loser.relativePath {
            guard let url = try? resolve(home: destinationHome, relative: existing.copyRelativePath),
                  disk.fileExists(at: url),
                  (try? disk.read(from: url)) == loser.contents else {
                continue
            }
            return
        }
        let relative = try uniqueConflictPath(
            suggested: suggestedRelativePath ?? "\(HomeLibraryFolder.conflicts)/\(loser.relativePath)",
            in: destinationHome,
            disk: disk
        )
        let url = try resolve(home: destinationHome, relative: relative)
        try disk.write(loser.contents, to: url)
        try disk.setModificationDate(loser.modifiedAt, of: url)
        index.copies.append(
            ConflictCopy(
                homeFolder: homeFolder,
                originalRelativePath: loser.relativePath,
                copyRelativePath: relative,
                winnerModifiedAt: winner.modifiedAt,
                loserModifiedAt: loser.modifiedAt,
                recordedAt: now
            )
        )
        try saveIndex(index, in: destinationHome, disk: disk)
    }

    private static func uniqueConflictPath(suggested: String, in home: URL, disk: HomeDisk) throws -> String {
        var candidate = suggested
        var suffix = 2
        while let url = try? resolve(home: home, relative: candidate), disk.fileExists(at: url) {
            candidate = "\(suggested)-\(suffix)"
            suffix += 1
            if suffix > 50 {
                throw HomeLibraryError.unsafePath(suggested)
            }
        }
        return candidate
    }

    private static func copyMissingConflictArchive(
        from sourceHome: URL,
        to destinationHome: URL,
        homeFolder: String,
        disk: HomeDisk
    ) throws {
        var destinationIndex = loadIndex(in: destinationHome, disk: disk)
        let sourceIndex = loadIndex(in: sourceHome, disk: disk)
        var changed = false
        for record in sourceIndex.copies {
            if destinationIndex.copies.contains(where: { $0.copyRelativePath == record.copyRelativePath }) {
                continue
            }
            guard let sourceURL = try? resolve(home: sourceHome, relative: record.copyRelativePath),
                  disk.fileExists(at: sourceURL) else {
                continue
            }
            let destinationURL = try resolve(home: destinationHome, relative: record.copyRelativePath)
            if !disk.fileExists(at: destinationURL) {
                let data = try disk.read(from: sourceURL)
                try disk.write(data, to: destinationURL)
                if let date = disk.modificationDate(of: sourceURL) {
                    try disk.setModificationDate(date, of: destinationURL)
                }
            }
            var stored = record
            stored.homeFolder = homeFolder
            destinationIndex.copies.append(stored)
            changed = true
        }
        if changed {
            try saveIndex(destinationIndex, in: destinationHome, disk: disk)
        }
    }

    private static func homeDirectories(at root: URL, disk: HomeDisk) throws -> [URL] {
        try disk.contentsOfDirectory(at: root).filter { disk.isDirectory($0) }
    }

    private static func roomFiles(in home: URL, disk: HomeDisk) throws -> [(relative: String, url: URL)] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: home,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [(String, URL)] = []
        while let item = enumerator.nextObject() as? URL {
            let relative = relativePath(from: home, to: item)
            if relative == HomeLibraryFolder.conflicts || relative.hasPrefix(HomeLibraryFolder.conflicts + "/") {
                if disk.isDirectory(item) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if disk.isDirectory(item) { continue }
            guard RelativePath.isSafe(relative) else { continue }
            files.append((relative, item))
        }
        return files
    }

    private static func relativePath(from home: URL, to item: URL) -> String {
        let base = home.standardizedFileURL.path
        var full = item.standardizedFileURL.path
        if full.hasPrefix(base) {
            full.removeFirst(base.count)
        }
        if full.hasPrefix("/") {
            full.removeFirst()
        }
        return full
    }

    private static func homeDirectory(_ folder: String, in libraryRoot: URL) throws -> URL {
        guard RelativePath.isSafe(folder), !folder.contains("/") else {
            throw HomeLibraryError.unsafePath(folder)
        }
        return libraryRoot.appendingPathComponent(folder, isDirectory: true)
    }

    private static func resolve(home: URL, relative: String) throws -> URL {
        guard let url = RelativePath.resolve(homeDirectory: home, relative: relative) else {
            throw HomeLibraryError.unsafePath(relative)
        }
        return url
    }

    private static func loadIndex(in home: URL, disk: HomeDisk) -> ConflictIndex {
        let url = home.appendingPathComponent(HomeLibraryFolder.conflicts).appendingPathComponent("index.json")
        guard disk.fileExists(at: url), let data = try? disk.read(from: url) else {
            return ConflictIndex(copies: [])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ConflictIndex.self, from: data)) ?? ConflictIndex(copies: [])
    }

    private static func saveIndex(_ index: ConflictIndex, in home: URL, disk: HomeDisk) throws {
        let url = home.appendingPathComponent(HomeLibraryFolder.conflicts).appendingPathComponent("index.json")
        if index.copies.isEmpty {
            try disk.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try disk.write(try encoder.encode(index), to: url)
    }
}
