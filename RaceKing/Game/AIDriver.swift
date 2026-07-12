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
    let entity: Entity
    let topSpeed: Float
    private(set) var lapCount = 0
    var finished = false
    /// Accumulated distance along the track, for live ranking.
    private(set) var progress: Float = 0

    private var physics = CarPhysics()
    private var nextCheckpoint = 1
    private var trackS: Float = 0

    init(bodyColor: SimpleMaterial.Color, topSpeed: Float) {
        // AI karts stay procedural so each keeps its own tint even when a
        // custom PlayerCar.usdz is installed.
        entity = EntityFactory.makeCar(bodyColor: bodyColor, allowCustomModel: false)
        self.topSpeed = topSpeed
    }

    static func defaultOpponents() -> [AIDriver] {
        [
            AIDriver(bodyColor: .init(red: 0.2, green: 0.4, blue: 0.95, alpha: 1), topSpeed: 0.63),
            AIDriver(bodyColor: .init(red: 0.15, green: 0.7, blue: 0.3, alpha: 1), topSpeed: 0.60),
            AIDriver(bodyColor: .init(red: 0.95, green: 0.65, blue: 0.1, alpha: 1), topSpeed: 0.575),
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
        entity.position += physics.step(
            dt: dt, steeringInput: steering, throttle: true, brake: false,
            offRoad: offRoad, topSpeed: topSpeed
        )
        entity.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])

        // The walls stop AI karts too (e.g. when shoved by another kart).
        let offset = layout.signedOffset(entity.position)
        let limit = layout.corridorLimit
        if abs(offset) > limit {
            let normal = layout.lateralNormal(at: entity.position)
            entity.position += normal * (max(-limit, min(limit, offset)) - offset)
            _ = physics.hitWall(normal: normal)
        }
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
