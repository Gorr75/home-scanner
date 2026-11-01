import SwiftUI

enum Theme {
    static let paper = Color(red: 0.957, green: 0.941, blue: 0.910)
    static let card = Color(red: 0.988, green: 0.980, blue: 0.965)
    static let ink = Color(red: 0.110, green: 0.098, blue: 0.082)
    static let secondary = Color(red: 0.361, green: 0.337, blue: 0.298)
    static let line = Color(red: 0.851, green: 0.820, blue: 0.765)
    static let accent = Color(red: 0.122, green: 0.420, blue: 0.353)
    static let accentSoft = Color(red: 0.894, green: 0.937, blue: 0.918)
    static let warn = Color(red: 0.549, green: 0.227, blue: 0.196)

    static let roomTints: [Color] = [
        Color(red: 0.93, green: 0.89, blue: 0.80),
        Color(red: 0.86, green: 0.90, blue: 0.86),
        Color(red: 0.90, green: 0.86, blue: 0.80),
        Color(red: 0.86, green: 0.88, blue: 0.91)
    ]

    static func roomTint(_ index: Int) -> Color {
        roomTints[abs(index) % roomTints.count]
    }
}

struct PaperScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper.ignoresSafeArea())
    }
}

struct LiDARNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "viewfinder")
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(LiDARSupport.unavailableReason)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
