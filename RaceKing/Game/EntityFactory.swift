//
//  EntityFactory.swift
//  RaceKing
//

import Foundation
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

    static let playerBodyColor = SimpleMaterial.Color(red: 0.9, green: 0.12, blue: 0.15, alpha: 1)
    static let ghostBodyColor = SimpleMaterial.Color(white: 0.9, alpha: 1)

    private static var supportDirectory: URL {
        let directory = URL.applicationSupportDirectory
            .appending(path: "RaceKing", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Where a car model imported from the Files app is kept across launches.
    static var importedCarURL: URL {
        supportDirectory.appending(path: "PlayerCar.usdz")
    }

    /// Imported model for one of the three AI karts (slots 0-2).
    static func importedAICarURL(index: Int) -> URL {
        supportDirectory.appending(path: "AICar\(index + 1).usdz")
    }

    /// Custom model for the player and ghost cars. An imported file wins
    /// over a bundled `PlayerCar.usdz`; nil falls back to the procedural kart.
    static var customCarTemplate: Entity? = {
        if let imported = try? Entity.load(contentsOf: importedCarURL) { return imported }
        return try? Entity.load(named: "PlayerCar")
    }()

    /// A bundled default model for one AI kart (`AICar1-3.usdz`).
    static func bundledAICarTemplate(index: Int) -> Entity? {
        try? Entity.load(named: "AICar\(index + 1)")
    }

    /// Models for the AI karts: an imported file wins over the bundled
    /// default; nil slots fall back to the tinted procedural kart.
    static var aiCarTemplates: [Entity?] = (0..<3).map { index in
        if let imported = try? Entity.load(contentsOf: importedAICarURL(index: index)) {
            return imported
        }
        return bundledAICarTemplate(index: index)
    }

    /// User override for when nose auto-detection guesses wrong; persisted.
    static var customCarFlipped: Bool {
        get { UserDefaults.standard.bool(forKey: "customCarFlipped") }
        set { UserDefaults.standard.set(newValue, forKey: "customCarFlipped") }
    }

    /// A small kart-style car with its nose toward +Z.
    static func makeCar(
        bodyColor: SimpleMaterial.Color = playerBodyColor,
        allowCustomModel: Bool = true
    ) -> Entity {
        let car = Entity()
        populate(car, bodyColor: bodyColor, customTemplate: allowCustomModel ? customCarTemplate : nil)
        return car
    }

    /// Replaces a car's body (custom model or procedural kart) in place,
    /// keeping the entity itself — and therefore its transform — intact.
    static func populate(_ car: Entity, bodyColor: SimpleMaterial.Color, customTemplate: Entity?) {
        for child in Array(car.children) { child.removeFromParent() }
        if let customTemplate {
            car.addChild(normalizedCustomCar(from: customTemplate))
        } else {
            addProceduralKart(to: car, bodyColor: bodyColor)
        }
        addEffectAttachments(to: car)
    }

    /// Clones and normalizes a custom model: ~9.5 cm long, resting on y = 0,
    /// centered, nose toward +Z (after `customCarYawFix`).
    private static func normalizedCustomCar(from template: Entity) -> Entity {
        let model = template.clone(recursive: true)
        let bounds = model.visualBounds(relativeTo: nil)
        let footprint = max(bounds.extents.x, bounds.extents.z)
        let scale = footprint > 0 ? 0.095 / footprint : 1
        // Multiply rather than assign: USD files carry their unit conversion
        // (metersPerUnit) as a root scale that must be preserved.
        model.scale *= SIMD3(repeating: scale)
        model.position = [
            -bounds.center.x * scale, -bounds.min.y * scale, -bounds.center.z * scale,
        ]
        let wrapper = Entity()
        let yaw = detectForwardYaw(of: model) + (customCarFlipped ? .pi : 0)
        wrapper.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        wrapper.addChild(model)
        return wrapper
    }

    /// Guesses the yaw that points an imported car's nose toward +Z by
    /// sampling mesh vertices: the longer horizontal axis is the length,
    /// and the lower of its two ends is assumed to be the nose (cars carry
    /// their cabin and wing height at the rear).
    static func detectForwardYaw(of entity: Entity) -> Float {
        let points = sampleVertices(of: entity)
        guard points.count >= 8 else { return 0 }

        var minPoint = points[0]
        var maxPoint = points[0]
        for point in points {
            minPoint = simd_min(minPoint, point)
            maxPoint = simd_max(maxPoint, point)
        }
        let extents = maxPoint - minPoint
        let lengthAxisIsX = extents.x > extents.z

        // Compare the tallest geometry within the outer 35% of each end.
        let low = lengthAxisIsX ? minPoint.x : minPoint.z
        let high = lengthAxisIsX ? maxPoint.x : maxPoint.z
        let margin = (high - low) * 0.35
        var positiveEndTop = -Float.greatestFiniteMagnitude
        var negativeEndTop = -Float.greatestFiniteMagnitude
        for point in points {
            let along = lengthAxisIsX ? point.x : point.z
            if along > high - margin {
                positiveEndTop = max(positiveEndTop, point.y)
            } else if along < low + margin {
                negativeEndTop = max(negativeEndTop, point.y)
            }
        }
        let noseAtPositiveEnd = positiveEndTop <= negativeEndTop

        if lengthAxisIsX {
            // Map the model's +X (or -X) to the game's +Z forward.
            return noseAtPositiveEnd ? -.pi / 2 : .pi / 2
        }
        return noseAtPositiveEnd ? 0 : .pi
    }

    /// Root-space positions of up to a few hundred vertices per mesh part.
    private static func sampleVertices(of root: Entity) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        func visit(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                for meshModel in model.mesh.contents.models {
                    for part in meshModel.parts {
                        let positions = part.positions.elements
                        let stride = max(1, positions.count / 400)
                        var index = 0
                        while index < positions.count {
                            points.append(entity.convert(position: positions[index], to: root))
                            index += stride
                        }
                    }
                }
            }
            for child in entity.children { visit(child) }
        }
        visit(root)
        return points
    }

    /// A low-poly racing kart built from primitives: wedge nose, wings,
    /// helmeted driver, and two-tone wheels.
    private static func addProceduralKart(to car: Entity, bodyColor: SimpleMaterial.Color) {
        let body = SimpleMaterial(color: bodyColor, roughness: 0.35, isMetallic: false)
        let dark = SimpleMaterial(color: .init(white: 0.08, alpha: 1), roughness: 0.4, isMetallic: false)
        let darkGray = SimpleMaterial(color: .init(white: 0.2, alpha: 1), roughness: 0.5, isMetallic: false)
        let silver = SimpleMaterial(color: .init(white: 0.75, alpha: 1), roughness: 0.25, isMetallic: true)
        let white = SimpleMaterial(color: .white, roughness: 0.4, isMetallic: false)
        let lamp = UnlitMaterial(color: .init(white: 0.98, alpha: 1))

        func part(
            _ mesh: MeshResource, _ material: SimpleMaterial,
            at position: SIMD3<Float>, orientation: simd_quatf? = nil
        ) {
            let entity = ModelEntity(mesh: mesh, materials: [material])
            entity.position = position
            if let orientation { entity.orientation = orientation }
            car.addChild(entity)
        }

        // Chassis plate and main body, with a pitched-down wedge nose.
        part(.generateBox(width: 0.048, height: 0.008, depth: 0.094, cornerRadius: 0.004),
             dark, at: [0, 0.012, 0])
        part(.generateBox(width: 0.04, height: 0.017, depth: 0.058, cornerRadius: 0.006),
             body, at: [0, 0.0255, -0.014])
        part(.generateBox(width: 0.028, height: 0.011, depth: 0.036, cornerRadius: 0.005),
             body, at: [0, 0.021, 0.028],
             orientation: simd_quatf(angle: 0.12, axis: [1, 0, 0]))

        // Front wing, rear wing on struts.
        part(.generateBox(width: 0.05, height: 0.0035, depth: 0.013, cornerRadius: 0.001),
             body, at: [0, 0.0115, 0.044])
        part(.generateBox(width: 0.048, height: 0.003, depth: 0.013, cornerRadius: 0.001),
             body, at: [0, 0.044, -0.041])
        for x: Float in [-0.014, 0.014] {
            part(.generateBox(width: 0.0035, height: 0.012, depth: 0.0035),
                 dark, at: [x, 0.036, -0.041])
        }

        // Cockpit with a helmeted driver.
        part(.generateBox(width: 0.026, height: 0.006, depth: 0.03, cornerRadius: 0.003),
             dark, at: [0, 0.036, -0.008])
        part(.generateSphere(radius: 0.0085), white, at: [0, 0.04, -0.006])
        part(.generateBox(width: 0.012, height: 0.0045, depth: 0.003, cornerRadius: 0.001),
             dark, at: [0, 0.0405, 0.0015])

        // Racing stripe, side pods, exhausts, headlights.
        part(.generateBox(width: 0.009, height: 0.0008, depth: 0.055),
             white, at: [0, 0.0348, -0.014])
        for x: Float in [-0.0235, 0.0235] {
            part(.generateBox(width: 0.009, height: 0.011, depth: 0.034, cornerRadius: 0.003),
                 darkGray, at: [x, 0.017, -0.004])
        }
        let exhaustRotation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        for x: Float in [-0.009, 0.009] {
            part(.generateCylinder(height: 0.009, radius: 0.0028),
                 silver, at: [x, 0.02, -0.049], orientation: exhaustRotation)
        }
        for x: Float in [-0.0085, 0.0085] {
            let light = ModelEntity(
                mesh: .generateBox(width: 0.005, height: 0.004, depth: 0.002, cornerRadius: 0.001),
                materials: [lamp]
            )
            light.position = [x, 0.0215, 0.0465]
            car.addChild(light)
        }

        // Two-tone wheels: black tires with bright hubs, bigger at the rear.
        let axleRotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        let wheels: [(x: Float, z: Float, radius: Float, width: Float)] = [
            (-0.026, -0.032, 0.0125, 0.011), (0.026, -0.032, 0.0125, 0.011),
            (-0.0245, 0.031, 0.0105, 0.010), (0.0245, 0.031, 0.0105, 0.010),
        ]
        for wheel in wheels {
            part(.generateCylinder(height: wheel.width, radius: wheel.radius),
                 dark, at: [wheel.x, wheel.radius, wheel.z], orientation: axleRotation)
            part(.generateCylinder(height: wheel.width + 0.0006, radius: wheel.radius * 0.48),
                 silver, at: [wheel.x, wheel.radius, wheel.z], orientation: axleRotation)
        }
    }

    /// Drift underglow and boost flame, toggled by the game via their names.
    private static func addEffectAttachments(to car: Entity) {
        let glowMesh = MeshResource.generatePlane(width: 0.06, depth: 0.11, cornerRadius: 0.02)
        let glowColors: [(name: String, color: SimpleMaterial.Color)] = [
            ("glowBlue", .init(red: 0.25, green: 0.6, blue: 1.0, alpha: 1)),
            ("glowOrange", .init(red: 1.0, green: 0.55, blue: 0.1, alpha: 1)),
        ]
        for glow in glowColors {
            let entity = ModelEntity(mesh: glowMesh, materials: [UnlitMaterial(color: glow.color)])
            entity.name = glow.name
            entity.position.y = 0.005
            entity.isEnabled = false
            car.addChild(entity)
        }
        let flame = ModelEntity(
            mesh: .generateBox(width: 0.014, height: 0.012, depth: 0.03, cornerRadius: 0.005),
            materials: [UnlitMaterial(color: .init(red: 1.0, green: 0.55, blue: 0.1, alpha: 1))]
        )
        flame.name = "boostFlame"
        flame.position = [0, 0.02, -0.058]
        flame.isEnabled = false
        car.addChild(flame)
    }

    /// Grass-colored ground for platforms without AR passthrough
    /// (macOS, simulator), where the real floor is not visible.
    static func makeFallbackGround() -> Entity {
        let grass = SimpleMaterial(color: .init(red: 0.2, green: 0.45, blue: 0.2, alpha: 1), roughness: 1, isMetallic: false)
        // Large enough that the camera never sees past its horizon,
        // even on tall iPad aspect ratios.
        return ModelEntity(
            mesh: .generatePlane(width: 60, depth: 60),
            materials: [grass]
        )
    }
}
