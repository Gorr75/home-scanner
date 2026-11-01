import UIKit
import RoomScanCore

enum PhotoIngest {
    struct Prepared {
        var data: Data
        var fileExtension: String
        var pixelWidth: Int
        var pixelHeight: Int
        var metadata: PhotoMetadata
        var placement: RasterPlacement?
    }

    enum Failure: LocalizedError {
        case unreadable
        case geotiffWithoutBitmap(String)

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "That file could not be read as an image."
            case .geotiffWithoutBitmap(let summary):
                return "The GeoTIFF georeference was read (\(summary)), but iOS could not decode the pixels. Lantmäteriet tiles are often JPEG or deflate compressed. Export a JPEG or PNG plus a .tfw world file and import those."
            }
        }
    }

    static func prepare(_ data: Data, maxPixel: CGFloat) -> Result<Prepared, Failure> {
        let metadata = PhotoEXIF.read(data)
        guard let image = image(from: data) else {
            if let placement = RasterGeoreference.geotiff(data: data, pixelWidth: 1, pixelHeight: 1) {
                return .failure(.geotiffWithoutBitmap(placement.summary))
            }
            return .failure(.unreadable)
        }
        let sourceWidth = max(Int(image.size.width * image.scale), 1)
        let sourceHeight = max(Int(image.size.height * image.scale), 1)
        let placement = RasterGeoreference.geotiff(data: data, pixelWidth: sourceWidth, pixelHeight: sourceHeight)
        guard let rendered = jpeg(image, maxPixel: maxPixel) else {
            return .failure(.unreadable)
        }
        return .success(Prepared(
            data: rendered.data,
            fileExtension: "jpg",
            pixelWidth: rendered.width,
            pixelHeight: rendered.height,
            metadata: metadata,
            placement: placement
        ))
    }

    static func image(from data: Data) -> UIImage? {
        if let image = UIImage(data: data) {
            return image
        }
        guard let raster = UncompressedTIFF.decode(data) else { return nil }
        return image(from: raster)
    }

    static func image(from raster: DecodedRaster) -> UIImage? {
        let width = raster.width
        let height = raster.height
        guard width > 0, height > 0, raster.rgba.count >= width * height * 4 else { return nil }
        let provider = CGDataProvider(data: raster.rgba as CFData)
        guard let provider,
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              )
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    static func footprint(for metadata: PhotoMetadata, pixelWidth: Int, pixelHeight: Int) -> (width: Double, height: Double, yaw: Double, note: String) {
        let heading = metadata.cameraHeading ?? 0
        let yaw = -heading * Double.pi / 180
        let aspect = Double(pixelHeight) / Double(max(pixelWidth, 1))
        let lookingDown = metadata.pitchDegrees.map { $0 < -50 } ?? (metadata.relativeAltitudeMeters != nil)
        if lookingDown, let altitude = metadata.relativeAltitudeMeters, altitude > 0.5 {
            let equivalent = metadata.focalLength35mm ?? metadata.focalLengthMillimeters.map { $0 * 36 / 6.3 }
            if let equivalent, equivalent > 1 {
                let width = altitude * 36 / equivalent
                let assumed = metadata.focalLength35mm == nil
                let note = assumed
                    ? "Ground size assumes a 6.3 mm wide sensor. The photo is treated as looking down."
                    : "Ground size comes from relative altitude and the 35 mm equivalent focal length."
                return (width, width * aspect, yaw, note)
            }
        }
        return (
            8,
            8 * aspect,
            yaw,
            "Placed from GPS when the site photo has a latitude. Absolute altitude is not a ground size, because the ground elevation is unknown."
        )
    }

    static func siteCenter(metadata: PhotoMetadata, underlay: SiteUnderlay?) -> Vec3 {
        let altitude = metadata.relativeAltitudeMeters ?? 0
        guard metadata.hasLocation, let latitude = metadata.latitude, let longitude = metadata.longitude else {
            return Vec3(x: 0, y: altitude, z: 0)
        }
        let overlay = DroneOverlay(
            image: "site/overlays/preview.jpg",
            pixelWidth: 1,
            pixelHeight: 1,
            center: Vec3(x: 0, y: altitude, z: 0),
            widthMeters: 1,
            heightMeters: 1,
            georeference: Georeference(
                latitude: latitude,
                longitude: longitude,
                headingDegrees: metadata.cameraHeading ?? 0
            )
        )
        return SiteGeodesy.overlayPosition(overlay, underlay: underlay)
    }

    private static func jpeg(_ image: UIImage, maxPixel: CGFloat) -> (data: Data, width: Int, height: Int)? {
        let pixelWidth = max(image.size.width * image.scale, 1)
        let pixelHeight = max(image.size.height * image.scale, 1)
        let longest = max(pixelWidth, pixelHeight)
        let scale = longest > maxPixel ? maxPixel / longest : 1
        let width = max(Int((pixelWidth * scale).rounded()), 1)
        let height = max(Int((pixelHeight * scale).rounded()), 1)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        guard let data = rendered.jpegData(compressionQuality: 0.86) else { return nil }
        return (data, width, height)
    }
}
