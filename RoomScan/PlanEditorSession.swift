import Foundation
import Observation
import RoomScanCore

/// Undo stack and the edits that change a home's measured rooms. The canvas owns the in-progress drag.
@MainActor
@Observable
final class PlanEditorSession {
    var selectedRoomID: UUID?
    var selectedOpeningID: UUID?
    private var history = PlanHistory()

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    func canSplit(_ home: Home) -> Bool {
        guard let selectedRoomID, let room = home.room(id: selectedRoomID) else { return false }
        return PlanEditor.canSplit(room.floorPlan)
    }

    var canCopy: Bool { selectedOpeningID != nil && selectedRoomID != nil }

    func commit(roomID: UUID, plan: FloorPlan, in home: Home) -> Home? {
        guard let index = home.rooms.firstIndex(where: { $0.id == roomID }),
              home.rooms[index].floorPlan != plan else {
            return nil
        }
        record(home)
        var edited = home
        edited.rooms[index].floorPlan = plan
        selectedRoomID = roomID
        return edited
    }

    func split(_ home: Home) -> Home? {
        guard let roomID = selectedRoomID,
              let index = home.rooms.firstIndex(where: { $0.id == roomID }) else {
            return nil
        }
        let parent = home.rooms[index]
        let newID = UUID()
        guard let parts = PlanEditor.splitRoom(
            parent,
            newID: newID,
            name: nextName(parent.name, in: home.rooms),
            createdAt: Date()
        ) else { return nil }
        record(home)
        var edited = home
        edited.rooms[index] = parts.kept
        edited.rooms.insert(parts.created, at: index + 1)
        edited.pins = PlanEditor.reassignedPins(edited.pins, from: roomID, to: newID, split: parts.plan)
        selectedOpeningID = nil
        return edited
    }

    func copyOpening(in home: Home) -> Home? {
        guard let roomID = selectedRoomID,
              let openingID = selectedOpeningID,
              let index = home.rooms.firstIndex(where: { $0.id == roomID }),
              let copy = PlanEditor.copyOpening(openingID, in: home.rooms[index].floorPlan) else {
            return nil
        }
        record(home)
        var edited = home
        edited.rooms[index].floorPlan = copy.plan
        selectedOpeningID = copy.openingID
        return edited
    }

    func undo(_ home: Home) -> Home? {
        var copy = history
        guard let restored = copy.undo(current: PlanSnapshot(home: home)) else { return nil }
        history = copy
        clearSelection(ifMissingFrom: restored)
        var edited = home
        edited.rooms = restored.rooms
        edited.pins = restored.pins
        return edited
    }

    func redo(_ home: Home) -> Home? {
        var copy = history
        guard let restored = copy.redo(current: PlanSnapshot(home: home)) else { return nil }
        history = copy
        clearSelection(ifMissingFrom: restored)
        var edited = home
        edited.rooms = restored.rooms
        edited.pins = restored.pins
        return edited
    }

    private func record(_ home: Home) {
        var copy = history
        copy.record(PlanSnapshot(home: home))
        history = copy
    }

    private func clearSelection(ifMissingFrom snapshot: PlanSnapshot) {
        guard let selectedRoomID, let room = snapshot.rooms.first(where: { $0.id == selectedRoomID }) else {
            self.selectedRoomID = nil
            selectedOpeningID = nil
            return
        }
        if let selectedOpeningID, !room.floorPlan.openings.contains(where: { $0.id == selectedOpeningID }) {
            self.selectedOpeningID = nil
        }
    }

    private func nextName(_ base: String, in rooms: [Room]) -> String {
        let names = Set(rooms.map(\.name))
        var number = 2
        var candidate = "\(base) \(number)"
        while names.contains(candidate) {
            number += 1
            candidate = "\(base) \(number)"
        }
        return candidate
    }
}
