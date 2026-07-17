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
    /// Model-space lateral acceleration available before the tires push wide.
    static let maximumLateralAcceleration: Float = 0.75
    /// Acceleration shifts grip away from turning, but keeps the effect forgiving.
    private static let poweredLateralGripMultiplier: Float = 0.88
    private static let brakingLateralGripMultiplier: Float = 0.92
    private static let tireScrubDrag: Float = 0.45
    private static let maximumUndersteerSlip: Float = 0.16
    /// Below this speed a drift cannot start (or survive).
    static let driftMinSpeed: Float = 0.3
    /// Seconds of drifting to charge mini-turbo level 1 (blue) and 2 (orange).
    /// A corner on this track takes roughly half a second of sliding.
    static let chargeLevel1: Float = 0.45
    static let chargeLevel2: Float = 1.2

    var speed: Float = 0
    var heading: Float = 0
    private var steering: Float = 0
    private var understeerSlip: Float = 0

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

    /// Fastest steady speed that can hold a turn of `radius` without sliding.
    static func maximumCorneringSpeed(radius: Float, underPower: Bool) -> Float {
        let grip = maximumLateralAcceleration
            * (underPower ? poweredLateralGripMultiplier : 1)
        return sqrt(max(0, grip * radius))
    }

    mutating func reset(heading newHeading: Float) {
        speed = 0
        steering = 0
        heading = newHeading
        isDrifting = false
        driftDirection = 0
        driftCharge = 0
        slip = 0
        understeerSlip = 0
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

    /// Cancels an already-fired mini-turbo without changing the car's momentum.
    mutating func cancelBoost() {
        boostTimer = 0
    }

    /// Integrates one step and returns the movement delta.
    mutating func step(
        dt: Float, steeringInput: Float, throttle: Bool, brake: Bool,
        offRoad: Bool, topSpeed: Float = CarPhysics.maxSpeed
    ) -> SIMD3<Float> {
        // High-speed turn-in is deliberate while releasing the control recenters
        // quickly, so a short digital tap adjusts the line instead of snapping it.
        let steeringSpeedRatio = min(1, abs(speed) / Self.maxSpeed)
        let isRecentering = abs(steeringInput) < abs(steering)
        let steeringResponse = isRecentering ? 16 : 10 - 4 * steeringSpeedRatio
        steering += (steeringInput - steering) * min(1, dt * steeringResponse)

        var effectiveTop = topSpeed
        if boostTimer > 0 {
            boostTimer -= dt
            effectiveTop = topSpeed * 1.28
            speed += 1.5 * dt
        }
        if throttle { speed += Self.acceleration * dt }
        if brake {
            if speed > 0 {
                // Braking may reach a standstill, but never crosses through it
                // in one integration step. A subsequent held step starts reverse.
                speed = max(0, speed - Self.brakeDeceleration * dt)
            } else {
                speed -= Self.reverseAcceleration * dt
            }
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
            // Cars face +Z, so a right turn is a negative yaw around +Y.
            // Positive steering still means right to every input source.
            heading -= driftDirection
                * (3.8 * grip * (0.45 + 0.55 * inward) * dt + (newSlip - slip))
            slip = newSlip
            understeerSlip += (0 - understeerSlip) * min(1, dt * 8)
        } else {
            // The wheel requests a yaw rate, but finite lateral tire grip caps
            // it at speed. Excess steering becomes understeer instead of making
            // the car rotate ever more sharply.
            let rolling = min(1, abs(speed) / 0.1)
            let grip = (0.25 + 0.75 * ratio) * rolling * (speed < 0 ? -1 : 1)
            let requestedYawRate = steering * 2.8 * grip
            var lateralLimit = Self.maximumLateralAcceleration
            if throttle { lateralLimit *= Self.poweredLateralGripMultiplier }
            if brake { lateralLimit *= Self.brakingLateralGripMultiplier }

            let maximumYawRate = lateralLimit / max(0.001, abs(speed))
            let yawRate = max(-maximumYawRate, min(maximumYawRate, requestedYawRate))
            heading -= yawRate * dt

            let requestedLateralAcceleration = abs(speed * requestedYawRate)
            let overload = max(0, requestedLateralAcceleration / lateralLimit - 1)
            let slipTarget = min(
                Self.maximumUndersteerSlip,
                overload * 0.12
            ) * (steering >= 0 ? 1 : -1)
            understeerSlip += (slipTarget - understeerSlip) * min(1, dt * 6)

            // Sliding tires scrub speed, but not enough to auto-brake a badly
            // overdriven corner back onto the racing line.
            let scrubDrag = Self.tireScrubDrag * min(1, overload)
            speed -= scrubDrag * speed * dt
            // Grip catches again: the travel direction converges onto the nose.
            slip += (0 - slip) * min(1, dt * 4)
        }

        // Drift and understeer both make the car travel wider than its nose.
        let travelHeading = heading + driftDirection * slip + understeerSlip
        return SIMD3(sin(travelHeading), 0, cos(travelHeading)) * speed * dt
    }

    /// Resolves the initial impact without steering the car on the player's
    /// behalf. Glancing contacts retain momentum; near head-on hits stop and
    /// produce only a small rebound. Returns impact strength 0...1.
    mutating func hitWall(
        normal: SIMD3<Float>, travel: SIMD3<Float>
    ) -> Float {
        let travelLength = simd_length(travel)
        let normalLength = simd_length(normal)
        guard travelLength > 1e-6, normalLength > 1e-6 else { return 0 }

        let direction = travel / travelLength
        let wallNormal = normal / normalLength
        let impact = min(1, abs(simd_dot(direction, wallNormal)))
        let stopImpact: Float = 0.85

        if impact < stopImpact {
            let ratio = impact / stopImpact
            speed *= 1 - ratio * ratio
        } else {
            let rebound = (impact - stopImpact) / (1 - stopImpact)
            speed *= -0.08 * rebound
        }
        slip *= max(0, 1 - impact)
        understeerSlip *= max(0, 1 - impact)
        return impact
    }
}
