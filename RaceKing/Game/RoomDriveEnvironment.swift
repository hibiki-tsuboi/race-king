//
//  RoomDriveEnvironment.swift
//  RaceKing
//

import Foundation
import RealityKit
import RoomPlan
import simd

/// A RoomPlan scan reduced to the floor and furniture geometry needed by the
/// arcade physics. Coordinates stay in the shared ARSession's world space.
struct RoomDriveEnvironment {
    struct Obstacle {
        let identifier: UUID
        let transform: simd_float4x4
        let inverseTransform: simd_float4x4
        let dimensions: SIMD3<Float>
    }

    struct Collision {
        let position: SIMD3<Float>
        /// Points from the driveable area toward the barrier when possible.
        let normal: SIMD3<Float>
    }

    enum ScanError: LocalizedError {
        case floorNotFound

        var errorDescription: String? {
            switch self {
            case .floorNotFound:
                return "走行できる床を検出できませんでした。床全体が映るようにもう一度スキャンしてください。"
            }
        }
    }

    /// Floor outline in AR world XZ coordinates.
    let floorPolygon: [SIMD2<Float>]
    let floorHeight: Float
    let obstacles: [Obstacle]

    init(capturedRoom: CapturedRoom) throws {
        let floorCandidates = capturedRoom.floors.compactMap { floor -> (points: [SIMD3<Float>], area: Float)? in
            let points = Self.worldCorners(of: floor)
            guard points.count >= 3 else { return nil }
            let polygon = points.map { SIMD2($0.x, $0.z) }
            return (points, abs(Self.signedArea(of: polygon)))
        }
        guard let floor = floorCandidates.max(by: { $0.area < $1.area }), floor.area > 0.2 else {
            throw ScanError.floorNotFound
        }

        let detectedFloorHeight = floor.points.map(\.y).reduce(0, +)
            / Float(floor.points.count)
        floorPolygon = floor.points.map { SIMD2($0.x, $0.z) }
        floorHeight = detectedFloorHeight

        obstacles = capturedRoom.objects.compactMap { object in
            let dimensions = object.dimensions
            guard dimensions.x > 0.04, dimensions.y > 0.04, dimensions.z > 0.04 else {
                return nil
            }

            // Wall-mounted objects such as televisions should not block a
            // miniature car. Floor-standing furniture has geometry near the floor.
            let centerY = object.transform.columns.3.y
            let bottomY = centerY - dimensions.y / 2
            guard bottomY <= detectedFloorHeight + 0.14 else { return nil }

            return Obstacle(
                identifier: object.identifier,
                transform: object.transform,
                inverseTransform: simd_inverse(object.transform),
                dimensions: dimensions
            )
        }
    }

    /// Intersects an aim ray with the scanned floor and validates enough room
    /// for the car. Returns nil when the player aims outside the usable area.
    func placementPoint(
        rayOrigin: SIMD3<Float>, direction: SIMD3<Float>, clearance: Float = 0.07
    ) -> SIMD3<Float>? {
        guard direction.y < -0.05 else { return nil }
        let distance = (floorHeight - rayOrigin.y) / direction.y
        guard distance > 0, distance < 15 else { return nil }
        var point = rayOrigin + direction * distance
        point.y = floorHeight
        guard isDriveable(point, clearance: clearance) else { return nil }
        return point
    }

    /// Stops a proposed movement at the first floor edge or furniture box.
    func collision(
        from previous: SIMD3<Float>, to proposed: SIMD3<Float>, clearance: Float = 0.035
    ) -> Collision? {
        let point = SIMD2(proposed.x, proposed.z)
        let inside = Self.contains(point, polygon: floorPolygon)
        let closestEdge = Self.closestPointOnPolygon(to: point, polygon: floorPolygon)
        if !inside || simd_distance(point, closestEdge) < clearance {
            let outward = inside ? closestEdge - point : point - closestEdge
            let fallback = SIMD2(proposed.x - previous.x, proposed.z - previous.z)
            let normal2D = Self.normalized(outward, fallback: fallback)
            return Collision(
                position: [previous.x, floorHeight, previous.z],
                normal: [normal2D.x, 0, normal2D.y]
            )
        }

        for obstacle in obstacles {
            guard let normal = obstacleNormal(at: proposed, obstacle: obstacle, clearance: clearance) else {
                continue
            }
            return Collision(
                position: [previous.x, floorHeight, previous.z],
                normal: normal
            )
        }
        return nil
    }

    /// Invisible RoomPlan furniture boxes let real furniture hide the virtual
    /// car even when live scene reconstruction is temporarily incomplete.
    func makeOcclusionRoot() -> Entity {
        let root = Entity()
        for obstacle in obstacles {
            let mesh = MeshResource.generateBox(
                width: obstacle.dimensions.x,
                height: obstacle.dimensions.y,
                depth: obstacle.dimensions.z
            )
            let entity = ModelEntity(mesh: mesh, materials: [OcclusionMaterial()])
            entity.name = "roomObstacle-\(obstacle.identifier.uuidString)"
            entity.transform = Transform(matrix: obstacle.transform)
            root.addChild(entity)
        }
        return root
    }

    private func isDriveable(_ point: SIMD3<Float>, clearance: Float) -> Bool {
        let point2D = SIMD2(point.x, point.z)
        guard Self.contains(point2D, polygon: floorPolygon) else { return false }
        guard simd_distance(
            point2D,
            Self.closestPointOnPolygon(to: point2D, polygon: floorPolygon)
        ) >= clearance else { return false }
        return obstacles.allSatisfy {
            obstacleNormal(at: point, obstacle: $0, clearance: clearance) == nil
        }
    }

    private func obstacleNormal(
        at point: SIMD3<Float>, obstacle: Obstacle, clearance: Float
    ) -> SIMD3<Float>? {
        let local = obstacle.inverseTransform * SIMD4(point.x, point.y, point.z, 1)
        let halfX = obstacle.dimensions.x / 2 + clearance
        let halfZ = obstacle.dimensions.z / 2 + clearance
        guard abs(local.x) < halfX, abs(local.z) < halfZ else { return nil }

        let penetrationX = halfX - abs(local.x)
        let penetrationZ = halfZ - abs(local.z)
        let localNormal: SIMD3<Float>
        if penetrationX < penetrationZ {
            localNormal = [local.x >= 0 ? 1 : -1, 0, 0]
        } else {
            localNormal = [0, 0, local.z >= 0 ? 1 : -1]
        }
        let world = obstacle.transform * SIMD4(localNormal.x, 0, localNormal.z, 0)
        let normal = SIMD3<Float>(world.x, 0, world.z)
        let length = simd_length(normal)
        return length > 1e-5 ? normal / length : nil
    }

    private static func worldCorners(of floor: CapturedRoom.Surface) -> [SIMD3<Float>] {
        var localCorners = floor.polygonCorners
        if localCorners.count < 3 {
            let halfWidth = floor.dimensions.x / 2
            let halfHeight = floor.dimensions.y / 2
            localCorners = [
                [-halfWidth, -halfHeight, 0],
                [halfWidth, -halfHeight, 0],
                [halfWidth, halfHeight, 0],
                [-halfWidth, halfHeight, 0],
            ]
        }
        return localCorners.map { corner in
            let world = floor.transform * SIMD4(corner.x, corner.y, corner.z, 1)
            return SIMD3(world.x, world.y, world.z)
        }
    }

    private static func signedArea(of polygon: [SIMD2<Float>]) -> Float {
        guard polygon.count >= 3 else { return 0 }
        var area: Float = 0
        for index in polygon.indices {
            let next = polygon[(index + 1) % polygon.count]
            area += polygon[index].x * next.y - next.x * polygon[index].y
        }
        return area / 2
    }

    private static func contains(_ point: SIMD2<Float>, polygon: [SIMD2<Float>]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let crossesY = (a.y > point.y) != (b.y > point.y)
            if crossesY {
                let crossingX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossingX { inside.toggle() }
            }
        }
        return inside
    }

    private static func closestPointOnPolygon(
        to point: SIMD2<Float>, polygon: [SIMD2<Float>]
    ) -> SIMD2<Float> {
        var closest = polygon[0]
        var closestDistance = Float.greatestFiniteMagnitude
        for index in polygon.indices {
            let a = polygon[index]
            let b = polygon[(index + 1) % polygon.count]
            let edge = b - a
            let denominator = simd_length_squared(edge)
            let t = denominator > 1e-8
                ? max(0, min(1, simd_dot(point - a, edge) / denominator))
                : 0
            let candidate = a + edge * t
            let distance = simd_distance_squared(point, candidate)
            if distance < closestDistance {
                closest = candidate
                closestDistance = distance
            }
        }
        return closest
    }

    private static func normalized(
        _ vector: SIMD2<Float>, fallback: SIMD2<Float>
    ) -> SIMD2<Float> {
        let length = simd_length(vector)
        if length > 1e-5 { return vector / length }
        let fallbackLength = simd_length(fallback)
        return fallbackLength > 1e-5 ? fallback / fallbackLength : [0, 1]
    }
}
