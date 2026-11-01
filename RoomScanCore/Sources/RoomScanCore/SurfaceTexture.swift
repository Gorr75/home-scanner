import Foundation

/// A point in a texture image. `u` grows to the right and `v` grows downward, both in 0...1.
public struct UVPoint: Codable, Equatable, Hashable, Sendable {
    public var u: Double
    public var v: Double

    public init(u: Double, v: Double) {
        self.u = u
        self.v = v
    }
}

/// A photo stretched onto one wall by its four corners.
///
/// Indoor room walls (`floor_plan.walls`) and outdoor facade walls (`outdoor_zones.walls`)
/// store this same object. Corner order is the wall quad, seen from outside the wall's
/// start-to-end direction:
///
/// 1. bottom at `start`
/// 2. bottom at `end`
/// 3. top at `end`
/// 4. top at `start`
///
/// The four points are a perspective correspondence, not a pair of affine triangles.
public struct SurfaceTexture: Codable, Equatable, Sendable {
    /// Path relative to the home folder.
    public var image: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var corners: [UVPoint]

    public init(image: String, pixelWidth: Int, pixelHeight: Int, corners: [UVPoint]) {
        self.image = image
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.corners = corners
    }

    public var isUsable: Bool {
        corners.count == 4 && pixelWidth > 0 && pixelHeight > 0 && RelativePath.isSafe(image)
    }

    /// The whole image, with the photo's bottom edge along the base of the wall.
    public static func fullImage(path: String, pixelWidth: Int, pixelHeight: Int) -> SurfaceTexture {
        SurfaceTexture(
            image: path,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            corners: [
                UVPoint(u: 0, v: 1),
                UVPoint(u: 1, v: 1),
                UVPoint(u: 1, v: 0),
                UVPoint(u: 0, v: 0)
            ]
        )
    }
}
