import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Converts Home Assistant light attributes into a 0...1 colour and brightness.
enum LightColorMath {
    static func appearance(from attributes: [String: Any]?) -> (brightness: Double?, red: Double?, green: Double?, blue: Double?) {
        guard let attributes else { return (nil, nil, nil, nil) }
        let brightness = brightnessFraction(attributes["brightness"])
        if let rgb = channels(attributes["rgb_color"]) {
            return (brightness, rgb.0, rgb.1, rgb.2)
        }
        if let hs = hsChannels(attributes["hs_color"]) {
            return (brightness, hs.0, hs.1, hs.2)
        }
        if let kelvin = kelvin(from: attributes) {
            let rgb = rgb(kelvin: kelvin)
            return (brightness, rgb.0, rgb.1, rgb.2)
        }
        return (brightness, nil, nil, nil)
    }

    /// Home Assistant sends brightness as an integer 0...255.
    static func brightnessFraction(_ value: Any?) -> Double? {
        guard let raw = double(value), raw.isFinite else { return nil }
        if raw <= 0 { return 0 }
        return min(1, raw / 255)
    }

    static func channels(_ value: Any?) -> (Double, Double, Double)? {
        guard let numbers = components(value, count: 3) else { return nil }
        let scale = numbers.max() ?? 0 > 1 ? 255.0 : 1.0
        return (
            clamp(numbers[0] / scale),
            clamp(numbers[1] / scale),
            clamp(numbers[2] / scale)
        )
    }

    /// Hue is degrees. Saturation is 0...100 from Home Assistant, or 0...1.
    static func hsChannels(_ value: Any?) -> (Double, Double, Double)? {
        guard let numbers = components(value, count: 2) else { return nil }
        let hue = numbers[0].truncatingRemainder(dividingBy: 360)
        let wrapped = hue < 0 ? hue + 360 : hue
        var saturation = numbers[1]
        if saturation > 1 { saturation /= 100 }
        return hsv(hue: wrapped, saturation: clamp(saturation), value: 1)
    }

    static func rgb(kelvin: Double) -> (Double, Double, Double) {
        let temperature = kelvin / 100
        let red: Double
        let green: Double
        let blue: Double
        if temperature <= 66 {
            red = 255
            green = 99.4708025861 * log(temperature) - 161.1195681661
        } else {
            red = 329.698727446 * pow(temperature - 60, -0.1332047592)
            green = 288.1221695283 * pow(temperature - 60, -0.0755148492)
        }
        if temperature >= 66 {
            blue = 255
        } else if temperature <= 19 {
            blue = 0
        } else {
            blue = 138.5177312231 * log(temperature - 10) - 305.0447927307
        }
        return (clamp(red / 255), clamp(green / 255), clamp(blue / 255))
    }

    private static func kelvin(from attributes: [String: Any]) -> Double? {
        if let kelvin = double(attributes["color_temp_kelvin"]), kelvin > 500, kelvin < 20_000 {
            return kelvin
        }
        if let mired = double(attributes["color_temp"]), mired > 0 {
            let kelvin = 1_000_000 / mired
            if kelvin > 500, kelvin < 20_000 { return kelvin }
        }
        return nil
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
        let sector = hue / 60
        let chroma = value * saturation
        let x = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let match = value - chroma
        let (red, green, blue): (Double, Double, Double)
        switch sector {
        case 0..<1: (red, green, blue) = (chroma, x, 0)
        case 1..<2: (red, green, blue) = (x, chroma, 0)
        case 2..<3: (red, green, blue) = (0, chroma, x)
        case 3..<4: (red, green, blue) = (0, x, chroma)
        case 4..<5: (red, green, blue) = (x, 0, chroma)
        default: (red, green, blue) = (chroma, 0, x)
        }
        return (clamp(red + match), clamp(green + match), clamp(blue + match))
    }

    private static func components(_ value: Any?, count: Int) -> [Double]? {
        guard let list = value as? [Any], list.count >= count else { return nil }
        let numbers = list.prefix(count).compactMap(double)
        guard numbers.count == count else { return nil }
        return numbers
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }
}
