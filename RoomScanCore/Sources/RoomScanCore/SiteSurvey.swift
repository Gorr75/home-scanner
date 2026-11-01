import Foundation

public enum SiteGeodesy {
    /// Meters per degree of latitude and longitude at `latitude`.
    public static func metersPerDegree(latitude: Double) -> (lat: Double, lon: Double) {
        let radians = latitude * Double.pi / 180
        let cosine = Trig.cos(radians)
        return (111_132.92, max(111_320 * cosine, 1))
    }

    /// East and north meters from `origin` to the other geographic point.
    /// Site +X is east and site +Z is north. Accurate across a house lot, not across a country.
    public static func offset(from origin: Georeference, latitude: Double, longitude: Double) -> (east: Double, north: Double) {
        let meters = metersPerDegree(latitude: origin.latitude)
        let east = (longitude - origin.longitude) * meters.lon
        let north = (latitude - origin.latitude) * meters.lat
        return (east, north)
    }

    /// Where a GPS photo sits on the current site. Latitude is the source of truth when both photos name a place.
    public static func overlayPosition(_ overlay: DroneOverlay, underlay: SiteUnderlay?) -> Vec3 {
        if let origin = underlay?.georeference, let photo = overlay.georeference {
            let delta = offset(from: origin, latitude: photo.latitude, longitude: photo.longitude)
            let center = underlay?.center ?? .zero
            return Vec3(x: center.x + delta.east, y: overlay.center.y, z: center.z + delta.north)
        }
        return overlay.center
    }
}

public enum SiteSurvey {
    public struct ScaleMeasurement: Equatable, Sendable {
        public var metersPerPixel: Double
        public var widthMeters: Double
        public var heightMeters: Double

        public init(metersPerPixel: Double, widthMeters: Double, heightMeters: Double) {
            self.metersPerPixel = metersPerPixel
            self.widthMeters = widthMeters
            self.heightMeters = heightMeters
        }
    }

    /// Two pixels and the ground distance between them. Aspect is unchanged.
    public static func scale(
        pixelA: (x: Double, y: Double),
        pixelB: (x: Double, y: Double),
        pixelWidth: Int,
        pixelHeight: Int,
        distanceMeters: Double
    ) -> ScaleMeasurement? {
        let span = hypot(pixelB.x - pixelA.x, pixelB.y - pixelA.y)
        guard span >= 1, distanceMeters > 0, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let metersPerPixel = distanceMeters / span
        return ScaleMeasurement(
            metersPerPixel: metersPerPixel,
            widthMeters: metersPerPixel * Double(pixelWidth),
            heightMeters: metersPerPixel * Double(pixelHeight)
        )
    }

    /// Image coordinate of a site point. Pixel y grows downward. The result may lie outside the bitmap.
    public static func underlayPixel(world: Vec3, underlay: SiteUnderlay) -> (x: Double, y: Double)? {
        guard underlay.widthMeters > 0, underlay.heightMeters > 0, underlay.pixelWidth > 0, underlay.pixelHeight > 0 else {
            return nil
        }
        let dx = world.x - underlay.center.x
        let dz = world.z - underlay.center.z
        let cosine = Trig.cos(underlay.yaw)
        let sine = Trig.sin(underlay.yaw)
        let localX = dx * cosine + dz * sine
        let localZ = -dx * sine + dz * cosine
        let column = (localX / underlay.widthMeters + 0.5) * Double(underlay.pixelWidth)
        let row = (0.5 - localZ / underlay.heightMeters) * Double(underlay.pixelHeight)
        return (column, row)
    }

    /// Places an underlay so two pixels land on two site points. Scale, yaw, and center all change.
    public static func alignUnderlay(
        pixelA: (x: Double, y: Double),
        pixelB: (x: Double, y: Double),
        siteA: Vec3,
        siteB: Vec3,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> (center: Vec3, yaw: Double, widthMeters: Double, heightMeters: Double)? {
        guard pixelWidth > 1, pixelHeight > 1 else { return nil }
        let a = pixelOffset(pixelA, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let b = pixelOffset(pixelB, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let local = Vec3(x: b.x - a.x, y: 0, z: b.z - a.z)
        let site = Vec3(x: siteB.x - siteA.x, y: 0, z: siteB.z - siteA.z)
        guard local.horizontalLength >= 1, site.horizontalLength > 0 else { return nil }
        let metersPerPixel = site.horizontalLength / local.horizontalLength
        let yaw = wrap(Trig.atan2(site.z, site.x) - Trig.atan2(local.z, local.x))
        let rotated = rotate(Vec3(x: a.x * metersPerPixel, y: 0, z: a.z * metersPerPixel), yaw: yaw)
        let center = Vec3(x: siteA.x - rotated.x, y: 0, z: siteA.z - rotated.z)
        return (
            center,
            yaw,
            metersPerPixel * Double(pixelWidth),
            metersPerPixel * Double(pixelHeight)
        )
    }

    /// Rigid placement. The room or zone keeps its measured size; the taps set position and rotation.
    public static func placementMatching(
        subject: SiteSubject,
        localA: Vec3,
        localB: Vec3,
        siteA: Vec3,
        siteB: Vec3
    ) -> SitePlacement? {
        let local = Vec3(x: localB.x - localA.x, y: 0, z: localB.z - localA.z)
        let site = Vec3(x: siteB.x - siteA.x, y: 0, z: siteB.z - siteA.z)
        guard local.horizontalLength > 0.05, site.horizontalLength > 0.05 else { return nil }
        let yaw = wrap(Trig.atan2(site.z, site.x) - Trig.atan2(local.z, local.x))
        let rotated = rotate(localA, yaw: yaw)
        let origin = Vec3(x: siteA.x - rotated.x, y: 0, z: siteA.z - rotated.z)
        return SitePlacement(subject: subject, origin: origin, yaw: yaw)
    }

    public static func longestWall(in plan: FloorPlan) -> WallSegment? {
        plan.walls.max { $0.length < $1.length }
    }

    public static func longestWall(in zone: OutdoorZone) -> WallSegment? {
        zone.walls.max { $0.length < $1.length }
    }

    /// Pixel offset from the image center. +x is right, +z is up (toward the top row).
    private static func pixelOffset(
        _ pixel: (x: Double, y: Double),
        pixelWidth: Int,
        pixelHeight: Int
    ) -> (x: Double, z: Double) {
        (
            pixel.x - Double(pixelWidth) / 2,
            Double(pixelHeight) / 2 - pixel.y
        )
    }

    private static func rotate(_ point: Vec3, yaw: Double) -> Vec3 {
        let cosine = Trig.cos(yaw)
        let sine = Trig.sin(yaw)
        return Vec3(
            x: point.x * cosine - point.z * sine,
            y: point.y,
            z: point.x * sine + point.z * cosine
        )
    }

    private static func wrap(_ angle: Double) -> Double {
        var value = angle
        while value > Double.pi { value -= 2 * Double.pi }
        while value < -Double.pi { value += 2 * Double.pi }
        return value
    }
}

/// Maps the unit square of a wall onto a photo. `s` runs from start to end, `t` runs from the base upward.
public struct PlaneHomography: Equatable, Sendable {
    public var h: [Double]

    public init(h: [Double]) {
        self.h = h
    }

    public func imagePoint(s: Double, t: Double) -> UVPoint? {
        guard h.count == 9 else { return nil }
        let weight = h[6] * s + h[7] * t + h[8]
        guard abs(weight) > 1e-10 else { return nil }
        return UVPoint(
            u: (h[0] * s + h[1] * t + h[2]) / weight,
            v: (h[3] * s + h[4] * t + h[5]) / weight
        )
    }

    /// `corners` follow `SurfaceTexture`: bottom-start, bottom-end, top-end, top-start.
    public static func wallToImage(corners: [UVPoint]) -> PlaneHomography? {
        guard corners.count == 4 else { return nil }
        let sources = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]
        var matrix = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
        var rhs = Array(repeating: 0.0, count: 8)
        for index in 0..<4 {
            let s = sources[index].0
            let t = sources[index].1
            let u = corners[index].u
            let v = corners[index].v
            let row = index * 2
            matrix[row] = [s, t, 1, 0, 0, 0, -u * s, -u * t]
            rhs[row] = u
            matrix[row + 1] = [0, 0, 0, s, t, 1, -v * s, -v * t]
            rhs[row + 1] = v
        }
        guard let solved = solve(matrix, rhs) else { return nil }
        return PlaneHomography(h: solved + [1])
    }

    private static func solve(_ original: [[Double]], _ originalRHS: [Double]) -> [Double]? {
        let n = originalRHS.count
        guard original.count == n, original.allSatisfy({ $0.count == n }) else { return nil }
        var matrix = original
        var rhs = originalRHS
        for column in 0..<n {
            var pivot = column
            var best = abs(matrix[column][column])
            if column + 1 < n {
                for row in (column + 1)..<n where abs(matrix[row][column]) > best {
                    best = abs(matrix[row][column])
                    pivot = row
                }
            }
            if best < 1e-12 { return nil }
            if pivot != column {
                matrix.swapAt(pivot, column)
                rhs.swapAt(pivot, column)
            }
            let divisor = matrix[column][column]
            for row in (column + 1)..<n {
                let factor = matrix[row][column] / divisor
                if factor == 0 { continue }
                for k in column..<n {
                    matrix[row][k] -= factor * matrix[column][k]
                }
                rhs[row] -= factor * rhs[column]
            }
        }
        var solution = Array(repeating: 0.0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = rhs[row]
            if row + 1 < n {
                for column in (row + 1)..<n {
                    sum -= matrix[row][column] * solution[column]
                }
            }
            if abs(matrix[row][row]) < 1e-12 { return nil }
            solution[row] = sum / matrix[row][row]
        }
        return solution
    }
}

public struct CameraPose: Equatable, Sendable {
    public var position: Vec3
    /// Clockwise degrees from true north. 0 looks toward site +Z.
    public var headingDegrees: Double
    /// 0 is the horizon. Negative looks down.
    public var pitchDegrees: Double
    public var focalLength35mm: Double?
    public var focalLengthMillimeters: Double?
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(
        position: Vec3,
        headingDegrees: Double,
        pitchDegrees: Double,
        focalLength35mm: Double?,
        focalLengthMillimeters: Double?,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.position = position
        self.headingDegrees = headingDegrees
        self.pitchDegrees = pitchDegrees
        self.focalLength35mm = focalLength35mm
        self.focalLengthMillimeters = focalLengthMillimeters
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public struct CornerSuggestion: Equatable, Sendable {
    public var corners: [UVPoint]
    /// False when only a physical focal length was available and a 6.3 mm sensor width was assumed.
    public var usedEquivalentFocalLength: Bool

    public init(corners: [UVPoint], usedEquivalentFocalLength: Bool) {
        self.corners = corners
        self.usedEquivalentFocalLength = usedEquivalentFocalLength
    }
}

public enum FacadeProjection {
    /// Projects the wall's four corners into the photo. Nil when the wall is behind the camera,
    /// the focal length is missing, or every corner falls well outside the frame.
    public static func suggestCorners(
        wall: WallSegment,
        placement: SitePlacement,
        camera: CameraPose
    ) -> CornerSuggestion? {
        let focal: (millimeters35: Double, usedEquivalent: Bool)
        if let equivalent = camera.focalLength35mm, equivalent > 1 {
            focal = (equivalent, true)
        } else if let physical = camera.focalLengthMillimeters, physical > 0.1 {
            // A small-drone sensor is often about 6.3 mm wide. This is a guess, not a calibration.
            focal = (physical * 36 / 6.3, false)
        } else {
            return nil
        }
        guard camera.pixelWidth > 0, camera.pixelHeight > 0 else { return nil }
        let heading = camera.headingDegrees * Double.pi / 180
        let pitch = camera.pitchDegrees * Double.pi / 180
        let forward = Vec3(
            x: Trig.sin(heading) * Trig.cos(pitch),
            y: Trig.sin(pitch),
            z: Trig.cos(heading) * Trig.cos(pitch)
        )
        let right = Vec3(x: Trig.cos(heading), y: 0, z: -Trig.sin(heading))
        let up = cross(forward, right)
        let world = quad(wall).map { SiteLayout.apply($0, placement: placement) }
        var corners: [UVPoint] = []
        for point in world {
            let delta = point - camera.position
            let x = delta.dot(right)
            let y = delta.dot(up)
            let z = delta.dot(forward)
            guard z > 0.05 else { return nil }
            let filmX = focal.millimeters35 * x / z
            let filmY = focal.millimeters35 * y / z
            corners.append(UVPoint(u: 0.5 + filmX / 36, v: 0.5 - filmY / 24))
        }
        let visible = corners.contains { corner in
            corner.u > -0.25 && corner.u < 1.25 && corner.v > -0.25 && corner.v < 1.25
        }
        guard visible else { return nil }
        return CornerSuggestion(corners: corners, usedEquivalentFocalLength: focal.usedEquivalent)
    }

    public static func quad(_ wall: WallSegment) -> [Vec3] {
        let rise = Vec3(x: 0, y: wall.height, z: 0)
        return [wall.start, wall.end, wall.end + rise, wall.start + rise]
    }

    private static func cross(_ a: Vec3, _ b: Vec3) -> Vec3 {
        Vec3(
            x: a.y * b.z - a.z * b.y,
            y: a.z * b.x - a.x * b.z,
            z: a.x * b.y - a.y * b.x
        )
    }
}
