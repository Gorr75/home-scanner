import Foundation

public enum EntityIDCheck: Equatable, Sendable {
    /// Empty or whitespace. The pin is not linked.
    case unset
    case valid(String)
    case invalid
}

public enum EntityIDRules {
    /// Home Assistant ids look like `light.kitchen` or `binary_sensor.front_door`.
    public static func check(_ raw: String) -> EntityIDCheck {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return .unset }
        guard isCanonical(value) else { return .invalid }
        return .valid(value)
    }

    public static func isValid(_ raw: String) -> Bool {
        if case .valid = check(raw) { return true }
        return false
    }

    private static func isCanonical(_ canonical: String) -> Bool {
        guard let dot = canonical.firstIndex(of: ".") else { return false }
        let domain = canonical[..<dot]
        let object = canonical[canonical.index(after: dot)...]
        guard !domain.isEmpty, !object.isEmpty, !object.contains(".") else { return false }
        return isToken(domain) && isToken(object)
    }

    private static func isToken(_ value: Substring) -> Bool {
        guard let first = value.first, isLeading(first) else { return false }
        return value.allSatisfy { isLeading($0) || ($0.isNumber && $0.isASCII) }
    }

    private static func isLeading(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character == "_" || (character.isLetter && character.isLowercase)
    }
}
