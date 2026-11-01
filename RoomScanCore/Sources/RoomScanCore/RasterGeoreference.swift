import Foundation

/// Scale, rotation, and an optional geographic position for an aerial raster.
public struct RasterPlacement: Equatable, Sendable {
    public var widthMeters: Double
    public var heightMeters: Double
    @Quantized public var yaw: Double
    public var georeference: Georeference?
    /// EPSG code when the file named one. 3006 is SWEREF 99 TM, used by Lantmäteriet ortofoto.
    public var epsg: Int?
    public var metersPerPixel: Double
    /// What was assumed, so the site plan can say so.
    public var summary: String

    public init(
        widthMeters: Double,
        heightMeters: Double,
        yaw: Double,
        georeference: Georeference?,
        epsg: Int?,
        metersPerPixel: Double,
        summary: String
    ) {
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.yaw = yaw
        self.georeference = georeference
        self.epsg = epsg
        self.metersPerPixel = metersPerPixel
        self.summary = summary
    }
}

public enum RasterGeoreference {
    /// Reads GeoTIFF geokeys and the pixel scale. Does not decode the bitmap.
    /// Returns nil when the file is not a classic TIFF or has no model scale.
    public static func geotiff(data: Data, pixelWidth: Int, pixelHeight: Int) -> RasterPlacement? {
        guard let header = TIFFDirectory.classicHeader(data),
              let directory = TIFFDirectory.read(data: data, ifdOffset: header.firstIFD, endian: header.endian, base: 0)
        else { return nil }
        let width = directory.int(256) ?? pixelWidth
        let height = directory.int(257) ?? pixelHeight
        guard width > 0, height > 0 else { return nil }
        let keys = geoKeys(directory)
        let rasterIsPoint = keys[1025] == 2
        let epsg = keys[3072] ?? keys[2048]
        let modelType = keys[1024]

        let affine: Affine
        let scale = directory.doubles(33550)
        let tie = directory.doubles(33922)
        if scale.count >= 2, tie.count >= 6 {
            let tieColumn = tie[0]
            let tieRow = tie[1]
            let originX = tie[3]
            let originY = tie[4]
            // ModelPixelScale Y is positive; image rows run south, so north decreases.
            affine = Affine(
                columnX: scale[0],
                columnY: 0,
                rowX: 0,
                rowY: -scale[1],
                originX: originX - tieColumn * scale[0],
                originY: originY + tieRow * scale[1]
            )
        } else {
            let matrix = directory.doubles(34264)
            guard matrix.count >= 16 else { return nil }
            affine = Affine(
                columnX: matrix[0],
                columnY: matrix[4],
                rowX: matrix[1],
                rowY: matrix[5],
                originX: matrix[3],
                originY: matrix[7]
            )
        }
        let registration: Registration = rasterIsPoint ? .pixelCenter : .pixelCorner
        return placement(
            affine: affine,
            pixelWidth: width,
            pixelHeight: height,
            registration: registration,
            epsg: epsg,
            modelIsGeographic: modelType == 2 || epsg == 4326,
            source: "GeoTIFF"
        )
    }

    /// A six-line world file: column size, rotation, rotation, row size, origin X, origin Y.
    /// The origin is the center of the upper-left pixel. A step smaller than 0.01 is treated as degrees.
    public static func worldFile(_ text: String, pixelWidth: Int, pixelHeight: Int) -> RasterPlacement? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 6,
              let a = Double(lines[0].replacingOccurrences(of: ",", with: ".")),
              let d = Double(lines[1].replacingOccurrences(of: ",", with: ".")),
              let b = Double(lines[2].replacingOccurrences(of: ",", with: ".")),
              let e = Double(lines[3].replacingOccurrences(of: ",", with: ".")),
              let c = Double(lines[4].replacingOccurrences(of: ",", with: ".")),
              let f = Double(lines[5].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let geographic = abs(a) < 0.01 && abs(e) < 0.01 && abs(b) < 0.01 && abs(d) < 0.01
        // World-file origin is the center of pixel (0, 0). Shift to the upper-left corner
        // so the shared placement math can treat it like a pixel-corner affine.
        let affine = Affine(
            columnX: a,
            columnY: d,
            rowX: b,
            rowY: e,
            originX: c - a / 2 - b / 2,
            originY: f - d / 2 - e / 2
        )
        return placement(
            affine: affine,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            registration: .pixelCorner,
            epsg: geographic ? 4326 : nil,
            modelIsGeographic: geographic,
            source: geographic ? "World file (degrees)" : "World file (projected meters, CRS not named)"
        )
    }

    private struct Affine {
        var columnX: Double
        var columnY: Double
        var rowX: Double
        var rowY: Double
        var originX: Double
        var originY: Double
    }

    private enum Registration {
        case pixelCorner
        case pixelCenter
    }

    private static func placement(
        affine: Affine,
        pixelWidth: Int,
        pixelHeight: Int,
        registration: Registration,
        epsg: Int?,
        modelIsGeographic: Bool,
        source: String
    ) -> RasterPlacement? {
        let columnLength = hypot(affine.columnX, affine.columnY)
        let rowLength = hypot(affine.rowX, affine.rowY)
        guard columnLength > 0, rowLength > 0, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let centerColumn = Double(pixelWidth) / 2
        let centerRow = Double(pixelHeight) / 2
        let shift = registration == .pixelCenter ? 0.5 : 0
        let centerX = affine.originX + (centerColumn - shift) * affine.columnX + (centerRow - shift) * affine.rowX
        let centerY = affine.originY + (centerColumn - shift) * affine.columnY + (centerRow - shift) * affine.rowY
        // Image +X follows the column step. Site +X is east and site +Z is north, so yaw is that bearing.
        let yaw = Trig.atan2(affine.columnY, affine.columnX)
        let shear = abs(affine.columnX * affine.rowX + affine.columnY * affine.rowY) / (columnLength * rowLength)
        var summary = source
        if shear > 0.02 {
            summary += ". Shear was dropped; the photo is placed with scale and rotation only."
        }

        if modelIsGeographic {
            let latitude = centerY
            let longitude = centerX
            guard abs(latitude) <= 90, abs(longitude) <= 180 else { return nil }
            let meters = SiteGeodesy.metersPerDegree(latitude: latitude)
            let width = columnLength * Double(pixelWidth) * meters.lon
            let height = rowLength * Double(pixelHeight) * meters.lat
            summary += ". Geographic coordinates were converted at this latitude."
            return RasterPlacement(
                widthMeters: width,
                heightMeters: height,
                yaw: yaw,
                georeference: Georeference(latitude: latitude, longitude: longitude, headingDegrees: 0),
                epsg: epsg ?? 4326,
                metersPerPixel: width / Double(pixelWidth),
                summary: summary
            )
        }

        let width = columnLength * Double(pixelWidth)
        let height = rowLength * Double(pixelHeight)
        var georeference: Georeference?
        if epsg == 3006 {
            let geographic = SWEREF99TM.toGeographic(easting: centerX, northing: centerY)
            georeference = Georeference(latitude: geographic.latitude, longitude: geographic.longitude, headingDegrees: 0)
            summary += ". SWEREF 99 TM (EPSG:3006) converted to latitude and longitude. Site +X is east and site +Z is north."
        } else if epsg == nil {
            summary += ". Latitude was not set, because the file does not name a coordinate system."
        } else {
            summary += ". EPSG:\(epsg ?? 0) is not converted. Set latitude and longitude yourself. Width is in the file's linear units, treated as meters."
        }
        return RasterPlacement(
            widthMeters: width,
            heightMeters: height,
            yaw: yaw,
            georeference: georeference,
            epsg: epsg,
            metersPerPixel: width / Double(pixelWidth),
            summary: summary
        )
    }

    /// GeoKeyDirectory values that are stored inline (TIFFTagLocation 0).
    private static func geoKeys(_ directory: TIFFDirectory) -> [Int: Int] {
        let shorts = directory.field(34735)?.integers ?? []
        guard shorts.count >= 4 else { return [:] }
        let keyCount = shorts[3]
        var values: [Int: Int] = [:]
        var index = 4
        while index + 3 < shorts.count, values.count < keyCount {
            let key = shorts[index]
            let location = shorts[index + 1]
            let value = shorts[index + 3]
            if location == 0 {
                values[key] = value
            }
            index += 4
        }
        return values
    }
}

public enum SWEREF99TM {
    private static let a = 6_378_137.0
    private static let f = 1 / 298.257222101
    private static let k0 = 0.9996
    private static let lon0 = 15.0 * Double.pi / 180
    private static let falseEasting = 500_000.0

    public static func toGeographic(easting: Double, northing: Double) -> (latitude: Double, longitude: Double) {
        let e2 = f * (2 - f)
        let e4 = e2 * e2
        let e6 = e4 * e2
        let ep2 = e2 / (1 - e2)
        let x = easting - falseEasting
        let y = northing
        let meridian = a * (1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256)
        let mu = y / (k0 * meridian)
        let root = (1 - (1 - e2).squareRoot()) / (1 + (1 - e2).squareRoot())
        let phi1 = mu
            + (3 * root / 2 - 27 * root * root * root / 32) * Trig.sin(2 * mu)
            + (21 * root * root / 16 - 55 * root * root * root * root / 32) * Trig.sin(4 * mu)
            + (151 * root * root * root / 96) * Trig.sin(6 * mu)
            + (1097 * root * root * root * root / 512) * Trig.sin(8 * mu)
        let sinPhi = Trig.sin(phi1)
        let cosPhi = Trig.cos(phi1)
        let tanPhi = sinPhi / cosPhi
        let c1 = ep2 * cosPhi * cosPhi
        let t1 = tanPhi * tanPhi
        let n1 = a / (1 - e2 * sinPhi * sinPhi).squareRoot()
        let r1 = a * (1 - e2) / pow3(1 - e2 * sinPhi * sinPhi)
        let d = x / (n1 * k0)
        let d2 = d * d
        let latitude = phi1 - (n1 * tanPhi / r1) * (
            d2 / 2
                - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * ep2) * d2 * d2 / 24
                + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * ep2 - 3 * c1 * c1) * d2 * d2 * d2 / 720
        )
        let longitude = lon0 + (
            d
                - (1 + 2 * t1 + c1) * d2 * d / 6
                + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * ep2 + 24 * t1 * t1) * d2 * d2 * d / 120
        ) / cosPhi
        return (latitude * 180 / Double.pi, longitude * 180 / Double.pi)
    }

    public static func toGrid(latitude: Double, longitude: Double) -> (easting: Double, northing: Double) {
        let e2 = f * (2 - f)
        let e4 = e2 * e2
        let e6 = e4 * e2
        let ep2 = e2 / (1 - e2)
        let lat = latitude * Double.pi / 180
        let lon = longitude * Double.pi / 180
        let sinLat = Trig.sin(lat)
        let cosLat = Trig.cos(lat)
        let tanLat = sinLat / cosLat
        let n = a / (1 - e2 * sinLat * sinLat).squareRoot()
        let t = tanLat * tanLat
        let c = ep2 * cosLat * cosLat
        let aa = (lon - lon0) * cosLat
        let m = a * (
            (1 - e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * lat
                - (3 * e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * Trig.sin(2 * lat)
                + (15 * e4 / 256 + 45 * e6 / 1024) * Trig.sin(4 * lat)
                - (35 * e6 / 3072) * Trig.sin(6 * lat)
        )
        let aa2 = aa * aa
        let easting = falseEasting + k0 * n * (
            aa
                + (1 - t + c) * aa2 * aa / 6
                + (5 - 18 * t + t * t + 72 * c - 58 * ep2) * aa2 * aa2 * aa / 120
        )
        let northing = k0 * (
            m + n * tanLat * (
                aa2 / 2
                    + (5 - t + 9 * c + 4 * c * c) * aa2 * aa2 / 24
                    + (61 - 58 * t + t * t + 600 * c - 330 * ep2) * aa2 * aa2 * aa2 / 720
            )
        )
        return (easting, northing)
    }

    private static func pow3(_ value: Double) -> Double {
        let root = value.squareRoot()
        return root * root * root
    }
}

public enum UncompressedTIFF {
    /// RGBA8, top row first. Only compression 1 (none), chunky strips, 8-bit gray or RGB.
    /// Tiled, JPEG, LZW, and deflate TIFFs return nil; ImageIO on device may still open those.
    public static func decode(_ data: Data) -> DecodedRaster? {
        guard let header = TIFFDirectory.classicHeader(data),
              let directory = TIFFDirectory.read(data: data, ifdOffset: header.firstIFD, endian: header.endian, base: 0)
        else { return nil }
        guard let width = directory.int(256), let height = directory.int(257), width > 0, height > 0 else { return nil }
        guard width <= 20_000, height <= 20_000 else { return nil }
        if directory.int(322) != nil { return nil }
        let compression = directory.int(259) ?? 1
        guard compression == 1 else { return nil }
        let photometric = directory.int(262) ?? -1
        guard photometric == 1 || photometric == 2 else { return nil }
        let samples = directory.int(277) ?? (photometric == 2 ? 3 : 1)
        guard samples == 1 || samples == 3 || samples == 4 else { return nil }
        let bits = directory.field(258)?.integers ?? [8]
        guard bits.allSatisfy({ $0 == 8 }) else { return nil }
        let planar = directory.int(284) ?? 1
        guard planar == 1 else { return nil }
        guard let stripField = directory.field(273), let countField = directory.field(279) else { return nil }
        let rowsPerStrip = directory.int(278) ?? height
        guard rowsPerStrip > 0 else { return nil }
        let offsets = stripField.integers
        let counts = countField.integers
        guard offsets.count == counts.count, !offsets.isEmpty else { return nil }
        var rgba = Data(count: width * height * 4)
        var row = 0
        for (strip, offset) in offsets.enumerated() {
            let byteCount = counts[strip]
            guard offset >= 0, byteCount >= 0, offset + byteCount <= data.count else { return nil }
            let stripRows = min(rowsPerStrip, height - row)
            let expected = stripRows * width * samples
            guard byteCount >= expected else { return nil }
            for y in 0..<stripRows {
                for x in 0..<width {
                    let source = offset + (y * width + x) * samples
                    let destination = ((row + y) * width + x) * 4
                    let red: UInt8
                    let green: UInt8
                    let blue: UInt8
                    if samples == 1 {
                        red = data[source]
                        green = red
                        blue = red
                    } else {
                        red = data[source]
                        green = data[source + 1]
                        blue = data[source + 2]
                    }
                    rgba[destination] = red
                    rgba[destination + 1] = green
                    rgba[destination + 2] = blue
                    rgba[destination + 3] = 255
                }
            }
            row += stripRows
        }
        guard row == height else { return nil }
        return DecodedRaster(width: width, height: height, rgba: rgba)
    }
}

public struct DecodedRaster: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgba: Data

    public init(width: Int, height: Int, rgba: Data) {
        self.width = width
        self.height = height
        self.rgba = rgba
    }
}
