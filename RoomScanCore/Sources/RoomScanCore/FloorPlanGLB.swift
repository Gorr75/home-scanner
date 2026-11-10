import Foundation

/// One room (or one storey of a room) ready to bake into a GLB or USDZ.
public struct DrawnLayer: Sendable, Equatable {
    public var plan: FloorPlan
    public var offset: Vec3
    public var furniture: [PlacedFurniture]
    public var flooring: FlooringMaterial?

    public init(
        plan: FloorPlan,
        offset: Vec3,
        furniture: [PlacedFurniture] = [],
        flooring: FlooringMaterial? = nil
    ) {
        self.plan = plan
        self.offset = offset
        self.furniture = furniture
        self.flooring = flooring
    }
}

/// A glTF binary model of a floor plan. Y is up and units are meters, matching the USDZ.
public enum FloorPlanGLB {
    public static func data(for plan: FloorPlan, offset: Vec3 = .zero, textures: [AppliedTexture] = []) -> Data {
        data(for: [(plan, offset)], textures: textures)
    }

    public static func data(for layers: [(plan: FloorPlan, offset: Vec3)], textures: [AppliedTexture] = []) -> Data {
        data(for: layers.map { DrawnLayer(plan: $0.plan, offset: $0.offset) }, textures: textures)
    }

    public static func data(for layers: [DrawnLayer], textures: [AppliedTexture] = []) -> Data {
        let assembled = ModelAssembly.buckets(for: layers)
        var primitives: [GLBPrimitive] = assembled.floors.map { GLBPrimitive(mesh: $0.mesh, shade: $0.shade) }
        primitives.append(GLBPrimitive(mesh: assembled.walls, color: [0.93, 0.91, 0.86, 1.0], roughness: 0.85))
        primitives.append(GLBPrimitive(mesh: assembled.objects, color: [0.55, 0.46, 0.36, 1.0], roughness: 0.7))
        primitives.append(GLBPrimitive(mesh: assembled.openings, color: [0.45, 0.32, 0.22, 1.0], roughness: 0.55))
        primitives.append(contentsOf: assembled.furniture.map {
            GLBPrimitive(mesh: $0.mesh, shade: $0.shade, name: $0.name)
        })
        return GLBEncoder.encode(
            primitives: primitives,
            textured: texturedQuads(layers: layers, textures: textures)
        )
    }

    private static func texturedQuads(layers: [DrawnLayer], textures: [AppliedTexture]) -> [TexturedQuad] {
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

    mutating func addCylinder(center: Vec3, diameter: Double, height: Double, segments: Int = 12) {
        let radius = max(diameter, 0.01) / 2
        let halfHeight = max(height, 0.01) / 2
        let bottom = center.y - halfHeight
        let top = center.y + halfHeight
        let count = max(segments, 6)
        var ring: [(Double, Double)] = []
        for index in 0..<count {
            let angle = Double(index) / Double(count) * 2 * Double.pi
            ring.append((Trig.cos(angle) * radius, Trig.sin(angle) * radius))
        }
        for index in 0..<count {
            let current = ring[index]
            let next = ring[(index + 1) % count]
            let normal = Vec3(x: current.0 + next.0, y: 0, z: current.1 + next.1).normalized()
            addQuad(
                Vec3(x: center.x + current.0, y: bottom, z: center.z + current.1),
                Vec3(x: center.x + next.0, y: bottom, z: center.z + next.1),
                Vec3(x: center.x + next.0, y: top, z: center.z + next.1),
                Vec3(x: center.x + current.0, y: top, z: center.z + current.1),
                normal: normal
            )
            addTriangle(
                Vec3(x: center.x, y: top, z: center.z),
                Vec3(x: center.x + current.0, y: top, z: center.z + current.1),
                Vec3(x: center.x + next.0, y: top, z: center.z + next.1),
                normal: Vec3(x: 0, y: 1, z: 0)
            )
            addTriangle(
                Vec3(x: center.x, y: bottom, z: center.z),
                Vec3(x: center.x + next.0, y: bottom, z: center.z + next.1),
                Vec3(x: center.x + current.0, y: bottom, z: center.z + current.1),
                normal: Vec3(x: 0, y: -1, z: 0)
            )
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
        point + offset
    }
}

struct AssembledMesh {
    var shade: Shade
    var mesh: TriangleMesh
    var name: String?
}

struct ModelBuckets {
    var floors: [AssembledMesh]
    var walls: TriangleMesh
    var objects: TriangleMesh
    var openings: TriangleMesh
    var furniture: [AssembledMesh]

    var isEmpty: Bool {
        floors.allSatisfy(\.mesh.isEmpty) && walls.isEmpty && objects.isEmpty && openings.isEmpty && furniture.allSatisfy(\.mesh.isEmpty)
    }
}

enum ModelAssembly {
    static func buckets(for layers: [DrawnLayer]) -> ModelBuckets {
        var floors: [Shade: TriangleMesh] = [:]
        var walls = TriangleMesh()
        var objects = TriangleMesh()
        var openings = TriangleMesh()
        var furniture: [String: (shade: Shade, mesh: TriangleMesh)] = [:]
        for layer in layers {
            let floorShade = Shade(flooring: layer.flooring)
            var floorMesh = floors[floorShade] ?? TriangleMesh()
            floorMesh.addFloors(layer.plan.floors, offset: layer.offset)
            floors[floorShade] = floorMesh
            walls.addWalls(layer.plan.walls, offset: layer.offset)
            let hidden = Set(layer.furniture.compactMap(\.replacesObjectId))
            objects.addObjects(layer.plan.objects.filter { !hidden.contains($0.id) }, offset: layer.offset)
            openings.addOpenings(layer.plan.openings, offset: layer.offset)
            addFurniture(layer.furniture, offset: layer.offset, into: &furniture)
        }
        if floors.values.allSatisfy(\.isEmpty) && walls.isEmpty && objects.isEmpty && openings.isEmpty && furniture.isEmpty {
            var pad = TriangleMesh()
            pad.addBox(
                center: Vec3(x: 0, y: 0.01, z: 0),
                size: Vec3(x: 1, y: 0.02, z: 1),
                yaw: 0
            )
            floors[Shade(flooring: nil)] = pad
        }
        return ModelBuckets(
            floors: floors.keys.sorted().map { AssembledMesh(shade: $0, mesh: floors[$0] ?? TriangleMesh(), name: nil) },
            walls: walls,
            objects: objects,
            openings: openings,
            furniture: furniture.keys.sorted().map { key in
                let entry = furniture[key]
                return AssembledMesh(shade: entry?.shade ?? Shade(flooring: nil), mesh: entry?.mesh ?? TriangleMesh(), name: key)
            }
        )
    }

    private static func addFurniture(
        _ items: [PlacedFurniture],
        offset: Vec3,
        into meshes: inout [String: (shade: Shade, mesh: TriangleMesh)]
    ) {
        for item in items {
            for part in FurnitureGeometry.parts(of: item) {
                let shade = Shade(material: part.material)
                let group = "furniture_\(item.catalogId)_\(part.material.name)"
                var entry = meshes[group] ?? (shade, TriangleMesh())
                let center = part.center + offset
                switch part.shape {
                case .box:
                    entry.mesh.addBox(center: center, size: part.size, yaw: part.yaw)
                case .cylinder:
                    entry.mesh.addCylinder(center: center, diameter: max(part.size.x, 0.01), height: max(part.size.y, 0.01))
                }
                meshes[group] = entry
            }
        }
    }
}

struct Shade: Hashable, Comparable {
    var red: Int
    var green: Int
    var blue: Int
    var alpha: Int
    var roughness: Int
    var metallic: Int

    init(material: FurnitureMaterial) {
        red = Self.quantized(material.red)
        green = Self.quantized(material.green)
        blue = Self.quantized(material.blue)
        alpha = Self.quantized(material.alpha)
        roughness = Self.quantized(material.roughness)
        metallic = Self.quantized(material.metallic)
    }

    init(flooring: FlooringMaterial?) {
        if let flooring {
            red = Self.quantized(flooring.red)
            green = Self.quantized(flooring.green)
            blue = Self.quantized(flooring.blue)
        } else {
            red = Self.quantized(0.86)
            green = Self.quantized(0.80)
            blue = Self.quantized(0.68)
        }
        alpha = 1000
        roughness = 900
        metallic = 0
    }

    var color: [Double] {
        [Double(red) / 1000, Double(green) / 1000, Double(blue) / 1000, Double(alpha) / 1000]
    }

    var roughnessFactor: Double { Double(roughness) / 1000 }
    var metallicFactor: Double { Double(metallic) / 1000 }
    var blends: Bool { alpha < 990 }

    var token: String { "\(red)-\(green)-\(blue)-\(alpha)" }

    static func < (lhs: Shade, rhs: Shade) -> Bool {
        if lhs.token != rhs.token { return lhs.token < rhs.token }
        if lhs.roughness != rhs.roughness { return lhs.roughness < rhs.roughness }
        return lhs.metallic < rhs.metallic
    }

    private static func quantized(_ value: Double) -> Int {
        Int((min(1, max(0, value)) * 1000).rounded())
    }
}

struct GLBPrimitive {
    var mesh: TriangleMesh
    var color: [Double]
    var roughness: Double
    var metallic: Double
    var blend: Bool
    var name: String?

    init(mesh: TriangleMesh, color: [Double], roughness: Double = 0.9, metallic: Double = 0, blend: Bool = false, name: String? = nil) {
        self.mesh = mesh
        self.color = color
        self.roughness = roughness
        self.metallic = metallic
        self.blend = blend
        self.name = name
    }

    init(mesh: TriangleMesh, shade: Shade, name: String? = nil) {
        self.init(
            mesh: mesh,
            color: shade.color,
            roughness: shade.roughnessFactor,
            metallic: shade.metallicFactor,
            blend: shade.blends,
            name: name
        )
    }
}

enum GLBEncoder {
    static func encode(primitives: [GLBPrimitive], textured: [TexturedQuad] = []) -> Data {
        var buffer = Data()
        var bufferViews: [[String: Any]] = []
        var accessors: [[String: Any]] = []
        var primitiveJSON: [[String: Any]] = []
        var materials: [[String: Any]] = []
        var images: [[String: Any]] = []
        var textureJSON: [[String: Any]] = []

        for primitive in primitives where !primitive.mesh.isEmpty {
            let mesh = primitive.mesh
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
            var material: [String: Any] = [
                "doubleSided": true,
                "pbrMetallicRoughness": [
                    "baseColorFactor": primitive.color,
                    "metallicFactor": primitive.metallic,
                    "roughnessFactor": primitive.roughness
                ]
            ]
            if primitive.blend {
                material["alphaMode"] = "BLEND"
            }
            if let name = primitive.name {
                material["name"] = name
            }
            materials.append(material)
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
