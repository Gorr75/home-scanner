import SwiftUI

enum Theme {
    // Lists, settings, and the rest of the paper chrome.
    static let paper = Color(red: 0.957, green: 0.941, blue: 0.910)
    static let card = Color(red: 0.988, green: 0.980, blue: 0.965)
    static let ink = Color(red: 0.110, green: 0.098, blue: 0.082)
    static let secondary = Color(red: 0.361, green: 0.337, blue: 0.298)
    static let line = Color(red: 0.851, green: 0.820, blue: 0.765)
    static let accent = Color(red: 0.122, green: 0.420, blue: 0.353)
    static let accentSoft = Color(red: 0.894, green: 0.937, blue: 0.918)
    static let warn = Color(red: 0.549, green: 0.227, blue: 0.196)

    // 3D viewer and floor plan. Warm charcoal `#100e0c`, navy panel `#1c2230`.
    static let charcoal = Color(red: 16.0 / 255, green: 14.0 / 255, blue: 12.0 / 255)
    static let navy = Color(red: 28.0 / 255, green: 34.0 / 255, blue: 48.0 / 255)
    /// Ivory type on charcoal. Same value as `paper`.
    static let chalk = paper
    static let mist = Color(red: 0.73, green: 0.69, blue: 0.63)
    static let charcoalLine = Color(red: 0.42, green: 0.38, blue: 0.34)
    /// Same teal hue as `accent`, lifted so strokes and icons clear charcoal and navy.
    static let accentOnCharcoal = Color(red: 0.27, green: 0.60, blue: 0.52)

    static let roomTints: [Color] = [
        Color(red: 0.93, green: 0.89, blue: 0.80),
        Color(red: 0.86, green: 0.90, blue: 0.86),
        Color(red: 0.90, green: 0.86, blue: 0.80),
        Color(red: 0.86, green: 0.88, blue: 0.91)
    ]

    /// Darker versions of `roomTints`, so chalk walls and labels stay readable on the plan.
    static let roomTintsOnCharcoal: [Color] = [
        Color(red: 0.32, green: 0.27, blue: 0.20),
        Color(red: 0.22, green: 0.30, blue: 0.26),
        Color(red: 0.34, green: 0.27, blue: 0.20),
        Color(red: 0.22, green: 0.26, blue: 0.34)
    ]

    static func roomTint(_ index: Int, onCharcoal: Bool = false) -> Color {
        let colors = onCharcoal ? roomTintsOnCharcoal : roomTints
        return colors[abs(index) % colors.count]
    }
}

extension View {
    /// Ivory ground, dark system text, and an ivory navigation bar.
    func paperChrome() -> some View {
        background(Theme.paper.ignoresSafeArea())
            .toolbarBackground(Theme.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
            .environment(\.colorScheme, .light)
    }

    /// Charcoal ground, light system text, and a charcoal navigation bar.
    /// The tint is the lifted teal so bordered controls stay readable on navy.
    func charcoalChrome() -> some View {
        background(Theme.charcoal.ignoresSafeArea())
            .tint(Theme.accentOnCharcoal)
            .toolbarBackground(Theme.charcoal, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    func surfaceChrome(charcoal: Bool) -> some View {
        if charcoal {
            charcoalChrome()
        } else {
            paperChrome()
        }
    }
}

struct PaperScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .paperChrome()
    }
}

struct CharcoalScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .charcoalChrome()
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
