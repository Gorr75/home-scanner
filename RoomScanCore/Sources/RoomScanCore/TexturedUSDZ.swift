import Foundation

/// A USDZ whose walls and floors carry JPEG textures. RoomPlan's own USDZ stays untouched on disk.
public enum TexturedUSDZ {
    public static func data(layers: [(plan: FloorPlan, offset: Vec3)], textures: [AppliedTexture]) -> Data? {
        let meshes = texturedMeshes(layers: layers, textures: textures)
        guard !meshes.isEmpty else { return nil }
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
        var files: [(path: String, data: Data)] = []
        for mesh in meshes {
            let name = "Surface_\(mesh.id.uuidString.replacingOccurrences(of: "-", with: "_"))"
            let imageName = "textures/\(mesh.id.uuidString).jpg"
            usda += meshBlock(name: name, imagePath: imageName, mesh: mesh)
            files.append((imageName, mesh.jpeg))
        }
        usda += "}\n"
        var entries: [(path: String, data: Data)] = [("model.usda", Data(usda.utf8))]
        entries.append(contentsOf: files)
        return AlignedZip.archive(files: entries)
    }

    private static func meshBlock(name: String, imagePath: String, mesh: TexturedMesh) -> String {
        var pointText = ""
        var cursor = 0
        while cursor + 2 < mesh.positions.count {
            pointText += "(\(format(mesh.positions[cursor])), \(format(mesh.positions[cursor + 1])), \(format(mesh.positions[cursor + 2])))"
            if cursor + 3 < mesh.positions.count { pointText += ", " }
            cursor += 3
        }
        let sts = stride(from: 0, to: mesh.uvs.count, by: 2).map { index in
            "(\(format(mesh.uvs[index])), \(format(mesh.uvs[index + 1])))"
        }.joined(separator: ", ")
        return """
            def Mesh "\(name)" (
                prepend apiSchemas = ["MaterialBindingAPI"]
            )
            {
                int[] faceVertexCounts = [3, 3]
                int[] faceVertexIndices = [0, 1, 2, 0, 2, 3]
                point3f[] points = [\(pointText)]
                texCoord2f[] primvars:st = [\(sts)] (
                    interpolation = "vertex"
                )
                uniform token subdivisionScheme = "none"
                rel material:binding = </Root/\(name)Mat>
            }
            def Material "\(name)Mat"
            {
                token outputs:surface.connect = </Root/\(name)Mat/Preview.outputs:surface>
                def Shader "Preview"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor.connect = </Root/\(name)Mat/Texture.outputs:rgb>
                    float inputs:roughness = 1
                    token outputs:surface
                }
                def Shader "Texture"
                {
                    uniform token info:id = "UsdUVTexture"
                    asset inputs:file = @\(imagePath)@
                    float2 inputs:st.connect = </Root/\(name)Mat/UV.outputs:result>
                    token inputs:wrapS = "clamp"
                    token inputs:wrapT = "clamp"
                    token outputs:rgb
                }
                def Shader "UV"
                {
                    uniform token info:id = "UsdPrimvarReader_float2"
                    token info:implementationSource = "id"
                    string inputs:varname = "st"
                    float2 outputs:result
                }
            }

        """
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), Double(value))
    }

    private static func texturedMeshes(layers: [(plan: FloorPlan, offset: Vec3)], textures: [AppliedTexture]) -> [TexturedMesh] {
        var meshes: [TexturedMesh] = []
        for texture in textures where texture.corners.count == 4 && !texture.jpeg.isEmpty {
            for layer in layers {
                if let wall = layer.plan.walls.first(where: { $0.id == texture.surfaceId }) {
                    let corners = SurfaceFrame.wallCorners(wall, offset: layer.offset)
                    meshes.append(mesh(id: texture.surfaceId, corners: corners, imageCorners: texture.corners, jpeg: texture.jpeg))
                }
                if let floor = layer.plan.floors.first(where: { $0.id == texture.surfaceId }) {
                    let corners = SurfaceFrame.floorCorners(floor, offset: layer.offset)
                    guard corners.count == 4 else { continue }
                    meshes.append(mesh(id: texture.surfaceId, corners: corners, imageCorners: texture.corners, jpeg: texture.jpeg))
                }
            }
        }
        return meshes
    }

    private static func mesh(id: UUID, corners: [Vec3], imageCorners: [ImagePoint], jpeg: Data) -> TexturedMesh {
        var positions: [Float] = []
        for corner in corners {
            positions.append(Float(corner.x))
            positions.append(Float(corner.y))
            positions.append(Float(corner.z))
        }
        let uvs = imageCorners.flatMap { point in
            [Float(point.x), Float(1 - point.y)]
        }
        return TexturedMesh(id: id, positions: positions, uvs: uvs, jpeg: jpeg)
    }
}

struct TexturedMesh {
    var id: UUID
    var positions: [Float]
    var uvs: [Float]
    var jpeg: Data
}

enum AlignedZip {
    /// Stored ZIP with each file payload starting on a 64-byte boundary, which USDZ requires.
    static func archive(files: [(path: String, data: Data)]) -> Data {
        var locals = Data()
        var central = Data()
        var count: UInt16 = 0
        for file in files {
            let name = Data(file.path.utf8)
            guard !name.isEmpty, name.count < 60000 else { continue }
            let base = 30 + name.count
            let padding = (64 - ((locals.count + base) % 64)) % 64
            let crc = CRC32.hash(file.data)
            let size = UInt32(file.data.count)
            let offset = UInt32(locals.count)
            appendLocal(name: name, extra: padding, crc: crc, size: size, to: &locals)
            locals.append(file.data)
            appendCentral(name: name, extra: padding, crc: crc, size: size, offset: offset, to: &central)
            count += 1
        }
        var archive = locals
        let centralOffset = UInt32(archive.count)
        archive.append(central)
        appendEnd(count: count, centralSize: UInt32(central.count), centralOffset: centralOffset, to: &archive)
        return archive
    }

    private static func appendLocal(name: Data, extra: Int, crc: UInt32, size: UInt32, to data: inout Data) {
        appendUInt32(0x04034B50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0x0021, to: &data)
        appendUInt32(crc, to: &data)
        appendUInt32(size, to: &data)
        appendUInt32(size, to: &data)
        appendUInt16(UInt16(name.count), to: &data)
        appendUInt16(UInt16(extra), to: &data)
        data.append(name)
        if extra > 0 {
            data.append(Data(repeating: 0, count: extra))
        }
    }

    private static func appendCentral(name: Data, extra: Int, crc: UInt32, size: UInt32, offset: UInt32, to data: inout Data) {
        appendUInt32(0x02014B50, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(20, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0x0021, to: &data)
        appendUInt32(crc, to: &data)
        appendUInt32(size, to: &data)
        appendUInt32(size, to: &data)
        appendUInt16(UInt16(name.count), to: &data)
        appendUInt16(UInt16(extra), to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt32(0, to: &data)
        appendUInt32(offset, to: &data)
        data.append(name)
        if extra > 0 {
            data.append(Data(repeating: 0, count: extra))
        }
    }

    private static func appendEnd(count: UInt16, centralSize: UInt32, centralOffset: UInt32, to data: inout Data) {
        appendUInt32(0x06054B50, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(count, to: &data)
        appendUInt16(count, to: &data)
        appendUInt32(centralSize, to: &data)
        appendUInt32(centralOffset, to: &data)
        appendUInt16(0, to: &data)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
