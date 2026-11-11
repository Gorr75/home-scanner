import Foundation
import Network
import Observation
import RoomScanCore

enum HomeLibraryPaths {
    static func localHomesRoot(fileManager: FileManager = .default) -> URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return documents.appendingPathComponent(ICloudLibrary.homesFolderName, isDirectory: true)
    }
}

/// File moves and conflict versions stay off the main actor. `NSFileCoordinator` is used for the copy.
private enum ICloudLibraryTransfer {
    static func copy(from source: URL, to destination: URL) throws -> HomeLibraryMigrationReport {
        try HomeLibraryMigrator.migrate(from: source, to: destination, disk: CoordinatedHomeDisk())
    }

    /// Last-writer-wins for each ubiquity conflict version. The older file is kept under `conflicts/`.
    static func resolveVersions(in libraryRoot: URL) throws -> Int {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: libraryRoot.path),
              let enumerator = fileManager.enumerator(
                at: libraryRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return 0
        }
        let disk = CoordinatedHomeDisk(fileManager: fileManager)
        let rootPath = libraryRoot.standardizedFileURL.path
        var resolved = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            let relative = relativePath(from: rootPath, to: item)
            let parts = relative.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2 else { continue }
            let fileRelative = parts[1]
            if fileRelative == HomeLibraryFolder.conflicts || fileRelative.hasPrefix(HomeLibraryFolder.conflicts + "/") {
                if values?.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isDirectory == true { continue }
            guard let versions = NSFileVersion.unresolvedConflictVersionsOfItem(at: item), !versions.isEmpty else {
                continue
            }
            for version in versions {
                _ = try HomeLibraryMigrator.absorb(
                    incoming: version.url,
                    relativePath: fileRelative,
                    homeFolder: parts[0],
                    libraryRoot: libraryRoot,
                    disk: disk
                )
                version.isResolved = true
                resolved += 1
            }
            try NSFileVersion.removeOtherVersionsOfItem(at: item)
        }
        return resolved
    }

    static func startDownloads(in libraryRoot: URL) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: libraryRoot,
            includingPropertiesForKeys: [.ubiquitousItemDownloadingStatusKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        while let item = enumerator.nextObject() as? URL {
            let status = try? item.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
            guard status == .notDownloaded || status == .downloaded else { continue }
            try? fileManager.startDownloadingUbiquitousItem(at: item)
        }
    }

    private static func relativePath(from rootPath: String, to item: URL) -> String {
        var full = item.standardizedFileURL.path
        if full.hasPrefix(rootPath) {
            full.removeFirst(rootPath.count)
        }
        if full.hasPrefix("/") {
            full.removeFirst()
        }
        return full
    }
}

@MainActor
@Observable
final class ICloudSyncController {
    private(set) var syncEnabled: Bool
    private(set) var accountAvailable: Bool
    private(set) var phase: ICloudSyncPhase
    private(set) var conflicts: [ConflictCopy] = []
    private(set) var isWorking = false
    private(set) var lastError: String?
    private(set) var backupMessage: String?

    private(set) var signals = ICloudSyncSignals(accountAvailable: false, networkAvailable: true)

    var statusText: String {
        if !accountAvailable { return ICloudSyncPhase.notSignedIn.label }
        if !syncEnabled { return "Off" }
        return phase.label
    }

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var store: HomeStore?
    private var cloudRoot: URL?
    private var usingCloud = false
    private var started = false
    private var refreshInFlight = false
    private var refreshAgain = false
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var downloadedManifests: Set<String> = []
    private let pathMonitor = NWPathMonitor()

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        let account = fileManager.ubiquityIdentityToken != nil
        let stored = defaults.object(forKey: ICloudSyncPreference.enabledKey) as? Bool
        let enabled = ICloudSyncPreference.isEnabled(stored: stored, accountAvailable: account)
        self.accountAvailable = account
        self.syncEnabled = enabled
        self.signals = ICloudSyncSignals(accountAvailable: account, networkAvailable: true)
        self.phase = account ? .synced : .notSignedIn
    }

    func start(store: HomeStore) {
        self.store = store
        guard !started else { return }
        started = true
        observeAccountAndNetwork()
        scheduleRefresh()
    }

    func setSyncEnabled(_ enabled: Bool) {
        guard enabled != syncEnabled else { return }
        defaults.set(enabled, forKey: ICloudSyncPreference.enabledKey)
        syncEnabled = enabled
        backupMessage = nil
        lastError = nil
        scheduleRefresh()
    }

    func backupNow() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        backupMessage = nil
        guard fileManager.ubiquityIdentityToken != nil else {
            accountAvailable = false
            var updated = signals
            updated.accountAvailable = false
            signals = updated
            phase = .notSignedIn
            lastError = "Sign in to iCloud to back up homes."
            return
        }
        guard let container = await containerURL() else {
            lastError = "iCloud Drive isn't available right now. Homes stay on this device."
            setDriveAvailable(false)
            publishPhase()
            return
        }
        setDriveAvailable(true)
        let cloud = ICloudLibrary.homesRoot(inContainer: container)
        do {
            let report: HomeLibraryMigrationReport
            if syncEnabled {
                try await activateCloud(container)
                report = HomeLibraryMigrationReport()
            } else {
                report = try await transfer { try ICloudLibraryTransfer.copy(from: HomeLibraryPaths.localHomesRoot(), to: cloud) }
            }
            let resolved = try await transfer { try ICloudLibraryTransfer.resolveVersions(in: cloud) }
            await transfer { ICloudLibraryTransfer.startDownloads(in: cloud) }
            if usingCloud {
                try store?.reload()
            }
            try reloadConflicts()
            lastError = nil
            backupMessage = backupSummary(report: report, resolvedVersions: resolved)
        } catch {
            lastError = error.localizedDescription
        }
        publishPhase()
    }

    func adopt(_ copy: ConflictCopy) {
        applyChoice { disk, root in
            try HomeLibraryMigrator.adopt(copy, in: root, disk: disk)
        }
    }

    func discard(_ copy: ConflictCopy) {
        applyChoice { disk, root in
            try HomeLibraryMigrator.discard(copy, in: root, disk: disk)
        }
    }

    private func scheduleRefresh() {
        if refreshInFlight {
            refreshAgain = true
            return
        }
        refreshInFlight = true
        Task {
            await refresh()
            refreshInFlight = false
            if refreshAgain {
                refreshAgain = false
                scheduleRefresh()
            }
        }
    }

    private func refresh() async {
        accountAvailable = fileManager.ubiquityIdentityToken != nil
        var accountSignals = signals
        accountSignals.accountAvailable = accountAvailable
        signals = accountSignals
        let stored = defaults.object(forKey: ICloudSyncPreference.enabledKey) as? Bool
        syncEnabled = ICloudSyncPreference.isEnabled(stored: stored, accountAvailable: accountAvailable)
        guard syncEnabled else {
            await disableSync()
            return
        }
        guard accountAvailable else {
            stopQuery()
            await returnToLocalIfNeeded()
            phase = .notSignedIn
            lastError = nil
            return
        }
        guard let container = await containerURL() else {
            stopQuery()
            await returnToLocalIfNeeded()
            setDriveAvailable(false)
            lastError = "iCloud Drive isn't available right now. Homes stay on this device."
            publishPhase()
            return
        }
        setDriveAvailable(true)
        do {
            try await activateCloud(container)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            await returnToLocalIfNeeded()
        }
        publishPhase()
    }

    private func activateCloud(_ container: URL) async throws {
        let cloud = ICloudLibrary.homesRoot(inContainer: container)
        cloudRoot = cloud
        // Merge whenever this device still has homes. An empty local folder must not
        // replace a library that already lives in iCloud, which is how a new install restores.
        if localHomesExist() {
            _ = try await transfer {
                try ICloudLibraryTransfer.copy(from: HomeLibraryPaths.localHomesRoot(), to: cloud)
            }
            try useCloud(cloud)
            try HomeLibraryMigrator.removeHomeFolders(at: HomeLibraryPaths.localHomesRoot(), fileManager: fileManager)
        } else if !usingCloud {
            try useCloud(cloud)
        }
        startQueryIfNeeded()
        _ = try await transfer { try ICloudLibraryTransfer.resolveVersions(in: cloud) }
        await transfer { ICloudLibraryTransfer.startDownloads(in: cloud) }
        try reloadConflicts()
        try store?.reload()
    }

    private func disableSync() async {
        stopQuery()
        if usingCloud, let cloudRoot {
            do {
                _ = try await transfer {
                    try ICloudLibraryTransfer.copy(from: cloudRoot, to: HomeLibraryPaths.localHomesRoot())
                }
                try useLocal()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                defaults.set(true, forKey: ICloudSyncPreference.enabledKey)
                syncEnabled = true
                startQueryIfNeeded()
            }
        } else {
            try? useLocal()
        }
        try? reloadConflicts()
        publishPhase()
    }

    /// Signed out, or iCloud Drive has not come up yet. Keep the on-device library.
    private func returnToLocalIfNeeded() async {
        guard usingCloud, let cloudRoot else {
            try? useLocal()
            try? reloadConflicts()
            return
        }
        do {
            _ = try await transfer {
                try ICloudLibraryTransfer.copy(from: cloudRoot, to: HomeLibraryPaths.localHomesRoot())
            }
        } catch {
            lastError = error.localizedDescription
        }
        try? useLocal()
        try? reloadConflicts()
    }

    private func localHomesExist() -> Bool {
        let root = HomeLibraryPaths.localHomesRoot(fileManager: fileManager)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        return entries.contains { url in
            var isDirectory = ObjCBool(false)
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func useCloud(_ root: URL) throws {
        guard let store else { return }
        try store.useLibrary(at: root, disk: CoordinatedHomeDisk(fileManager: fileManager))
        usingCloud = true
        cloudRoot = root
    }

    private func useLocal() throws {
        guard let store else { return }
        try store.useLibrary(at: HomeLibraryPaths.localHomesRoot(fileManager: fileManager), disk: LocalHomeDisk(fileManager: fileManager))
        usingCloud = false
    }

    private func applyChoice(_ body: (HomeDisk, URL) throws -> Void) {
        do {
            let disk: HomeDisk = usingCloud ? CoordinatedHomeDisk(fileManager: fileManager) : LocalHomeDisk(fileManager: fileManager)
            try body(disk, activeRoot)
            try store?.reload()
            try reloadConflicts()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var activeRoot: URL {
        if usingCloud, let cloudRoot { return cloudRoot }
        return HomeLibraryPaths.localHomesRoot(fileManager: fileManager)
    }

    private func reloadConflicts() throws {
        let disk: HomeDisk = usingCloud ? CoordinatedHomeDisk(fileManager: fileManager) : LocalHomeDisk(fileManager: fileManager)
        conflicts = try HomeLibraryMigrator.conflictCopies(in: activeRoot, disk: disk)
    }

    private func backupSummary(report: HomeLibraryMigrationReport, resolvedVersions: Int) -> String {
        let conflicts = report.conflicts.count + resolvedVersions
        if !signals.networkAvailable {
            return "Saved on this device. It will upload when you are back online."
        }
        if conflicts > 0 {
            let noun = conflicts == 1 ? "older file was" : "older files were"
            return "Backed up. \(conflicts) \(noun) kept so you can choose them."
        }
        return "Backed up. iCloud will finish uploading."
    }

    private func setDriveAvailable(_ available: Bool) {
        var updated = signals
        updated.driveAvailable = available
        signals = updated
    }

    private func publishPhase() {
        var updated = signals
        updated.accountAvailable = accountAvailable
        signals = updated
        phase = signals.phase
    }

    private func containerURL() async -> URL? {
        let identifier = ICloudLibrary.containerIdentifier
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier)
                continuation.resume(returning: url)
            }
        }
    }

    private func transfer<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func observeAccountAndNetwork() {
        observeIdentityChanges()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                var updated = self.signals
                updated.networkAvailable = available
                self.signals = updated
                self.publishPhase()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "se.jansson.homescan.icloud-path"))
    }

    private func startQueryIfNeeded() {
        guard query == nil else { return }
        let metadataQuery = NSMetadataQuery()
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        metadataQuery.predicate = NSPredicate(value: true)
        let names: [Notification.Name] = [.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: metadataQuery, queue: .main) { [weak self] notification in
                Task { @MainActor in
                    self?.handleQuery(notification)
                }
            })
        }
        metadataQuery.start()
        query = metadataQuery
    }

    private func stopQuery() {
        query?.stop()
        query = nil
        downloadedManifests = []
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        observeIdentityChanges()
    }

    private func observeIdentityChanges() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSUbiquityIdentityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleRefresh()
            }
        })
    }

    private func handleQuery(_ notification: Notification) {
        guard let metadataQuery = notification.object as? NSMetadataQuery else { return }
        metadataQuery.disableUpdates()
        defer { metadataQuery.enableUpdates() }
        var uploading = 0
        var pending = 0
        var downloading = 0
        var conflicted = false
        var manifests: Set<String> = []
        let homesPath = cloudRoot?.standardizedFileURL.path
        for case let item as NSMetadataItem in metadataQuery.results {
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { continue }
            if let homesPath, !Self.isInsideLibrary(url, homesPath: homesPath) { continue }
            let isUploading = item.value(forAttribute: NSMetadataUbiquitousItemIsUploadingKey) as? Bool ?? false
            let isUploaded = item.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool ?? true
            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let hasConflict = item.value(forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool ?? false
            if isUploading { uploading += 1 }
            if !isUploaded { pending += 1 }
            if status == NSMetadataUbiquitousItemDownloadingStatusNotDownloaded
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded {
                downloading += 1
                try? fileManager.startDownloadingUbiquitousItem(at: url)
            }
            if hasConflict { conflicted = true }
            if url.lastPathComponent == "home.json" {
                manifests.insert(url.standardizedFileURL.path)
            }
        }
        var updated = signals
        updated.uploadingCount = uploading
        updated.pendingUploadCount = pending
        updated.downloadingCount = downloading
        signals = updated
        publishPhase()
        if conflicted, let cloudRoot {
            Task {
                do {
                    _ = try await self.transfer { try ICloudLibraryTransfer.resolveVersions(in: cloudRoot) }
                    try self.store?.reload()
                    try self.reloadConflicts()
                } catch {
                    self.lastError = error.localizedDescription
                }
            }
        }
        if manifests != downloadedManifests {
            downloadedManifests = manifests
            try? store?.reload()
        }
    }

    private static func isInsideLibrary(_ url: URL, homesPath: String) -> Bool {
        let path = url.standardizedFileURL.path
        let prefix = homesPath.hasSuffix("/") ? homesPath : homesPath + "/"
        return path == homesPath || path.hasPrefix(prefix)
    }
}
