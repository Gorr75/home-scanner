import SwiftUI
import UIKit
import RoomScanCore

struct PinLook: Equatable {
    var state: String
    var domain: String
    var brightness: Double?
    var red: Double?
    var green: Double?
    var blue: Double?

    init(_ snapshot: EntitySnapshot) {
        state = snapshot.state
        domain = snapshot.domain
        brightness = snapshot.brightness
        red = snapshot.red
        green = snapshot.green
        blue = snapshot.blue
    }
}

enum PinPaint {
    /// Sphere and plan colour for a live pin. Lights use their colour, scaled by brightness.
    static func channels(_ look: PinLook) -> (red: Double, green: Double, blue: Double) {
        if look.domain == "light" {
            if look.state != "on" {
                return (0.45, 0.42, 0.38)
            }
            let brightness = min(1, max(0, look.brightness ?? 1))
            let gain = 0.22 + 0.78 * brightness
            return (
                (look.red ?? 1) * gain,
                (look.green ?? 0.78) * gain,
                (look.blue ?? 0.45) * gain
            )
        }
        if look.state == "on" { return (0.18, 0.55, 0.32) }
        if look.state == "off" { return (0.45, 0.42, 0.38) }
        return (0.20, 0.38, 0.55)
    }

    static func uiColor(_ look: PinLook?, linked: Bool) -> UIColor {
        guard let look else {
            return linked ? UIColor(Theme.chalk) : UIColor(Theme.accentOnCharcoal)
        }
        let rgb = channels(look)
        return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    static func color(_ look: PinLook?, linked: Bool, muted: Color, accent: Color, ink: Color) -> Color {
        guard let look else {
            return linked ? ink : accent
        }
        if look.domain != "light" {
            if look.state == "on" { return Color(red: 0.18, green: 0.55, blue: 0.32) }
            if look.state == "off" { return muted }
            return Color(red: 0.20, green: 0.38, blue: 0.55)
        }
        let rgb = channels(look)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
