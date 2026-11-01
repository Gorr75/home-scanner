import Foundation

/// GPS and camera fields read from a JPEG's EXIF and, when present, DJI-style XMP.
public struct PhotoMetadata: Equatable, Sendable {
    public var latitude: Double?
    public var longitude: Double?
    public var altitudeMeters: Double?
    /// GPSImgDirection, clockwise from north. Magnetic and true are not distinguished.
    public var headingDegrees: Double?
    /// Gimbal pitch when the file carries it. 0 is the horizon, negative looks down.
    public var pitchDegrees: Double?
    public var relativeAltitudeMeters: Double?
    public var focalLengthMillimeters: Double?
    public var focalLength35mm: Double?
    /// Gimbal yaw, preferred over the GPS direction for a hovering drone.
    public var gimbalYawDegrees: Double?

    public init(
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitudeMeters: Double? = nil,
        headingDegrees: Double? = nil,
        pitchDegrees: Double? = nil,
        relativeAltitudeMeters: Double? = nil,
        focalLengthMillimeters: Double? = nil,
        focalLength35mm: Double? = nil,
        gimbalYawDegrees: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeMeters = altitudeMeters
        self.headingDegrees = headingDegrees
        self.pitchDegrees = pitchDegrees
        self.relativeAltitudeMeters = relativeAltitudeMeters
        self.focalLengthMillimeters = focalLengthMillimeters
        self.focalLength35mm = focalLength35mm
        self.gimbalYawDegrees = gimbalYawDegrees
    }

    public var hasLocation: Bool {
        if let latitude, let longitude {
            return abs(latitude) <= 90 && abs(longitude) <= 180
        }
        return false
    }

    public var cameraHeading: Double? {
        gimbalYawDegrees ?? headingDegrees
    }
}

public enum PhotoEXIF {
    public static func read(_ data: Data) -> PhotoMetadata {
        var metadata = PhotoMetadata()
        if let exif = exifTIFF(data) {
            metadata = exif
        }
        if let pitch = firstNumber(in: data, keys: ["GimbalPitchDegree"]) {
            metadata.pitchDegrees = pitch
        }
        if let yaw = firstNumber(in: data, keys: ["GimbalYawDegree", "FlightYawDegree"]) {
            metadata.gimbalYawDegrees = yaw
        }
        if let relative = firstNumber(in: data, keys: ["RelativeAltitude"]) {
            metadata.relativeAltitudeMeters = relative
        }
        return metadata
    }

    private static func exifTIFF(_ data: Data) -> PhotoMetadata? {
        guard data.count > 4, data[0] == 0xFF, data[1] == 0xD8 else { return nil }
        var cursor = 2
        while cursor + 4 < data.count {
            if data[cursor] != 0xFF {
                cursor += 1
                continue
            }
            while cursor < data.count, data[cursor] == 0xFF { cursor += 1 }
            guard cursor < data.count else { break }
            let marker = data[cursor]
            cursor += 1
            if marker == 0xD9 || marker == 0xDA { break }
            if marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7) { continue }
            guard cursor + 2 <= data.count else { break }
            let length = Int(TIFFDirectory.readU16(data, cursor, .big))
            guard length >= 2, cursor + length <= data.count else { break }
            if marker == 0xE1 {
                let payload = cursor + 2
                let header = Data("Exif\0\0".utf8)
                if payload + header.count + 8 <= data.count, data[payload..<(payload + header.count)].elementsEqual(header) {
                    let tiff = payload + header.count
                    if let parsed = parseTIFF(data, tiffBase: tiff) {
                        return parsed
                    }
                }
            }
            cursor += length
        }
        return nil
    }

    private static func parseTIFF(_ data: Data, tiffBase: Int) -> PhotoMetadata? {
        let slice = data.suffix(from: tiffBase)
        guard let header = TIFFDirectory.classicHeader(Data(slice)) else { return nil }
        let first = tiffBase + header.firstIFD
        guard let root = TIFFDirectory.read(data: data, ifdOffset: first, endian: header.endian, base: tiffBase) else {
            return nil
        }
        var metadata = PhotoMetadata()
        if let gpsOffset = root.int(0x8825) {
            let gps = TIFFDirectory.read(data: data, ifdOffset: tiffBase + gpsOffset, endian: header.endian, base: tiffBase)
            if let gps {
                let lat = coordinate(gps, valueTag: 2, refTag: 1, negative: "S")
                let lon = coordinate(gps, valueTag: 4, refTag: 3, negative: "W")
                metadata.latitude = lat
                metadata.longitude = lon
                if let altitude = gps.doubles(6).first {
                    let below = gps.int(5) == 1
                    metadata.altitudeMeters = below ? -altitude : altitude
                }
                if let direction = gps.doubles(17).first {
                    metadata.headingDegrees = direction
                }
            }
        }
        if let exifOffset = root.int(0x8769),
           let exif = TIFFDirectory.read(data: data, ifdOffset: tiffBase + exifOffset, endian: header.endian, base: tiffBase) {
            metadata.focalLengthMillimeters = exif.doubles(0x920A).first
            if let equivalent = exif.int(0xA405) {
                metadata.focalLength35mm = Double(equivalent)
            }
        }
        return metadata
    }

    private static func coordinate(_ directory: TIFFDirectory, valueTag: Int, refTag: Int, negative: String) -> Double? {
        let parts = directory.doubles(valueTag)
        guard parts.count >= 3 else { return nil }
        let value = parts[0] + parts[1] / 60 + parts[2] / 3600
        let ref = directory.field(refTag)?.ascii ?? ""
        if ref.uppercased().hasPrefix(negative) { return -value }
        return value
    }

    private static func firstNumber(in data: Data, keys: [String]) -> Double? {
        for key in keys {
            guard let range = data.range(of: Data(key.utf8)) else { continue }
            var index = range.upperBound
            while index < data.count, data[index] == 0x20 || data[index] == 0x3D || data[index] == 0x22 || data[index] == 0x27 || data[index] == 0x3E {
                index += 1
            }
            let start = index
            if index < data.count, data[index] == 0x2B || data[index] == 0x2D { index += 1 }
            var sawDigit = false
            while index < data.count {
                let byte = data[index]
                if byte >= 0x30 && byte <= 0x39 { sawDigit = true; index += 1; continue }
                if byte == 0x2E { index += 1; continue }
                break
            }
            guard sawDigit, let text = String(data: data[start..<index], encoding: .utf8), let value = Double(text) else {
                continue
            }
            return value
        }
        return nil
    }
}
