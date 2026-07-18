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

/// A computer-controlled kart that chases a lookahead point near the
/// centerline (pure pursuit). Each kart rerolls a personality per race —
/// pace, preferred lane, cornering caution, and drift use — so the field
/// spreads out instead of running the identical line in a queue.
final class AIDriver {
    private static let curvatureSampleDistance: Float = 0.03
    private static let minimumCornerPreviewDistance: Float = 0.18
    /// Top-speed tiers dealt out (shuffled) across the field each race.
    private static let racePaceTiers: [Float] = [0.635, 0.605, 0.578, 0.552]

    let entity: Entity
    private(set) var topSpeed: Float
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

    // MARK: - Per-race personality (rerolled by `place`)

    /// Pure-pursuit lookahead; shorter hugs corners tighter.
    private var pursuitDistance: Float = 0.16
    /// Fraction of the physically possible corner speed this kart dares.
    private var cornerCaution: Float = 0.96
    /// Preferred lateral offset from the centerline — the kart's lane.
    private var lineOffset: Float = 0
    private var wanderAmplitude: Float = 0
    private var wanderRate: Float = 0
    private var wanderPhase: Float = 0
    private var wanderClock: Float = 0
    private var usesDrift = false
    /// Seconds between drifts; eager karts slide every corner, casual ones
    /// only now and then, so drifting doesn't flatten the pace tiers.
    private var driftRestBase: Float = 2
    private var driftRelease: Float = 0
    private var driftCooldown: Float = 0

    private var glowBlue: Entity?
    private var glowOrange: Entity?
    private var boostFlame: Entity?

    init(index: Int, bodyColor: SimpleMaterial.Color, topSpeed: Float) {
        self.bodyColor = bodyColor
        self.topSpeed = topSpeed
        entity = Entity()
        let template = EntityFactory.aiCarTemplates.indices.contains(index)
            ? EntityFactory.aiCarTemplates[index] : nil
        EntityFactory.populate(entity, bodyColor: bodyColor, customTemplate: template)
        cacheEffectEntities()
    }

    /// Swaps this kart's body for an imported model (nil = tinted kart).
    func applyModel(_ template: Entity?) {
        EntityFactory.populate(entity, bodyColor: bodyColor, customTemplate: template)
        cacheEffectEntities()
    }

    private func cacheEffectEntities() {
        glowBlue = entity.findEntity(named: "glowBlue")
        glowOrange = entity.findEntity(named: "glowOrange")
        boostFlame = entity.findEntity(named: "boostFlame")
    }

    /// Deals a shuffled speed tier (plus a small jitter) to every kart so a
    /// different opponent can set the pace each race.
    static func rollRacePaces(for drivers: [AIDriver]) {
        let tiers = racePaceTiers.shuffled()
        for (index, driver) in drivers.enumerated() {
            driver.topSpeed = tiers[index % tiers.count]
                + .random(in: -0.012...0.012)
        }
    }

    static func defaultOpponents() -> [AIDriver] {
        [
            AIDriver(index: 0, bodyColor: .init(red: 0.9, green: 0.12, blue: 0.15, alpha: 1), topSpeed: 0.63),
            AIDriver(index: 1, bodyColor: .init(red: 0.2, green: 0.45, blue: 0.95, alpha: 1), topSpeed: 0.60),
            AIDriver(index: 2, bodyColor: .init(white: 0.9, alpha: 1), topSpeed: 0.575),
            AIDriver(index: 3, bodyColor: .init(red: 0.95, green: 0.72, blue: 0.08, alpha: 1), topSpeed: 0.55),
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
        rollPersonality()
    }

    /// Rerolls how this kart drives; runs for every grid placement.
    private func rollPersonality() {
        pursuitDistance = .random(in: 0.13...0.19)
        cornerCaution = .random(in: 0.90...1.0)
        lineOffset = .random(in: -0.045...0.045)
        wanderAmplitude = .random(in: 0.004...0.016)
        wanderRate = .random(in: 0.5...1.1)
        wanderPhase = .random(in: 0...(2 * .pi))
        wanderClock = 0
        usesDrift = Bool.random()
        driftRestBase = .random(in: 0.7...3.5)
        driftRelease = 0
        driftCooldown = 0
        glowBlue?.isEnabled = false
        glowOrange?.isEnabled = false
        boostFlame?.isEnabled = false
    }

    func drive(dt: Float, layout: TrackLayout) {
        let p = entity.position
        let s = layout.nearestS(to: p, near: trackS)
        progress += layout.progressDelta(from: trackS, to: s)
        trackS = s
        wanderClock += dt

        // Chase a point in this kart's lane: the preferred offset plus a slow
        // wander, so the field spreads across the road instead of queueing.
        let ahead = layout.sample(at: s + pursuitDistance)
        let lane = lineOffset
            + wanderAmplitude * sin(wanderPhase + wanderClock * wanderRate)
        let side = SIMD3<Float>(-ahead.tangent.z, 0, ahead.tangent.x)
        let target = ahead.position + side * lane
        let to = SIMD2(target.x - p.x, target.z - p.z)
        let forward = SIMD2(sin(physics.heading), cos(physics.heading))
        // 2D cross product; positive when the target is to the kart's right.
        let cross = forward.x * to.y - forward.y * to.x
        let steering = max(-1, min(1, 4 * cross / max(0.001, simd_length(to))))

        let offRoad = layout.distanceFromCenterline(p) > layout.roadWidth / 2 + 0.015
        let targetSpeed = targetSpeed(at: s, layout: layout)
        updateDrift(dt: dt, steering: steering, targetSpeed: targetSpeed)
        // A kart about to drift carries extra speed into the corner (like a
        // player who skips braking) and lets the slide shed it instead.
        var speedTarget = targetSpeed
        if usesDrift, !physics.isDrifting, driftCooldown <= 0,
           targetSpeed < topSpeed - 0.02 {
            speedTarget = max(targetSpeed, CarPhysics.driftMinSpeed + 0.14)
        }
        let brake = !physics.isDrifting && physics.speed > speedTarget + 0.015
        let throttle = physics.isDrifting
            || (!brake && physics.speed < speedTarget + 0.005)
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
            // Slamming a wall kills the drift without a reward, like the player.
            if physics.isDrifting {
                physics.endDrift(rewardBoost: false)
                driftCooldown = 1.2
            }
            touchingWall = true
        } else {
            touchingWall = false
        }

        glowBlue?.isEnabled = physics.isDrifting && physics.chargeLevel == 1
        glowOrange?.isEnabled = physics.isDrifting && physics.chargeLevel >= 2
        boostFlame?.isEnabled = physics.isBoosting
    }

    /// Kart-style drifting: kick into a meaningful corner, hold the slide
    /// while it keeps turning, then straighten and cash the mini-turbo.
    private func updateDrift(dt: Float, steering: Float, targetSpeed: Float) {
        driftCooldown -= dt
        guard usesDrift else { return }
        let cornering = targetSpeed < topSpeed - 0.02

        guard physics.isDrifting else {
            if cornering, driftCooldown <= 0, abs(steering) > 0.45,
               physics.speed > CarPhysics.driftMinSpeed + 0.08, !touchingWall {
                physics.startDrift(direction: steering > 0 ? 1 : -1)
                driftRelease = 0
            }
            return
        }

        if physics.speed < CarPhysics.driftMinSpeed {
            physics.endDrift(rewardBoost: false)
            driftCooldown = 1.0
            return
        }
        // Unlike the player's steering-release rule, pure pursuit constantly
        // counter-steers mid-slide, so the AI holds the drift until the
        // corner itself opens up, then straightens and takes the boost.
        if cornering {
            driftRelease = 0
        } else {
            driftRelease += dt
            if driftRelease > 0.1 {
                physics.endDrift(rewardBoost: true)
                driftCooldown = driftRestBase * .random(in: 0.7...1.3)
            }
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
        ) * cornerCaution
        return min(topSpeed, cornerSpeed)
    }

    /// Returns the within-step fraction when the kart just completed a lap.
    func updateLap(
        from previousPosition: SIMD3<Float>, layout: TrackLayout,
        checkpoints: [SIMD3<Float>], radius: Float
    ) -> Float? {
        guard let crossingFraction = RaceGame.advanceCheckpoint(
            &nextCheckpoint,
            from: previousPosition,
            to: entity.position,
            checkpoints: checkpoints,
            radius: radius,
            layout: layout
        ) else { return nil }
        lapCount += 1
        return crossingFraction
    }
}
