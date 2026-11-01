import ARKit
import Metal
import RoomScanCore
import simd

enum OutdoorScanSupport {
    static let rangeMeters = MeshRange.lidarMeters

    static var canScan: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    static var unavailableReason: String {
        #if targetEnvironment(simulator)
        "The simulator has no LiDAR sensor. Outdoor meshes need a physical iPhone or iPad Pro. You can still place the sample shed and an aerial photo on the site plan."
        #else
        "This device cannot build a LiDAR scene mesh. Outdoor scans need an iPhone or iPad Pro. The site plan still accepts an aerial photo and any rooms you have already scanned."
        #endif
    }
}

enum MeshCapture {
    /// Copies one mesh chunk and keeps only triangles inside the LiDAR's useful range.
    static func localMesh(from anchor: ARMeshAnchor) -> TriangleMesh {
        let geometry = anchor.geometry
        let source = geometry.vertices
        // ARKit documents mesh vertices as float3. A future SDK that changes the format
        // should fail this guard instead of reading the buffer as the wrong type.
        guard source.format == .float3, source.componentsPerVector >= 3, source.stride >= MemoryLayout<Float>.size * 3 else {
            return TriangleMesh(vertices: [], faces: [])
        }
        let base = source.buffer.contents()
        var vertices: [Vec3] = []
        vertices.reserveCapacity(source.count)
        for index in 0..<source.count {
            let pointer = base.advanced(by: source.offset + index * source.stride).assumingMemoryBound(to: Float.self)
            vertices.append(Vec3(x: Double(pointer[0]), y: Double(pointer[1]), z: Double(pointer[2])))
        }
        let faces = geometry.faces
        let faceBase = faces.buffer.contents()
        let primitive = faces.indexCountPerPrimitive
        guard primitive >= 3,
              faces.bytesPerIndex == MemoryLayout<UInt16>.size || faces.bytesPerIndex == MemoryLayout<UInt32>.size
        else { return TriangleMesh(vertices: vertices, faces: []) }
        var meshFaces: [MeshFace] = []
        meshFaces.reserveCapacity(faces.count)
        for faceIndex in 0..<faces.count {
            var indices: [Int] = []
            indices.reserveCapacity(primitive)
            for corner in 0..<primitive {
                let offset = (faceIndex * primitive + corner) * faces.bytesPerIndex
                let value: Int
                if faces.bytesPerIndex == MemoryLayout<UInt32>.size {
                    value = Int(faceBase.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee)
                } else {
                    value = Int(faceBase.advanced(by: offset).assumingMemoryBound(to: UInt16.self).pointee)
                }
                indices.append(value)
            }
            meshFaces.append(MeshFace(a: indices[0], b: indices[1], c: indices[2]))
        }
        return MeshRange.clipped(TriangleMesh(vertices: vertices, faces: meshFaces))
    }

    static func worldMesh(from anchors: [ARMeshAnchor]) -> TriangleMesh {
        var vertices: [Vec3] = []
        var faces: [MeshFace] = []
        for anchor in anchors {
            let local = localMesh(from: anchor)
            let pose = pose(from: anchor.transform)
            let base = vertices.count
            vertices.append(contentsOf: local.vertices.map { pose.applying($0) })
            faces.append(contentsOf: local.faces.map { face in
                MeshFace(a: face.a + base, b: face.b + base, c: face.c + base)
            })
        }
        return TriangleMesh(vertices: vertices, faces: faces)
    }

    private static func pose(from matrix: simd_float4x4) -> Transform {
        Transform(
            axisX: Vec3(x: Double(matrix.columns.0.x), y: Double(matrix.columns.0.y), z: Double(matrix.columns.0.z)),
            axisY: Vec3(x: Double(matrix.columns.1.x), y: Double(matrix.columns.1.y), z: Double(matrix.columns.1.z)),
            axisZ: Vec3(x: Double(matrix.columns.2.x), y: Double(matrix.columns.2.y), z: Double(matrix.columns.2.z)),
            translation: Vec3(x: Double(matrix.columns.3.x), y: Double(matrix.columns.3.y), z: Double(matrix.columns.3.z))
        )
    }
}

final class OutdoorMeshCollector: NSObject, ObservableObject, ARSessionDelegate {
    private let lock = NSLock()
    private var anchors: [UUID: ARMeshAnchor] = [:]

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        store(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        store(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        lock.lock()
        for anchor in anchors {
            self.anchors[anchor.identifier] = nil
        }
        lock.unlock()
    }

    func snapshot() -> TriangleMesh {
        lock.lock()
        let current = Array(anchors.values)
        lock.unlock()
        return MeshCapture.worldMesh(from: current)
    }

    private func store(_ anchors: [ARAnchor]) {
        lock.lock()
        for anchor in anchors {
            if let mesh = anchor as? ARMeshAnchor {
                self.anchors[mesh.identifier] = mesh
            }
        }
        lock.unlock()
    }
}
