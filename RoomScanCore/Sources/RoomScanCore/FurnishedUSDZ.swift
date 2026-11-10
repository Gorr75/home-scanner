import Foundation

/// A USDZ of the measured plan plus catalog furniture. RoomPlan's own USDZ stays on disk.
public enum FurnishedUSDZ {
    public static func data(layers: [DrawnLayer]) -> Data? {
        let assembled = ModelAssembly.buckets(for: layers)
        guard !assembled.isEmpty else { return nil }
        var usda = """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )
        def Xform "Root"
        {

        """
        var index = 0
        func appendMesh(name: String, mesh: TriangleMesh, shade: Shade) {
            guard !mesh.isEmpty else { return }
            usda += meshBlock(name: "\(name)_\(index)", mesh: mesh, shade: shade)
            index += 1
        }
        for floor in assembled.floors {
            appendMesh(name: "Floor", mesh: floor.mesh, shade: floor.shade)
        }
        appendMesh(name: "Walls", mesh: assembled.walls, shade: Shade(material: FurnitureMaterial(name: "wall", red: 0.93, green: 0.91, blue: 0.86, roughness: 0.85)))
        appendMesh(name: "Objects", mesh: assembled.objects, shade: Shade(material: FurnitureMaterial(name: "object", red: 0.55, green: 0.46, blue: 0.36, roughness: 0.7)))
        appendMesh(name: "Openings", mesh: assembled.openings, shade: Shade(material: FurnitureMaterial(name: "opening", red: 0.45, green: 0.32, blue: 0.22, roughness: 0.55)))
        for item in assembled.furniture {
            appendMesh(name: item.name ?? "Furniture", mesh: item.mesh, shade: item.shade)
        }
        usda += "}\n"
        return AlignedZip.archive(files: [("model.usda", Data(usda.utf8))])
    }

    private static func meshBlock(name: String, mesh: TriangleMesh, shade: Shade) -> String {
        let safe = name.replacingOccurrences(of: "-", with: "_")
        var points = ""
        var cursor = 0
        while cursor + 2 < mesh.positions.count {
            points += "(\(format(mesh.positions[cursor])), \(format(mesh.positions[cursor + 1])), \(format(mesh.positions[cursor + 2])))"
            if cursor + 3 < mesh.positions.count { points += ", " }
            cursor += 3
        }
        let faceCount = mesh.indices.count / 3
        let counts = Array(repeating: "3", count: faceCount).joined(separator: ", ")
        let indices = mesh.indices.map(String.init).joined(separator: ", ")
        let color = shade.color
        return """
            def Mesh "\(safe)" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                int[] faceVertexCounts = [\(counts)]
                int[] faceVertexIndices = [\(indices)]
                point3f[] points = [\(points)]
                uniform bool doubleSided = 1
                uniform token subdivisionScheme = "none"
                rel material:binding = </Root/\(safe)Mat>
            }
            def Material "\(safe)Mat"
            {
                token outputs:surface.connect = </Root/\(safe)Mat/Preview.outputs:surface>
                def Shader "Preview"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (\(format(Float(color[0]))), \(format(Float(color[1]))), \(format(Float(color[2]))))
                    float inputs:roughness = \(format(Float(shade.roughnessFactor)))
                    float inputs:metallic = \(format(Float(shade.metallicFactor)))
                    float inputs:opacity = \(format(Float(color.count > 3 ? color[3] : 1)))
                    token outputs:surface
                }
            }

        """
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }
}
