import ARKit
import CoreImage
import CoreVideo
import UIKit
import RoomScanCore

struct ScanHeldFrame: Identifiable {
    var id: UUID
    var jpeg: Data
    var pose: ScanCameraPose
    var manual: Bool
}

enum ScanFrameImage {
    static func jpeg(from buffer: CVPixelBuffer, maxEdge: CGFloat = 1920) -> Data? {
        let source = CIImage(cvPixelBuffer: buffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(source, from: source.extent) else { return nil }
        return jpeg(from: UIImage(cgImage: cgImage), maxEdge: maxEdge, quality: 0.82)
    }

    static func pose(from frame: ARFrame) -> ScanCameraPose {
        let transform = frame.camera.transform
        var columns: [Double] = []
        for index in 0..<4 {
            let column = transform.columns[index]
            columns.append(Double(column.x))
            columns.append(Double(column.y))
            columns.append(Double(column.z))
            columns.append(Double(column.w))
        }
        let intrinsics = frame.camera.intrinsics
        return ScanCameraPose(
            columns: columns,
            fx: Double(intrinsics.columns.0.x),
            fy: Double(intrinsics.columns.1.y),
            cx: Double(intrinsics.columns.2.x),
            cy: Double(intrinsics.columns.2.y),
            imageWidth: Double(CVPixelBufferGetWidth(frame.capturedImage)),
            imageHeight: Double(CVPixelBufferGetHeight(frame.capturedImage)),
            matchesScan: true
        )
    }

    static func jpeg(from image: UIImage, maxEdge: CGFloat, quality: CGFloat = 0.85) -> Data? {
        scaled(image, maxEdge: maxEdge).jpegData(compressionQuality: quality)
    }

    private static func scaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxEdge, longest > 0 else { return image }
        let ratio = maxEdge / longest
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
