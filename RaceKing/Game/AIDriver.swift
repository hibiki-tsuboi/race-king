//
//  AIDriver.swift
//  RaceKing
//

import Foundation
import RealityKit
import simd
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A computer-controlled kart that chases a lookahead point on the centerline
/// (pure pursuit). Each opponent has a different top speed for variety.
final class AIDriver {
    private static let curvatureSampleDistance: Float = 0.03
    private static let minimumCornerPreviewDistance: Float = 0.18
    private static let cornerSpeedSafetyFactor: Float = 0.96

    let entity: Entity
    let topSpeed: Float
    /// Tint of the procedural kart, kept for reverting a custom model.
    let bodyColor: SimpleMaterial.Color
    private(set) var lapCount = 0
    var finished = false
    /// Accumulated distance along the track, for live ranking.
    private(set) var progress: Float = 0

    private var physics = CarPhysics()
    private var nextCheckpoint = 1
    private var trackS: Float = 0
    private var touchingWall = false

    init(index: Int, bodyColor: SimpleMaterial.Color, topSpeed: Float) {
        self.bodyColor = bodyColor
        self.topSpeed = topSpeed
        entity = Entity()
        let template = EntityFactory.aiCarTemplates.indices.contains(index)
            ? EntityFactory.aiCarTemplates[index] : nil
        EntityFactory.populate(entity, bodyColor: bodyColor, customTemplate: template)
    }

    /// Swaps this kart's body for an imported model (nil = tinted kart).
    func applyModel(_ template: Entity?) {
        EntityFactory.populate(entity, bodyColor: bodyColor, customTemplate: template)
    }

    static func defaultOpponents() -> [AIDriver] {
        [
            AIDriver(index: 0, bodyColor: .init(red: 0.2, green: 0.4, blue: 0.95, alpha: 1), topSpeed: 0.63),
            AIDriver(index: 1, bodyColor: .init(red: 0.15, green: 0.7, blue: 0.3, alpha: 1), topSpeed: 0.60),
            AIDriver(index: 2, bodyColor: .init(red: 0.95, green: 0.65, blue: 0.1, alpha: 1), topSpeed: 0.575),
        ]
    }

    /// Puts the kart on its grid slot, `back` meters behind the start line.
    func place(back: Float, lateral: Float, layout: TrackLayout) {
        let s = layout.startOffset - back
        let grid = layout.sample(at: s)
        let side = SIMD3<Float>(-grid.tangent.z, 0, grid.tangent.x)
        entity.position = grid.position + side * lateral
        physics.reset(heading: TrackLayout.heading(of: grid.tangent))
        entity.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])
        lapCount = 0
        nextCheckpoint = 1
        finished = false
        progress = 0
        trackS = layout.nearestS(to: entity.position, near: s)
        touchingWall = false
    }

    func drive(dt: Float, layout: TrackLayout) {
        let p = entity.position
        let s = layout.nearestS(to: p, near: trackS)
        progress += layout.progressDelta(from: trackS, to: s)
        trackS = s

        let target = layout.sample(at: s + 0.16).position
        let to = SIMD2(target.x - p.x, target.z - p.z)
        let forward = SIMD2(sin(physics.heading), cos(physics.heading))
        // 2D cross product; positive when the target is to the kart's right.
        let cross = forward.x * to.y - forward.y * to.x
        let steering = max(-1, min(1, 4 * cross / max(0.001, simd_length(to))))

        let offRoad = layout.distanceFromCenterline(p) > layout.roadWidth / 2 + 0.015
        let targetSpeed = targetSpeed(at: s, layout: layout)
        let brake = physics.speed > targetSpeed + 0.015
        let throttle = !brake && physics.speed < targetSpeed + 0.005
        let movement = physics.step(
            dt: dt, steeringInput: steering, throttle: throttle, brake: brake,
            offRoad: offRoad, topSpeed: topSpeed
        )
        entity.position += movement
        entity.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])

        // The walls stop AI karts too (e.g. when shoved by another kart).
        let offset = layout.signedOffset(entity.position)
        let limit = layout.corridorLimit
        if abs(offset) > limit {
            let normal = layout.lateralNormal(at: entity.position)
            entity.position += normal * (max(-limit, min(limit, offset)) - offset)
            if !touchingWall {
                _ = physics.hitWall(normal: normal, travel: movement)
            }
            touchingWall = true
        } else {
            touchingWall = false
        }
    }

    /// Looks far enough ahead to brake before the tightest upcoming curve.
    private func targetSpeed(at s: Float, layout: TrackLayout) -> Float {
        let previewDistance = max(
            Self.minimumCornerPreviewDistance,
            min(0.26, abs(physics.speed) * 0.35)
        )
        let sampleCount = max(
            1,
            Int(ceil(previewDistance / Self.curvatureSampleDistance))
        )
        let sampleDistance = previewDistance / Float(sampleCount)
        var previousTangent = layout.sample(at: s).tangent
        var maximumCurvature: Float = 0

        for sample in 1...sampleCount {
            let distance = Float(sample) * sampleDistance
            let tangent = layout.sample(at: s + distance).tangent
            let alignment = max(-1, min(1, simd_dot(previousTangent, tangent)))
            maximumCurvature = max(
                maximumCurvature,
                acos(alignment) / sampleDistance
            )
            previousTangent = tangent
        }

        guard maximumCurvature > 0.05 else { return topSpeed }
        let radius = 1 / maximumCurvature
        let cornerSpeed = CarPhysics.maximumCorneringSpeed(
            radius: radius,
            underPower: true
        ) * Self.cornerSpeedSafetyFactor
        return min(topSpeed, cornerSpeed)
    }

    /// Returns true when the kart just completed a lap.
    func updateLap(checkpoints: [SIMD3<Float>], radius: Float) -> Bool {
        guard RaceGame.advanceCheckpoint(
            &nextCheckpoint, position: entity.position, checkpoints: checkpoints,
            radius: radius
        ) else { return false }
        lapCount += 1
        return true
    }
}
