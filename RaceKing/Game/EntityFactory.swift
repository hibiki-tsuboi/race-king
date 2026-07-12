//
//  EntityFactory.swift
//  RaceKing
//

import RealityKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Builds the visual entities for the game. All models face +Z as "forward".
enum EntityFactory {
    /// A circuit made of flat road segments, alternating red/white curbs,
    /// and a checkered start/finish line.
    static func makeTrack(layout: TrackLayout) -> Entity {
        let track = Entity()
        let segments = 96
        let segmentLength = layout.totalLength / Float(segments)

        let asphalt = SimpleMaterial(color: .init(white: 0.15, alpha: 1), roughness: 0.9, isMetallic: false)
        let red = SimpleMaterial(color: .init(red: 0.85, green: 0.1, blue: 0.1, alpha: 1), roughness: 0.6, isMetallic: false)
        let white = SimpleMaterial(color: .white, roughness: 0.6, isMetallic: false)
        let black = SimpleMaterial(color: .init(white: 0.05, alpha: 1), roughness: 0.8, isMetallic: false)

        // Slightly overlapping boxes along the centerline form the road surface.
        let roadMesh = MeshResource.generateBox(
            width: layout.roadWidth, height: 0.002, depth: segmentLength * 1.35
        )
        let curbMesh = MeshResource.generateBox(
            width: 0.018, height: 0.0035, depth: segmentLength * 1.35
        )
        // Walls need extra overlap: the outer corner arc is longer than the
        // centerline arc, so segments spread apart there.
        let wallMesh = MeshResource.generateBox(
            width: 0.008, height: 0.018, depth: segmentLength * 1.8
        )
        let barrier = SimpleMaterial(color: .init(white: 0.92, alpha: 1), roughness: 0.5, isMetallic: false)
        for i in 0..<segments {
            let s = (Float(i) + 0.5) * segmentLength
            let (position, tangent) = layout.sample(at: s)
            let rotation = simd_quatf(angle: TrackLayout.heading(of: tangent), axis: [0, 1, 0])

            let piece = ModelEntity(mesh: roadMesh, materials: [asphalt])
            piece.position = position + [0, 0.001, 0]
            piece.orientation = rotation
            track.addChild(piece)

            let right = rotation.act([1, 0, 0])
            for side: Float in [-1, 1] {
                let curb = ModelEntity(mesh: curbMesh, materials: [i.isMultiple(of: 2) ? red : white])
                curb.position = position + right * (layout.roadWidth / 2) * side + [0, 0.0018, 0]
                curb.orientation = rotation
                track.addChild(curb)

                let wall = ModelEntity(mesh: wallMesh, materials: [barrier])
                wall.position = position + right * layout.wallOffset * side + [0, 0.009, 0]
                wall.orientation = rotation
                track.addChild(wall)
            }
        }

        // Checkered start/finish line across the road.
        let start = layout.sample(at: layout.startOffset)
        let startRotation = simd_quatf(angle: TrackLayout.heading(of: start.tangent), axis: [0, 1, 0])
        let cells = 8
        let cellSize = layout.roadWidth / Float(cells)
        let cellMesh = MeshResource.generateBox(width: cellSize, height: 0.0026, depth: cellSize)
        for row in 0..<2 {
            for column in 0..<cells {
                let cell = ModelEntity(
                    mesh: cellMesh,
                    materials: [(row + column).isMultiple(of: 2) ? white : black]
                )
                let localX = (Float(column) + 0.5) * cellSize - layout.roadWidth / 2
                let localZ = (Float(row) + 0.5) * cellSize - cellSize
                cell.position = start.position + startRotation.act([localX, 0.0022, localZ])
                cell.orientation = startRotation
                track.addChild(cell)
            }
        }
        return track
    }

    /// A small kart-style car with its nose toward +Z.
    static func makeCar(
        bodyColor: SimpleMaterial.Color = .init(red: 0.9, green: 0.12, blue: 0.15, alpha: 1)
    ) -> Entity {
        let car = Entity()
        let body = SimpleMaterial(color: bodyColor, roughness: 0.35, isMetallic: false)
        let dark = SimpleMaterial(color: .init(white: 0.08, alpha: 1), roughness: 0.4, isMetallic: false)

        let chassis = ModelEntity(
            mesh: .generateBox(width: 0.045, height: 0.02, depth: 0.095, cornerRadius: 0.006),
            materials: [body]
        )
        chassis.position.y = 0.02
        car.addChild(chassis)

        let cabin = ModelEntity(
            mesh: .generateBox(width: 0.034, height: 0.016, depth: 0.036, cornerRadius: 0.005),
            materials: [dark]
        )
        cabin.position = [0, 0.036, -0.008]
        car.addChild(cabin)

        let spoiler = ModelEntity(
            mesh: .generateBox(width: 0.042, height: 0.004, depth: 0.012),
            materials: [body]
        )
        spoiler.position = [0, 0.041, -0.045]
        car.addChild(spoiler)

        let wheelMesh = MeshResource.generateCylinder(height: 0.009, radius: 0.011)
        let axleRotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        for x: Float in [-0.024, 0.024] {
            for z: Float in [-0.032, 0.03] {
                let wheel = ModelEntity(mesh: wheelMesh, materials: [dark])
                wheel.position = [x, 0.011, z]
                wheel.orientation = axleRotation
                car.addChild(wheel)
            }
        }
        return car
    }

    /// Grass-colored ground for platforms without AR passthrough
    /// (macOS, simulator), where the real floor is not visible.
    static func makeFallbackGround() -> Entity {
        let grass = SimpleMaterial(color: .init(red: 0.2, green: 0.45, blue: 0.2, alpha: 1), roughness: 1, isMetallic: false)
        return ModelEntity(
            mesh: .generatePlane(width: 12, depth: 12),
            materials: [grass]
        )
    }
}
