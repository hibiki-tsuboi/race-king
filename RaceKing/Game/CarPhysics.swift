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

    var speed: Float = 0
    var heading: Float = 0
    private var steering: Float = 0

    var forward: SIMD3<Float> { [sin(heading), 0, cos(heading)] }

    mutating func reset(heading newHeading: Float) {
        speed = 0
        steering = 0
        heading = newHeading
    }

    /// Integrates one step and returns the movement delta.
    mutating func step(
        dt: Float, steeringInput: Float, throttle: Bool, brake: Bool,
        offRoad: Bool, topSpeed: Float = CarPhysics.maxSpeed
    ) -> SIMD3<Float> {
        // Ease the wheel toward the input so steering isn't twitchy.
        steering += (steeringInput - steering) * min(1, dt * 10)

        if throttle { speed += Self.acceleration * dt }
        if brake {
            speed -= (speed > 0 ? Self.brakeDeceleration : Self.reverseAcceleration) * dt
        }

        // The road has grip; leaving it slows the car down hard.
        var drag = Self.rollingDrag
        if offRoad { drag += Self.offRoadDrag }
        speed -= drag * speed * dt
        speed = max(-Self.maxReverseSpeed, min(speed, topSpeed))

        // Yaw response grows with speed so the car can't pivot in place;
        // in reverse it flips, like a real car backing up.
        let ratio = min(1, abs(speed) / Self.maxSpeed)
        let grip = (0.25 + 0.75 * ratio) * (speed < 0 ? -1 : 1)
        heading -= steering * 2.8 * grip * dt
        return forward * speed * dt
    }

    /// Scrubs off speed when hitting a wall: a glancing touch barely slows
    /// the car, a head-on hit nearly stops it. Returns impact 0...1.
    mutating func hitWall(normal: SIMD3<Float>) -> Float {
        let impact = abs(simd_dot(forward, normal))
        speed *= max(0, 1 - 0.9 * impact)
        return impact
    }
}
