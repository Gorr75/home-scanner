import SwiftUI
import RoomScanCore

/// Lines a room up by hand when the saved map did not lock.
/// The floor plan is the charcoal surface. Pins, furniture, and the saved camera stay on the room.
struct RoomNudgeSheet: View {
    @Environment(HomeStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let homeID: UUID
    let roomIDs: [UUID]
    var sharesSpace: Bool

    @State private var selectedID: UUID?
    @State private var errorMessage: String?

    private var home: Home? { store.home(id: homeID) }

    var body: some View {
        NavigationStack {
            CharcoalScreen {
                VStack(spacing: 16) {
                    if let home {
                        FloorPlanCanvas(
                            layers: PlanLayers.forHome(home),
                            pins: home.pins,
                            showPins: PlanLayers.showsDevicePins(home),
                            selectedPinID: nil,
                            placing: false,
                            interactive: false,
                            markup: .preview,
                            onCharcoal: true
                        )
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    Text("Line the new room up with the doorway. Turns rotate it around its center, and the arrows slide it. Pins, furniture, and the saved camera move with the room.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.mist)
                        .fixedSize(horizontal: false, vertical: true)
                    if !sharesSpace, roomIDs.count > 1, let home {
                        Picker("Room", selection: roomSelection) {
                            ForEach(roomIDs, id: \.self) { id in
                                Text(home.room(id: id)?.name ?? "Room").tag(id)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    VStack(spacing: 10) {
                        Button { nudge(yaw: 0, translation: Vec3(x: 0, y: 0, z: -0.1)) } label: {
                            Image(systemName: "chevron.up")
                        }
                        HStack(spacing: 18) {
                            Button { nudge(yaw: 0, translation: Vec3(x: -0.1, y: 0, z: 0)) } label: {
                                Image(systemName: "chevron.left")
                            }
                            Button { nudge(yaw: 0, translation: Vec3(x: 0.1, y: 0, z: 0)) } label: {
                                Image(systemName: "chevron.right")
                            }
                        }
                        Button { nudge(yaw: 0, translation: Vec3(x: 0, y: 0, z: 0.1)) } label: {
                            Image(systemName: "chevron.down")
                        }
                        HStack(spacing: 12) {
                            Button("Rotate left") { nudge(yaw: -5 * .pi / 180, translation: .zero) }
                            Button("Rotate right") { nudge(yaw: 5 * .pi / 180, translation: .zero) }
                        }
                        .font(.subheadline)
                        Button("Snap to doorways") { snap() }
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.accentOnCharcoal)
                }
                .padding(20)
            }
            .navigationTitle("Line up the room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't move the room", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onAppear {
                selectedID = roomIDs.first
            }
        }
    }

    private var roomSelection: Binding<UUID> {
        Binding(
            get: { selectedID ?? roomIDs.first ?? UUID() },
            set: { selectedID = $0 }
        )
    }

    private var movingIDs: [UUID] {
        if sharesSpace || roomIDs.count <= 1 { return roomIDs }
        return selectedID.map { [$0] } ?? roomIDs
    }

    private func nudge(yaw: Double, translation: Vec3) {
        guard var home else { return }
        let ids = Set(movingIDs)
        let rooms = home.rooms.filter { ids.contains($0.id) }
        var placements = home.structure?.placements ?? home.rooms.map {
            RoomPlacement(roomId: $0.id, yaw: 0, translation: .zero, snapped: false)
        }
        for room in home.rooms where !placements.contains(where: { $0.roomId == room.id }) {
            placements.append(RoomPlacement(roomId: room.id, yaw: 0, translation: .zero, snapped: false))
        }
        placements = ScanCoordinates.nudgeGroup(
            placements: placements,
            rooms: rooms,
            yaw: yaw,
            translation: translation
        )
        write(home: &home, placements: placements, overlaps: home.structure?.overlaps ?? [])
    }

    private func snap() {
        guard var home else { return }
        let ids = Set(movingIDs)
        let incoming = home.rooms.filter { ids.contains($0.id) }
        let existing = home.rooms.filter { !ids.contains($0.id) }
        let join = ScanCoordinates.join(
            existing: existing,
            incoming: incoming,
            incomingMatchAnchors: false,
            incomingShareSpace: sharesSpace || incoming.count > 1,
            anchorRoomId: home.worldMap?.anchorRoomId,
            anchorRoomIds: home.worldMap?.roomIds ?? [],
            existingPlacements: home.structure?.placements ?? []
        )
        write(home: &home, placements: join.placements, overlaps: join.overlaps)
    }

    private func write(home: inout Home, placements: [RoomPlacement], overlaps: [RoomOverlap]) {
        let captured = home.rooms.filter { $0.assets.capturedRoom != nil }.map(\.id)
        do {
            _ = try store.updateAlignment(
                homeId: home.id,
                placements: placements,
                overlaps: overlaps,
                coordinatesAreUnified: false,
                shellWasRebuilt: true,
                overview: ScanCoordinates.overview(rooms: home.rooms, placements: placements),
                roomIds: captured
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
