//
//  CarPhysics.swift
//  RaceKing
//

import simd

/// Arcade car physics shared by the player and AI drivers.
struct CarPhysics {
    static let maxSpeed: Float = 0.65
    static let acceleration: Float = 0.55
    static let brakeDeceleration: Float = 1.4
    /// Holding the brake past a standstill backs the car up, gently.
    static let reverseAcceleration: Float = 0.5
    static let maxReverseSpeed: Float = 0.22
    static let rollingDrag: Float = 0.35
    static let offRoadDrag: Float = 2.2
    static let driftDrag: Float = 0.35
    /// Below this speed a drift cannot start (or survive).
    static let driftMinSpeed: Float = 0.3
    /// Seconds of drifting to charge mini-turbo level 1 (blue) and 2 (orange).
    /// A corner on this track takes roughly half a second of sliding.
    static let chargeLevel1: Float = 0.45
    static let chargeLevel2: Float = 1.2

    var speed: Float = 0
    var heading: Float = 0
    private var steering: Float = 0

    // MARK: - Drift state

    private(set) var isDrifting = false
    /// +1 while drifting right, -1 left. Keeps its last value after a drift
    /// ends so the slip angle can ease back to zero on the same side.
    private(set) var driftDirection: Float = 0
    private(set) var driftCharge: Float = 0
    private var slip: Float = 0
    private var boostTimer: Float = 0

    var isBoosting: Bool { boostTimer > 0 }
    /// Mini-turbo tier charged so far: 0 none, 1 blue, 2 orange.
    var chargeLevel: Int {
        if driftCharge >= Self.chargeLevel2 { return 2 }
        if driftCharge >= Self.chargeLevel1 { return 1 }
        return 0
    }

    var forward: SIMD3<Float> { [sin(heading), 0, cos(heading)] }

    mutating func reset(heading newHeading: Float) {
        speed = 0
        steering = 0
        heading = newHeading
        isDrifting = false
        driftDirection = 0
        driftCharge = 0
        slip = 0
        boostTimer = 0
    }

    mutating func startDrift(direction: Float) {
        isDrifting = true
        driftDirection = direction
        driftCharge = 0
        // The kick into the slide bites off a little speed.
        speed *= 0.9
    }

    /// Ends the drift and returns the mini-turbo level fired (0 = none).
    @discardableResult
    mutating func endDrift(rewardBoost: Bool) -> Int {
        guard isDrifting else { return 0 }
        let level = chargeLevel
        isDrifting = false
        driftCharge = 0
        guard rewardBoost, level > 0 else { return 0 }
        boostTimer = level == 2 ? 1.4 : 0.7
        return level
    }

    /// Integrates one step and returns the movement delta.
    mutating func step(
        dt: Float, steeringInput: Float, throttle: Bool, brake: Bool,
        offRoad: Bool, topSpeed: Float = CarPhysics.maxSpeed
    ) -> SIMD3<Float> {
        // Ease the wheel toward the input so steering isn't twitchy.
        steering += (steeringInput - steering) * min(1, dt * 10)

        var effectiveTop = topSpeed
        if boostTimer > 0 {
            boostTimer -= dt
            effectiveTop = topSpeed * 1.28
            speed += 1.5 * dt
        }
        if throttle { speed += Self.acceleration * dt }
        if brake {
            speed -= (speed > 0 ? Self.brakeDeceleration : Self.reverseAcceleration) * dt
        }

        // The road has grip; leaving it slows the car down hard, and a
        // sliding car scrubs some speed too.
        var drag = Self.rollingDrag
        if offRoad { drag += Self.offRoadDrag }
        if isDrifting { drag += Self.driftDrag }
        speed -= drag * speed * dt
        if boostTimer > 0 {
            // The boost cap is a hard ceiling while it lasts.
            speed = min(speed, effectiveTop)
        } else if speed > effectiveTop {
            // After the boost expires, bleed the excess instead of snapping.
            speed = max(effectiveTop, speed - 1.0 * dt)
        }
        speed = max(-Self.maxReverseSpeed, speed)

        let ratio = min(1, abs(speed) / Self.maxSpeed)
        if isDrifting {
            driftCharge += dt
            // Steering picks the drift line between shallow (counter-steer)
            // and tight (full inside); it always keeps rotating some.
            let inward = max(-1, min(1, steering * driftDirection))
            let grip = 0.25 + 0.75 * ratio
            let newSlip = slip + (0.25 - slip) * min(1, dt * 4)
            // The nose rotates ahead by the growing slip angle while the
            // travel direction follows the steered arc, so kicking the tail
            // out doesn't push the car wide at corner entry.
            heading -= driftDirection
                * (3.8 * grip * (0.45 + 0.55 * inward) * dt + (newSlip - slip))
            slip = newSlip
        } else {
            // Yaw comes from rolling: it grows with speed, fades to zero at
            // a standstill (a parked car can't pivot), and flips in reverse
            // like a real car backing up.
            let rolling = min(1, abs(speed) / 0.1)
            let grip = (0.25 + 0.75 * ratio) * rolling * (speed < 0 ? -1 : 1)
            heading -= steering * 2.8 * grip * dt
            // Grip catches again: the travel direction converges onto the nose.
            slip += (0 - slip) * min(1, dt * 4)
        }

        // While sliding, the car travels wider than its nose points.
        let travelHeading = heading + driftDirection * slip
        return SIMD3(sin(travelHeading), 0, cos(travelHeading)) * speed * dt
    }

    /// Scrubs off speed when hitting a wall: a glancing touch barely slows
    /// the car, a head-on hit nearly stops it. Returns impact 0...1.
    mutating func hitWall(normal: SIMD3<Float>) -> Float {
        let impact = abs(simd_dot(forward, normal))
        speed *= max(0, 1 - 0.9 * impact)
        return impact
    }

    /// Nudges a forward-moving car toward the course direction after it hits
    /// a guardrail. Glancing contacts get a subtle correction, while a
    /// head-on impact turns the car far enough to prevent repeated collisions.
    mutating func assistAlongGuardrail(
        trackTangent: SIMD3<Float>, impact: Float
    ) {
        guard speed > 0, impact > 0.05 else { return }

        let targetHeading = atan2(trackTangent.x, trackTangent.z)
        let angleDelta = atan2(
            sin(targetHeading - heading),
            cos(targetHeading - heading)
        )
        // Do not interfere when the player is deliberately facing backward.
        guard abs(angleDelta) < .pi * 0.6 else { return }

        let correction = min(0.85, 0.15 + 0.7 * impact)
        heading += angleDelta * correction
        slip *= 1 - correction
    }
}
