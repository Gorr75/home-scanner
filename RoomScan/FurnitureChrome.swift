import SwiftUI
import RoomScanCore

struct FloorTabBar: View {
    var floors: [FloorSummary]
    var selection: Int
    var onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(floors) { floor in
                    Button {
                        onSelect(floor.level)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(floor.name)
                                .font(.subheadline.weight(.semibold))
                            Text("Level \(floor.level)")
                                .font(.caption2)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            floor.level == selection ? Theme.navy : Theme.navy.opacity(0.35),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .foregroundStyle(Theme.chalk)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(floor.name), level \(floor.level)")
                    .accessibilityAddTraits(floor.level == selection ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.charcoal)
    }
}

struct FurnitureAdjustBar: View {
    var title: String
    var onCharcoal: Bool
    var onRotate: (Double) -> Void
    var onScale: (Double) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("Drag to move")
                    .font(.caption2)
                    .foregroundStyle(onCharcoal ? Theme.mist : Theme.secondary)
            }
            Spacer(minLength: 8)
            Button {
                onRotate(-.pi / 12)
            } label: {
                Image(systemName: "rotate.left")
            }
            .accessibilityLabel("Rotate left")
            Button {
                onRotate(.pi / 12)
            } label: {
                Image(systemName: "rotate.right")
            }
            .accessibilityLabel("Rotate right")
            Button {
                onScale(1 / 1.1)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityLabel("Scale down")
            Button {
                onScale(1.1)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("Scale up")
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Remove furniture")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(onCharcoal ? Theme.navy : Theme.card)
        .foregroundStyle(onCharcoal ? Theme.chalk : Theme.ink)
    }
}

struct FurnitureCatalogSheet: View {
    var suggestedID: String?
    var onPick: (FurnitureCatalogItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let suggestedID, let suggested = FurnitureCatalog.item(id: suggestedID) {
                    Section("Matches the scan") {
                        row(suggested)
                    }
                }
                Section("Catalog") {
                    ForEach(FurnitureCatalog.all) { item in
                        row(item)
                    }
                }
            }
            .navigationTitle("Furniture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func row(_ item: FurnitureCatalogItem) -> some View {
        Button {
            onPick(item)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .foregroundStyle(Theme.ink)
                    Text("\(ObjectLabels.meters(item.nominalSize.x)) × \(ObjectLabels.meters(item.nominalSize.y)) × \(ObjectLabels.meters(item.nominalSize.z)) m")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(Theme.accent)
            }
        }
        .buttonStyle(.plain)
    }
}
