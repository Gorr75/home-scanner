import UIKit
import RoomScanCore

enum FloorPlanPDF {
    static func fileURL(for home: Home) throws -> URL {
        let data = render(home)
        var name = home.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Home" }
        name = name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) floor plan.pdf")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func render(_ home: Home) -> Data {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        return renderer.pdfData { context in
            context.beginPage()
            var y = 40.0
            y = draw(
                home.name,
                at: y,
                font: .systemFont(ofSize: 22, weight: .semibold),
                color: ink
            )
            let rooms = MeasurementMath.summarize(home: home)
            let total = rooms.reduce(0) { $0 + $1.measurements.floorArea }
            y = draw(
                "Floor area \(MeasurementMath.squareMeters(total))",
                at: y + 8,
                font: .systemFont(ofSize: 14, weight: .regular),
                color: ink
            )
            y += 12
            for room in rooms {
                y = draw(room.name, at: y + 10, font: .systemFont(ofSize: 16, weight: .semibold), color: ink)
                let summary = room.measurements
                y = draw(
                    "Area \(MeasurementMath.squareMeters(summary.floorArea)) · walls \(MeasurementMath.meters(summary.wallLength)) m",
                    at: y + 2,
                    font: .systemFont(ofSize: 12, weight: .regular),
                    color: secondary
                )
                if !summary.doorWidths.isEmpty {
                    let doors = summary.doorWidths.map { "\(MeasurementMath.meters($0)) m" }.joined(separator: ", ")
                    y = draw("Doors \(doors)", at: y + 2, font: .systemFont(ofSize: 12, weight: .regular), color: secondary)
                }
                if !summary.windowWidths.isEmpty {
                    let windows = summary.windowWidths.map { "\(MeasurementMath.meters($0)) m" }.joined(separator: ", ")
                    y = draw("Windows \(windows)", at: y + 2, font: .systemFont(ofSize: 12, weight: .regular), color: secondary)
                }
                y = drawWalls(summary.wallLengths, at: y + 4)
            }
            if let first = home.rooms.first {
                drawPlan(first.floorPlan, in: context.cgContext, top: CGFloat(max(y + 24, 360)))
            }
        }
    }

    @discardableResult
    private static func draw(_ text: String, at y: Double, font: UIFont, color: UIColor) -> Double {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let rect = CGRect(x: 36, y: CGFloat(y), width: 520, height: 28)
        (text as NSString).draw(in: rect, withAttributes: attributes)
        return y + Double(font.lineHeight)
    }

    private static func drawWalls(_ lengths: [Double], at y: Double) -> Double {
        let text = lengths.enumerated().map { index, length in
            "Wall \(index + 1) \(MeasurementMath.meters(length)) m"
        }.joined(separator: "   ")
        return draw(text, at: y, font: .systemFont(ofSize: 11, weight: .regular), color: secondary)
    }

    private static func drawPlan(_ plan: FloorPlan, in context: CGContext, top: CGFloat) {
        let bounds = FloorPlanGeometry.bounds(of: plan)
        let spanX = max(bounds.size.x, 0.001)
        let spanZ = max(bounds.size.z, 0.001)
        let frame = CGRect(x: 36, y: top, width: 520, height: 280)
        let scale = min(frame.width / spanX, frame.height / spanZ)
        func point(_ x: Double, _ z: Double) -> CGPoint {
            CGPoint(
                x: frame.minX + (x - bounds.min.x) * scale,
                y: frame.minY + (z - bounds.min.z) * scale
            )
        }
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(2)
        context.beginPath()
        for wall in plan.walls {
            let start = point(wall.start.x, wall.start.z)
            let end = point(wall.end.x, wall.end.z)
            context.move(to: start)
            context.addLine(to: end)
        }
        context.strokePath()
    }

    private static let ink = UIColor(red: 0.110, green: 0.098, blue: 0.082, alpha: 1)
    private static let secondary = UIColor(red: 0.361, green: 0.337, blue: 0.298, alpha: 1)
}
