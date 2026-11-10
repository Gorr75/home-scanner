import SwiftUI

/// Undo, redo, split, and copy for the floor-plan editor. Geometry only.
struct PlanEditorBar: View {
    var canUndo: Bool
    var canRedo: Bool
    var canSplit: Bool
    var canCopy: Bool
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onSplit: () -> Void
    var onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUndo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!canUndo)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityLabel("Undo plan edit")

            Button(action: onRedo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel("Redo plan edit")

            Spacer(minLength: 4)

            Button("Copy opening", action: onCopy)
                .disabled(!canCopy)
                .accessibilityLabel("Copy opening on the same wall")

            Button("Split room", action: onSplit)
                .disabled(!canSplit)
                .accessibilityLabel("Split the room in half")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Theme.navy)
    }
}
