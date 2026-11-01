import SceneKit
import UIKit
import RoomScanCore

enum TexturedFacade {
    /// Builds a wall quad whose texture follows the four-corner homography.
    /// SceneKit samples each small cell affinely, so the grid is what makes the perspective hold.
    static func node(wall: WallSegment, image: UIImage, texture: SurfaceTexture, divisions: Int = 8) -> SCNNode? {
        guard texture.isUsable, let homography = PlaneHomography.wallToImage(corners: texture.corners) else { return nil }
        let steps = max(divisions, 1)
        let axis = wall.end - wall.start
        let rawNormal = Vec3(x: -axis.z, y: 0, z: axis.x)
        let normal = rawNormal.normalized()
        var vertices: [SCNVector3] = []
        var texels: [CGPoint] = []
        vertices.reserveCapacity((steps + 1) * (steps + 1))
        for row in 0...steps {
            let t = Double(row) / Double(steps)
            for column in 0...steps {
                let s = Double(column) / Double(steps)
                guard let uv = homography.imagePoint(s: s, t: t) else { return nil }
                let position = wall.start
                    + axis.scaled(s)
                    + Vec3(x: 0, y: wall.height * t, z: 0)
                    + normal.scaled(0.03)
                vertices.append(SCNVector3(Float(position.x), Float(position.y), Float(position.z)))
                texels.append(CGPoint(x: uv.u, y: 1 - uv.v))
            }
        }
        var indices: [UInt32] = []
        let stride = steps + 1
        for row in 0..<steps {
            for column in 0..<steps {
                let base = UInt32(row * stride + column)
                let next = base + UInt32(stride)
                indices.append(contentsOf: [base, base + 1, next + 1, base, next + 1, next])
            }
        }
        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(textureCoordinates: texels)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let material = SCNMaterial()
        material.diffuse.contents = image
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}
