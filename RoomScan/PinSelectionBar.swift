import SwiftUI
import RoomScanCore

struct PinSelectionBar: View {
    var pin: DevicePin
    var snapshot: EntitySnapshot?
    var onCharcoal: Bool
    var onToggle: () -> Void
    var onBrightness: (Double) -> Void
    var onEdit: () -> Void

    @State private var draftBrightness: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: pin.kind.symbolName)
                    .foregroundStyle(onCharcoal ? Theme.accentOnCharcoal : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(onCharcoal ? Theme.chalk : Theme.ink)
                    Text(snapshot?.displayState ?? pin.entityId ?? "Not linked")
                        .font(.caption)
                        .foregroundStyle(onCharcoal ? Theme.mist : Theme.secondary)
                }
                Spacer()
                if let snapshot, snapshot.isToggleable {
                    Button(snapshot.isOn ? "Turn off" : "Turn on", action: onToggle)
                        .buttonStyle(.bordered)
                }
                Button("Edit", action: onEdit)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
            }
            if snapshot?.domain == "light" {
                brightness
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(onCharcoal ? Theme.navy : Theme.card)
    }

    private var brightness: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Brightness")
                .font(.caption2)
                .foregroundStyle(onCharcoal ? Theme.mist : Theme.secondary)
            Slider(
                value: Binding(
                    get: { draftBrightness ?? shownBrightness },
                    set: { draftBrightness = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let level = draftBrightness {
                        onBrightness(level)
                        draftBrightness = nil
                    }
                }
            )
            .tint(onCharcoal ? Theme.accentOnCharcoal : Theme.accent)
            .accessibilityLabel("Brightness")
        }
    }

    private var shownBrightness: Double {
        if let brightness = snapshot?.brightness { return min(1, max(0, brightness)) }
        return snapshot?.isOn == true ? 1 : 0
    }
}
