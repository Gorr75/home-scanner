import Foundation
import RoomPlan
import RoomScanCore

struct ScanPiece: Identifiable {
    var section: ScanCheckpointSection
    var room: CapturedRoom
    var plan: FloorPlan
    var json: Data
    var usdz: Data?

    var id: UUID { section.id }
}

enum ScanCommitError: Error {
    case empty
}

extension ScanCommitError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .empty:
            return "The scan did not capture a room to save."
        }
    }
}

enum ScanCommit {
    struct Result {
        var needsNudge: Bool
        var roomIDs: [UUID]
        var sharesSpace: Bool
    }

    static func load(checkpoint: ScanCheckpoint, from store: ScanCheckpointStore) throws -> [ScanPiece] {
        var pieces: [ScanPiece] = []
        for section in checkpoint.sections {
            let data: Data
            do {
                data = try store.data(checkpoint.id, relative: section.capturedRoom)
            } catch {
                continue
            }
            let room = try ScanArchive.decodeRoom(data)
            let json = try ScanArchive.encodeRoom(room)
            pieces.append(ScanPiece(
                section: section,
                room: room,
                plan: FloorPlanExtractor.floorPlan(from: room),
                json: json,
                usdz: try? ScanArchive.usdzData(for: room)
            ))
        }
        guard !pieces.isEmpty else { throw ScanCommitError.empty }
        return pieces
    }

    static func worldMap(for checkpoint: ScanCheckpoint, from store: ScanCheckpointStore) -> Data? {
        guard let relative = checkpoint.worldMap else { return nil }
        return try? store.data(checkpoint.id, relative: relative)
    }

    @MainActor
    static func save(
        pieces: [ScanPiece],
        homeID: UUID,
        replacingRoomID: UUID?,
        worldMap: Data?,
        frames: [ScanHeldFrame],
        store: HomeStore
    ) async throws -> Result {
        if let replacingRoomID {
            try replace(
                pieces: pieces,
                homeID: homeID,
                roomID: replacingRoomID,
                worldMap: worldMap,
                frames: frames,
                store: store
            )
            return Result(needsNudge: false, roomIDs: [], sharesSpace: false)
        }
        guard !pieces.isEmpty else { throw ScanCommitError.empty }
        let drafts = pieces.map { piece in
            CapturedRoomDraft(
                id: piece.section.id,
                name: piece.section.name,
                floor: piece.section.floor,
                floorPlan: piece.plan,
                capturedJSON: piece.json,
                usdz: piece.usdz
            )
        }
        let saved = try store.addCapturedRooms(homeId: homeID, drafts: drafts)
        let paired: [(piece: ScanPiece, room: Room)] = pieces.compactMap { piece in
            guard let room = saved.room(id: piece.section.id) else { return nil }
            return (piece, room)
        }
        guard paired.count == pieces.count else { throw ScanCommitError.empty }
        for pair in paired {
            try store.installScanFrames(
                frames.map { (id: $0.id, jpeg: $0.jpeg, pose: $0.pose) },
                plan: pair.room.floorPlan,
                homeId: homeID
            )
        }
        let joined = try await place(paired, in: saved, worldMap: worldMap, store: store)
        return joined
    }

    @MainActor
    private static func replace(
        pieces: [ScanPiece],
        homeID: UUID,
        roomID: UUID,
        worldMap: Data?,
        frames: [ScanHeldFrame],
        store: HomeStore
    ) throws {
        guard let piece = pieces.last else { throw ScanCommitError.empty }
        _ = try store.replaceCapturedRoom(
            homeId: homeID,
            roomId: roomID,
            floorPlan: piece.plan,
            capturedJSON: piece.json,
            usdz: piece.usdz
        )
        try store.installScanFrames(
            frames.map { (id: $0.id, jpeg: $0.jpeg, pose: $0.pose) },
            plan: piece.plan,
            homeId: homeID
        )
        guard let home = store.home(id: homeID) else { return }
        if piece.section.sharesHomeMap, let worldMap {
            var ids = home.worldMap?.roomIds ?? []
            if !ids.contains(roomID) { ids.append(roomID) }
            if ids.isEmpty { ids = [roomID] }
            _ = try store.writeWorldMap(
                homeId: homeID,
                data: worldMap,
                roomIds: ids,
                anchorRoomId: home.worldMap?.anchorRoomId ?? roomID
            )
        } else if var map = home.worldMap, map.roomIds.contains(roomID), !piece.section.sharesHomeMap {
            map.roomIds.removeAll { $0 == roomID }
            _ = try store.updateWorldMapMembership(
                homeId: homeID,
                roomIds: map.roomIds,
                anchorRoomId: map.anchorRoomId == roomID ? map.roomIds.first : map.anchorRoomId
            )
        } else if home.worldMap == nil, let worldMap {
            _ = try store.writeWorldMap(
                homeId: homeID,
                data: worldMap,
                roomIds: [roomID],
                anchorRoomId: roomID
            )
        }
    }

    @MainActor
    private static func place(
        _ paired: [(piece: ScanPiece, room: Room)],
        in home: Home,
        worldMap: Data?,
        store: HomeStore
    ) async throws -> Result {
        var placements = home.structure?.placements ?? []
        var overlaps: [RoomOverlap] = home.structure?.overlaps ?? []
        var needsNudge = false
        var nudged: [UUID] = []
        var nudgedSpaces = Set<UUID>()
        var replacedShell = false
        var unified = home.rooms.count <= 1
        let groups = grouped(paired)
        for group in groups {
            let incoming = group.map(\.room)
            let incomingIDs = Set(incoming.map(\.id))
            let existing = home.rooms.filter { !incomingIDs.contains($0.id) }
            let sharesMap = group.allSatisfy { $0.piece.section.sharesHomeMap }
            let join = ScanCoordinates.join(
                existing: existing,
                incoming: incoming,
                incomingMatchAnchors: sharesMap && home.worldMap != nil,
                incomingShareSpace: true,
                anchorRoomId: home.worldMap?.anchorRoomId,
                anchorRoomIds: home.worldMap?.roomIds ?? [],
                existingPlacements: placements
            )
            placements = join.placements
            overlaps = join.overlaps
            unified = join.coordinatesAreUnified
            if join.replacedShell || join.usedAlignmentFallback {
                replacedShell = true
            }
            if join.usedAlignmentFallback {
                needsNudge = true
                nudged.append(contentsOf: incoming.map(\.id))
                if let space = group.first?.piece.section.spaceId {
                    nudgedSpaces.insert(space)
                }
            }
        }
        let stored = ScanFrameJoin(
            placements: placements,
            overlaps: overlaps,
            coordinatesAreUnified: unified,
            usedAlignmentFallback: needsNudge,
            replacedShell: replacedShell
        )
        try await writeStructure(
            home: home,
            stored: stored,
            worldMap: worldMap,
            mapRoomIDs: mapRoomIDs(in: paired, home: home),
            store: store
        )
        let sharesSpace = nudgedSpaces.count <= 1
        return Result(needsNudge: needsNudge, roomIDs: nudged, sharesSpace: sharesSpace)
    }

    /// Rooms captured in the saved map, or, when the home has no map yet, the latest ARSession.
    private static func mapRoomIDs(
        in paired: [(piece: ScanPiece, room: Room)],
        home: Home
    ) -> [UUID] {
        let locked = paired.filter { $0.piece.section.sharesHomeMap }.map(\.room.id)
        if !locked.isEmpty { return locked }
        guard home.worldMap == nil, let space = paired.last?.piece.section.spaceId else { return [] }
        return paired.filter { $0.piece.section.spaceId == space }.map(\.room.id)
    }

    /// Home-map sections stay together. Everything else is grouped by the ARSession that captured it.
    private static func grouped(
        _ paired: [(piece: ScanPiece, room: Room)]
    ) -> [[(piece: ScanPiece, room: Room)]] {
        var order: [String] = []
        var buckets: [String: [(piece: ScanPiece, room: Room)]] = [:]
        for pair in paired {
            let key = pair.piece.section.sharesHomeMap ? "map" : pair.piece.section.spaceId.uuidString
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(pair)
        }
        // The map group is placed first so a later session can align against it.
        let sorted = order.sorted { lhs, rhs in
            if lhs == "map" { return true }
            if rhs == "map" { return false }
            return lhs < rhs
        }
        return sorted.compactMap { buckets[$0] }
    }

    @MainActor
    private static func writeStructure(
        home: Home,
        stored: ScanFrameJoin,
        worldMap: Data?,
        mapRoomIDs: [UUID],
        store: HomeStore
    ) async throws {
        let alignment = stored.storedAlignment
        let captured = home.rooms.filter { $0.assets.capturedRoom != nil }
        let overview = ScanCoordinates.overview(rooms: home.rooms, placements: alignment.placements)
        var merged = false
        if stored.coordinatesAreUnified, captured.count >= 2, !stored.replacedShell, !stored.usedAlignmentFallback {
            do {
                let payloads = try store.capturedPayloads(in: home)
                let rooms = try payloads.map { try ScanArchive.decodeRoom($0.data) }
                if rooms.count >= 2 {
                    let structure = try await ScanArchive.buildStructure(from: rooms)
                    let shell = FloorPlanExtractor.floorPlan(from: structure)
                    let json = try ScanArchive.encodeStructure(structure)
                    let usdz = try ScanArchive.usdzData(for: structure)
                    _ = try store.attachStructure(
                        homeId: home.id,
                        capturedJSON: json,
                        usdz: usdz,
                        overview: shell,
                        roomIds: payloads.map(\.room.id),
                        coordinatesAreUnified: true,
                        alignment: .none
                    )
                    merged = true
                }
            } catch {
                merged = false
            }
        }
        if !merged, captured.count >= 2 || stored.usedAlignmentFallback {
            _ = try store.updateAlignment(
                homeId: home.id,
                placements: alignment.placements,
                overlaps: alignment.overlaps,
                coordinatesAreUnified: stored.coordinatesAreUnified && !stored.usedAlignmentFallback,
                shellWasRebuilt: true,
                overview: overview,
                roomIds: captured.map(\.id)
            )
        }
        try writeMap(
            home: store.home(id: home.id) ?? home,
            worldMap: worldMap,
            mapRoomIDs: mapRoomIDs,
            store: store
        )
    }

    @MainActor
    private static func writeMap(
        home: Home,
        worldMap: Data?,
        mapRoomIDs: [UUID],
        store: HomeStore
    ) throws {
        guard !mapRoomIDs.isEmpty else { return }
        if let existing = home.worldMap {
            var ids = existing.roomIds
            for id in mapRoomIDs where !ids.contains(id) {
                ids.append(id)
            }
            if let worldMap, !worldMap.isEmpty {
                _ = try store.writeWorldMap(
                    homeId: home.id,
                    data: worldMap,
                    roomIds: ids,
                    anchorRoomId: existing.anchorRoomId ?? existing.roomIds.first
                )
            } else {
                _ = try store.updateWorldMapMembership(
                    homeId: home.id,
                    roomIds: ids,
                    anchorRoomId: existing.anchorRoomId ?? ids.first
                )
            }
        } else if let worldMap, !worldMap.isEmpty {
            _ = try store.writeWorldMap(
                homeId: home.id,
                data: worldMap,
                roomIds: mapRoomIDs,
                anchorRoomId: mapRoomIDs.first
            )
        }
    }
}
