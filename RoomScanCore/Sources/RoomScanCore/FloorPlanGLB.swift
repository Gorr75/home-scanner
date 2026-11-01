import Foundation

/// A glTF binary model of a floor plan. Y is up and units are meters, matching the USDZ.
public enum FloorPlanGLB {
    public static func data(for plan: FloorPlan, offset: Vec3 = .zero, textures: [AppliedTexture] = []) -> Data {
        data(for: [(plan, offset)], textures: textures)
    }

    public static func data(for layers: [(plan: FloorPlan, offset: Vec3)], textures: [AppliedTexture] = []) -> Data {
        var floors = TriangleMesh()
        var walls = TriangleMesh()
        var objects = TriangleMesh()
        var openings = TriangleMesh()
        for layer in layers {
            floors.addFloors(layer.plan.floors, offset: layer.offset)
            walls.addWalls(layer.plan.walls, offset: layer.offset)
            objects.addObjects(layer.plan.objects, offset: layer.offset)
            openings.addOpenings(layer.plan.openings, offset: layer.offset)
        }
        if floors.isEmpty && walls.isEmpty && objects.isEmpty && openings.isEmpty {
            floors.addBox(
                center: Vec3(x: 0, y: 0.01, z: 0),
                size: Vec3(x: 1, y: 0.02, z: 1),
                yaw: 0
            )
        }
        return GLBEncoder.encode(
            primitives: [
                (floors, [0.86, 0.80, 0.68, 1.0]),
                (walls, [0.93, 0.91, 0.86, 1.0]),
                (objects, [0.55, 0.46, 0.36, 1.0]),
                (openings, [0.45, 0.32, 0.22, 1.0])
            ],
            textured: texturedQuads(layers: layers, textures: textures)
        )
    }

    private static func texturedQuads(layers: [(plan: FloorPlan, offset: Vec3)], textures: [AppliedTexture]) -> [TexturedQuad] {
        var quads: [TexturedQuad] = []
        for texture in textures where texture.corners.count == 4 && !texture.jpeg.isEmpty {
            for layer in layers {
                let corners: [Vec3]
                if let wall = layer.plan.walls.first(where: { $0.id == texture.surfaceId }) {
                    corners = SurfaceFrame.wallCorners(wall, offset: layer.offset)
                } else if let floor = layer.plan.floors.first(where: { $0.id == texture.surfaceId }) {
                    corners = SurfaceFrame.floorCorners(floor, offset: layer.offset)
                } else {
                    corners = []
                }
                guard corners.count == 4 else { continue }
                quads.append(TexturedQuad(corners: corners, imageCorners: texture.corners, jpeg: texture.jpeg))
            }
        }
        return quads
    }
}

struct TexturedQuad {
    var positions: [Float]
    var normals: [Float]
    var uvs: [Float]
    var indices: [UInt32]
    var jpeg: Data

    init(corners: [Vec3], imageCorners: [ImagePoint], jpeg: Data) {
        let normal = SurfaceFrame.faceNormal(corners)
        positions = corners.flatMap { [Float($0.x), Float($0.y), Float($0.z)] }
        normals = corners.flatMap { _ in [Float(normal.x), Float(normal.y), Float(normal.z)] }
        uvs = imageCorners.flatMap { [Float($0.x), Float(1 - $0.y)] }
        indices = [0, 1, 2, 0, 2, 3]
        self.jpeg = jpeg
    }
}

struct TriangleMesh {
    var positions: [Float] = []
    var normals: [Float] = []
    var indices: [UInt32] = []

    var isEmpty: Bool { indices.isEmpty }

    mutating func addFloors(_ floors: [FloorPolygon], offset: Vec3) {
        for floor in floors where floor.corners.count >= 3 {
            let corners = floor.corners.map { shifted($0, by: offset) }
            for index in 1..<(corners.count - 1) {
                addTriangle(corners[0], corners[index], corners[index + 1], normal: Vec3(x: 0, y: 1, z: 0))
            }
        }
    }

    mutating func addWalls(_ walls: [WallSegment], offset: Vec3) {
        for wall in walls where wall.length > 0.02 {
            let start = shifted(wall.start, by: offset)
            let end = shifted(wall.end, by: offset)
            let delta = end - start
            let yaw = Trig.atan2(delta.z, delta.x)
            let center = Vec3(
                x: (start.x + end.x) / 2,
                y: start.y + wall.height / 2,
                z: (start.z + end.z) / 2
            )
            addBox(
                center: center,
                size: Vec3(x: wall.length, y: max(wall.height, 0.05), z: max(wall.thickness, 0.02)),
                yaw: yaw
            )
        }
    }

    mutating func addObjects(_ objects: [PlacedObject], offset: Vec3) {
        for object in objects {
            addBox(
                center: shifted(object.center, by: offset),
                size: Vec3(
                    x: max(object.dimensions.x, 0.05),
                    y: max(object.dimensions.y, 0.05),
                    z: max(object.dimensions.z, 0.05)
                ),
                yaw: object.yaw
            )
        }
    }

    mutating func addOpenings(_ openings: [Opening], offset: Vec3) {
        for opening in openings {
            addBox(
                center: shifted(opening.center, by: offset),
                size: Vec3(x: max(opening.width, 0.05), y: max(opening.height, 0.05), z: 0.08),
                yaw: opening.yaw
            )
        }
    }

    mutating func addBox(center: Vec3, size: Vec3, yaw: Double) {
        let hx = size.x / 2
        let hy = size.y / 2
        let hz = size.z / 2
        let cosine = Trig.cos(yaw)
        let sine = Trig.sin(yaw)
        func world(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
            Vec3(
                x: center.x + x * cosine - z * sine,
                y: center.y + y,
                z: center.z + x * sine + z * cosine
            )
        }
        func normal(_ x: Double, _ y: Double, _ z: Double) -> Vec3 {
            Vec3(x: x * cosine - z * sine, y: y, z: x * sine + z * cosine)
        }
        let faces: [(Vec3, Vec3, Vec3, Vec3, Vec3)] = [
            (world(-hx, hy, -hz), world(hx, hy, -hz), world(hx, hy, hz), world(-hx, hy, hz), normal(0, 1, 0)),
            (world(-hx, -hy, hz), world(hx, -hy, hz), world(hx, -hy, -hz), world(-hx, -hy, -hz), normal(0, -1, 0)),
            (world(hx, -hy, -hz), world(hx, hy, -hz), world(hx, hy, hz), world(hx, -hy, hz), normal(1, 0, 0)),
            (world(-hx, -hy, hz), world(-hx, hy, hz), world(-hx, hy, -hz), world(-hx, -hy, -hz), normal(-1, 0, 0)),
            (world(-hx, -hy, hz), world(hx, -hy, hz), world(hx, hy, hz), world(-hx, hy, hz), normal(0, 0, 1)),
            (world(hx, -hy, -hz), world(-hx, -hy, -hz), world(-hx, hy, -hz), world(hx, hy, -hz), normal(0, 0, -1))
        ]
        for face in faces {
            addQuad(face.0, face.1, face.2, face.3, normal: face.4)
        }
    }

    private mutating func addTriangle(_ a: Vec3, _ b: Vec3, _ c: Vec3, normal: Vec3) {
        let base = UInt32(positions.count / 3)
        append(a, normal: normal)
        append(b, normal: normal)
        append(c, normal: normal)
        indices.append(contentsOf: [base, base + 1, base + 2])
    }

    private mutating func addQuad(_ a: Vec3, _ b: Vec3, _ c: Vec3, _ d: Vec3, normal: Vec3) {
        let base = UInt32(positions.count / 3)
        append(a, normal: normal)
        append(b, normal: normal)
        append(c, normal: normal)
        append(d, normal: normal)
        indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }

    private mutating func append(_ vertex: Vec3, normal: Vec3) {
        positions.append(contentsOf: [Float(vertex.x), Float(vertex.y), Float(vertex.z)])
        normals.append(contentsOf: [Float(normal.x), Float(normal.y), Float(normal.z)])
    }

    private func shifted(_ point: Vec3, by offset: Vec3) -> Vec3 {
        Vec3(x: point.x + offset.x, y: point.y, z: point.z + offset.z)
    }
}

enum GLBEncoder {
    static func encode(primitives: [(TriangleMesh, [Double])], textured: [TexturedQuad] = []) -> Data {
        var buffer = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var primitiveJSON: [[String: Any]] = []
        var materials: [[String: Any]] = []
        var images: [[String: Any]] = []
        var textureJSON: [[String: Any]] = []

        for (mesh, color) in primitives where !mesh.isEmpty {
            let positionView = append(floats: mesh.positions, to: &buffer, views: &bufferViews, target: 34962)
            let normalView = append(floats: mesh.normals, to: &buffer, views: &bufferViews, target: 34962)
            let indexView = append(indices: mesh.indices, to: &buffer, views: &bufferViews)
            let positionAccessor = accessors.count
            accessors.append(positionAccessorJSON(mesh.positions, view: positionView))
            accessors.append([
                "bufferView": normalView,
                "componentType": 5126,
                "count": mesh.normals.count / 3,
                "type": "VEC3"
            ])
            accessors.append([
                "bufferView": indexView,
                "componentType": 5125,
                "count": mesh.indices.count,
                "type": "SCALAR"
            ])
            let materialIndex = materials.count
            materials.append([
                "doubleSided": true,
                "pbrMetallicRoughness": [
                    "baseColorFactor": color,
                    "metallicFactor": 0.0,
                    "roughnessFactor": 0.9
                ]
            ])
            primitiveJSON.append([
                "attributes": ["POSITION": positionAccessor, "NORMAL": positionAccessor + 1],
                "indices": positionAccessor + 2,
                "material": materialIndex,
                "mode": 4
            ])
        }

        for quad in textured where quad.positions.count >= 12 && quad.uvs.count >= 8 {
            let positionView = append(floats: quad.positions, to: &buffer, views: &bufferViews, target: 34962)
            let normalView = append(floats: quad.normals, to: &buffer, views: &bufferViews, target: 34962)
            let uvView = append(floats: quad.uvs, to: &buffer, views: &bufferViews, target: 34962)
            let indexView = append(indices: quad.indices, to: &buffer, views: &bufferViews)
            let imageView = append(bytes: quad.jpeg, to: &buffer, views: &bufferViews)
            let positionAccessor = accessors.count
            accessors.append(positionAccessorJSON(quad.positions, view: positionView))
            accessors.append([
                "bufferView": normalView,
                "componentType": 5126,
                "count": quad.normals.count / 3,
                "type": "VEC3"
            ])
            accessors.append([
                "bufferView": uvView,
                "componentType": 5126,
                "count": quad.uvs.count / 2,
                "type": "VEC2"
            ])
            accessors.append([
                "bufferView": indexView,
                "componentType": 5125,
                "count": quad.indices.count,
                "type": "SCALAR"
            ])
            let imageIndex = images.count
            images.append([
                "bufferView": imageView,
                "mimeType": "image/jpeg"
            ])
            let textureIndex = textureJSON.count
            textureJSON.append(["source": imageIndex])
            let materialIndex = materials.count
            materials.append([
                "doubleSided": true,
                "pbrMetallicRoughness": [
                    "baseColorTexture": ["index": textureIndex],
                    "metallicFactor": 0.0,
                    "roughnessFactor": 1.0
                ]
            ])
            primitiveJSON.append([
                "attributes": [
                    "POSITION": positionAccessor,
                    "NORMAL": positionAccessor + 1,
                    "TEXCOORD_0": positionAccessor + 2
                ],
                "indices": positionAccessor + 3,
                "material": materialIndex,
                "mode": 4
            ])
        }

        var jsonObject: [String: Any] = [
            "asset": ["version": "2.0", "generator": "Home Scanner"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["primitives": primitiveJSON]],
            "materials": materials,
            "buffers": [["byteLength": buffer.count]],
            "bufferViews": bufferViews,
            "accessors": accessors
        ]
        if !images.isEmpty {
            jsonObject["images"] = images
            jsonObject["textures"] = textureJSON
        }
        let json = (try? JSONSerialization.data(withJSONObject: jsonObject)) ?? Data("{}".utf8)
        return pack(json: json, bin: buffer)
    }

    private static func append(
        floats: [Float],
        to buffer: inout Data,
        views: inout [[String: Any]],
        target: Int
    ) -> Int {
        let viewIndex = views.count
        let offset = buffer.count
        for value in floats {
            appendFloat(value, to: &buffer)
        }
        views.append([
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": floats.count * 4,
            "target": target
        ])
        return viewIndex
    }

    private static func append(
        indices: [UInt32],
        to buffer: inout Data,
        views: inout [[String: Any]]
    ) -> Int {
        let viewIndex = views.count
        let offset = buffer.count
        for value in indices {
            appendUInt32(value, to: &buffer)
        }
        views.append([
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": indices.count * 4,
            "target": 34963
        ])
        return viewIndex
    }

    private static func append(bytes: Data, to buffer: inout Data, views: inout [[String: Any]]) -> Int {
        let viewIndex = views.count
        let offset = buffer.count
        buffer.append(bytes)
        let extra = (4 - (buffer.count % 4)) % 4
        if extra > 0 {
            buffer.append(Data(repeating: 0, count: extra))
        }
        views.append([
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": bytes.count
        ])
        return viewIndex
    }

    private static func positionAccessorJSON(_ positions: [Float], view: Int) -> [String: Any] {
        var minX = Float.greatestFiniteMagnitude
        var minY = minX
        var minZ = minX
        var maxX = -Float.greatestFiniteMagnitude
        var maxY = maxX
        var maxZ = maxX
        var index = 0
        while index + 2 < positions.count {
            minX = min(minX, positions[index])
            minY = min(minY, positions[index + 1])
            minZ = min(minZ, positions[index + 2])
            maxX = max(maxX, positions[index])
            maxY = max(maxY, positions[index + 1])
            maxZ = max(maxZ, positions[index + 2])
            index += 3
        }
        return [
            "bufferView": view,
            "componentType": 5126,
            "count": positions.count / 3,
            "type": "VEC3",
            "min": [Double(minX), Double(minY), Double(minZ)],
            "max": [Double(maxX), Double(maxY), Double(maxZ)]
        ]
    }

    private static func pack(json: Data, bin: Data) -> Data {
        var jsonChunk = json
        pad(&jsonChunk, fill: 0x20)
        var binChunk = bin
        pad(&binChunk, fill: 0x00)
        let total = 12 + 8 + jsonChunk.count + 8 + binChunk.count
        var data = Data()
        appendUInt32(0x46546C67, to: &data)
        appendUInt32(2, to: &data)
        appendUInt32(UInt32(total), to: &data)
        appendUInt32(UInt32(jsonChunk.count), to: &data)
        appendUInt32(0x4E4F534A, to: &data)
        data.append(jsonChunk)
        appendUInt32(UInt32(binChunk.count), to: &data)
        appendUInt32(0x004E4942, to: &data)
        data.append(binChunk)
        return data
    }

    private static func pad(_ data: inout Data, fill: UInt8) {
        let extra = (4 - (data.count % 4)) % 4
        if extra > 0 {
            data.append(Data(repeating: fill, count: extra))
        }
    }

    private static func appendFloat(_ value: Float, to data: inout Data) {
        var le = value.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
