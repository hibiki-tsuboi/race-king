//
//  RaceGame.swift
//  RaceKing
//

import Foundation
import Observation
import RealityKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Gameplay moments other systems (audio, haptics) react to.
enum GameEvent {
    case countdownTick(Int)
    case go
    case lapCompleted(isBest: Bool)
    case raceFinished(position: Int)
    /// Periodic pulse while the player is off the road.
    case offRoad
    /// The player bumped a barrier wall hard.
    case wallHit
    case driftStarted
    /// Periodic pulse while drifting.
    case driftPulse
    /// Mini-turbo charge reached a new tier (1 = blue, 2 = orange).
    case driftChargeLevelUp(Int)
    /// Drift finished; boostLevel 0 means no mini-turbo fired.
    case driftEnded(boostLevel: Int)
}

/// Drives the whole game: owns the scene entities, integrates car physics
/// every frame, and runs the race state machine for both modes.
@Observable
final class RaceGame {
    enum Phase: Equatable {
        case ready
        case countdown
        case racing
        case finished
    }

    enum Mode: String, CaseIterable {
        case timeAttack
        case race
    }

    /// Laps to the checkered flag in VS race mode.
    static let raceLapTotal = 3

    // MARK: - State observed by the HUD

    private(set) var phase: Phase = .ready
    var mode: Mode = .timeAttack {
        didSet {
            guard phase == .ready, mode != oldValue else { return }
            placeCarsOnGrid()
        }
    }
    private(set) var lapCount = 0
    private(set) var currentLapTime: TimeInterval = 0
    private(set) var lastLapTime: TimeInterval?
    /// Best lap ever (time attack), persisted across launches.
    private(set) var bestLapTime: TimeInterval?
    private(set) var countdownValue = 3
    /// Playful scaled speed for the HUD (the car itself moves at miniature scale).
    private(set) var displaySpeed = 0
    /// Player rank (1-based) among all karts during a VS race.
    private(set) var playerPosition = 1
    /// Final rank once the player takes the checkered flag.
    private(set) var finalPosition: Int?
    /// Total elapsed time of the current VS race.
    private(set) var raceTime: TimeInterval = 0

    // MARK: - Settings (persisted)

    var ghostEnabled: Bool {
        didSet { UserDefaults.standard.set(ghostEnabled, forKey: "ghostEnabled") }
    }
    var tiltSteeringEnabled: Bool {
        didSet { UserDefaults.standard.set(tiltSteeringEnabled, forKey: "tiltSteering") }
    }

    // MARK: - Player input (written by touch controls or tilt)

    /// Steering in -1 (left) ... 1 (right).
    var steeringInput: Float = 0
    var throttleInput = false
    var brakeInput = false

    /// Hook for audio and haptics.
    var onEvent: ((GameEvent) -> Void)?

    // MARK: - Scene

    let layout = TrackLayout()
    /// Root of the game scene. On AR devices this gets anchored to the floor.
    let root = Entity()
    private let car: Entity
    private let ghostCar: Entity
    private let checkpoints: [SIMD3<Float>]
    private var aiDrivers: [AIDriver] = []

    /// Car pose in `root`'s space, for follow cameras and tests.
    var carPosition: SIMD3<Float> { car.position }
    var carHeading: Float { physics.heading }
    var speedRatio: Float { physics.speed / CarPhysics.maxSpeed }
    var isEngineRunning: Bool { phase == .countdown || phase == .racing }
    var isDrifting: Bool { physics.isDrifting }

    // MARK: - Simulation

    private var physics = CarPhysics()
    private var nextCheckpoint = 1
    private var countdownRemaining: TimeInterval = 0
    private var ghost: GhostRecorder
    private var playerTrackS: Float = 0
    private var playerProgress: Float = 0
    private var aiFinishedCount = 0
    private var offRoadPulse: TimeInterval = 0
    private var wallHitCooldown: TimeInterval = 0

    // MARK: - Drift bookkeeping

    private var brakeHoldTime: TimeInterval = 0
    private var driftReleaseGrace: TimeInterval = 0
    private var driftChargeLevelSeen = 0
    private var driftPulseTimer: TimeInterval = 0
    private var driftHopRemaining: TimeInterval = 0
    private var smokeSpawnTimer: TimeInterval = 0
    private var smokePuffs: [(entity: ModelEntity, age: Float)] = []
    private var glowBlue: Entity?
    private var glowOrange: Entity?
    private var boostFlame: Entity?

    private static let smokeMesh = MeshResource.generateSphere(radius: 0.0045)
    private static let smokeMaterial = UnlitMaterial(color: .init(white: 0.95, alpha: 1))

    /// Keyed by track length so records reset when the circuit changes.
    private let bestLapKey: String

    init() {
        car = EntityFactory.makeCar()
        ghost = GhostRecorder(trackLength: layout.totalLength)
        bestLapKey = "bestLapTime-\(Int(layout.totalLength * 1000))"
        ghostCar = EntityFactory.makeCar(bodyColor: EntityFactory.ghostBodyColor)
        ghostCar.components.set(OpacityComponent(opacity: 0.35))
        ghostCar.isEnabled = false
        checkpoints = layout.checkpoints
        aiDrivers = AIDriver.defaultOpponents()
        ghostEnabled = UserDefaults.standard.object(forKey: "ghostEnabled") as? Bool ?? true
        tiltSteeringEnabled = UserDefaults.standard.bool(forKey: "tiltSteering")

        root.addChild(EntityFactory.makeTrack(layout: layout))
        root.addChild(car)
        root.addChild(ghostCar)
        glowBlue = car.findEntity(named: "glowBlue")
        glowOrange = car.findEntity(named: "glowOrange")
        boostFlame = car.findEntity(named: "boostFlame")

        let savedBest = UserDefaults.standard.double(forKey: bestLapKey)
        bestLapTime = savedBest > 0 ? savedBest : nil
        placeCarsOnGrid()
    }

    /// Floor target for AR anchoring: any horizontal floor of 0.6 x 0.6 m+.
    static var floorAnchorTarget: AnchoringComponent.Target {
        .plane(.horizontal, classification: .floor, minimumBounds: [0.6, 0.6])
    }

    /// Anchors the course to the floor (called once from AR setup).
    func installFloorAnchor() {
        root.components.set(AnchoringComponent(Self.floorAnchorTarget))
    }

    /// Detaches the course and re-anchors it to the floor plane currently
    /// in view — point the camera where the course should go first.
    func reanchorCourse() {
        guard phase == .ready, root.components.has(AnchoringComponent.self) else { return }
        root.isEnabled = false
        root.components.remove(AnchoringComponent.self)
        Task { @MainActor in
            // Give the anchoring system a beat to release the old plane.
            try? await Task.sleep(for: .milliseconds(80))
            root.components.set(AnchoringComponent(Self.floorAnchorTarget))
            root.isEnabled = true
        }
    }

    /// Spins the whole course a quarter turn on the floor, for rooms where
    /// the long side doesn't match the anchor's orientation.
    func rotateCourse() {
        guard phase == .ready else { return }
        root.orientation = simd_quatf(angle: .pi / 2, axis: [0, 1, 0]) * root.orientation
    }

    /// Applies an imported car model to the player and ghost cars in place
    /// (nil restores the procedural kart). Safe to call mid-race.
    func setCustomCarModel(_ template: Entity?) {
        EntityFactory.populate(car, bodyColor: EntityFactory.playerBodyColor, customTemplate: template)
        EntityFactory.populate(ghostCar, bodyColor: EntityFactory.ghostBodyColor, customTemplate: template)
        glowBlue = car.findEntity(named: "glowBlue")
        glowOrange = car.findEntity(named: "glowOrange")
        boostFlame = car.findEntity(named: "boostFlame")
    }

    func startRace() {
        guard phase == .ready else { return }
        countdownRemaining = 3
        countdownValue = 3
        phase = .countdown
        onEvent?(.countdownTick(3))
    }

    func reset() {
        phase = .ready
        lapCount = 0
        currentLapTime = 0
        lastLapTime = nil
        raceTime = 0
        displaySpeed = 0
        playerPosition = 1
        finalPosition = nil
        aiFinishedCount = 0
        ghostCar.isEnabled = false
        clearDriftState()
        placeCarsOnGrid()
    }

    /// Advances the game by one frame. Called from the scene's update event.
    func update(deltaTime: TimeInterval) {
        let dt = Float(min(deltaTime, 1.0 / 20.0))
        switch phase {
        case .ready:
            break
        case .countdown:
            countdownRemaining -= deltaTime
            let newValue = max(1, Int(countdownRemaining.rounded(.up)))
            if newValue != countdownValue {
                countdownValue = newValue
                onEvent?(.countdownTick(newValue))
            }
            if countdownRemaining <= 0 {
                phase = .racing
                currentLapTime = 0
                ghost.beginLap()
                onEvent?(.go)
            }
        case .racing:
            currentLapTime += deltaTime
            if mode == .race { raceTime += deltaTime }
            stepPlayer(dt, deltaTime: deltaTime)
            stepAI(dt)
            separateCars()
            updateGhost()
            updateRanking()
        case .finished:
            // Let the field keep rolling past the flag; brake only to a stop,
            // not into reverse.
            car.position += physics.step(
                dt: dt, steeringInput: 0, throttle: false,
                brake: physics.speed > 0.01, offRoad: false
            )
            car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])
            collidePlayerWithWalls()
            updateDriftEffects(deltaTime)
            stepAI(dt)
            separateCars()
        }
    }

    // MARK: - Per-frame stepping

    private func stepPlayer(_ dt: Float, deltaTime: TimeInterval) {
        updateDrift(deltaTime)
        let offRoad = layout.distanceFromCenterline(car.position) > layout.roadWidth / 2 + 0.015
        car.position += physics.step(
            dt: dt, steeringInput: steeringInput,
            throttle: throttleInput,
            brake: brakeInput && !physics.isDrifting,
            offRoad: offRoad
        )
        // A small hop when the drift kicks in.
        driftHopRemaining = max(0, driftHopRemaining - deltaTime)
        car.position.y = driftHopRemaining > 0
            ? sin(.pi * Float(1 - driftHopRemaining / 0.16)) * 0.01
            : 0
        car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])

        let impact = collidePlayerWithWalls()
        wallHitCooldown -= deltaTime
        if impact > 0.25, wallHitCooldown <= 0 {
            onEvent?(.wallHit)
            wallHitCooldown = 0.3
        }
        // Slamming a wall kills the drift without a reward.
        if impact > 0.2, physics.isDrifting {
            physics.endDrift(rewardBoost: false)
            onEvent?(.driftEnded(boostLevel: 0))
        }
        updateDriftEffects(deltaTime)
        displaySpeed = Int(abs(physics.speed) * 400)

        if offRoad {
            offRoadPulse -= deltaTime
            if offRoadPulse <= 0 {
                onEvent?(.offRoad)
                offRoadPulse = 0.15
            }
        } else {
            offRoadPulse = 0
        }

        if mode == .timeAttack {
            ghost.record(time: currentLapTime, position: car.position, heading: physics.heading)
        }
        checkPlayerCheckpoints()
    }

    private func stepAI(_ dt: Float) {
        guard mode == .race else { return }
        for driver in aiDrivers {
            driver.drive(dt: dt, layout: layout)
            if driver.updateLap(checkpoints: checkpoints, radius: layout.checkpointRadius),
               driver.lapCount >= Self.raceLapTotal, !driver.finished {
                driver.finished = true
                aiFinishedCount += 1
            }
        }
    }

    // MARK: - Drift

    /// Starts a drift on a brake tap while turning at speed, and ends it
    /// when the player straightens up (with a mini-turbo), holds the brake
    /// for real braking, or slows down too much.
    private func updateDrift(_ deltaTime: TimeInterval) {
        brakeHoldTime = brakeInput ? brakeHoldTime + deltaTime : 0

        guard physics.isDrifting else {
            let isTapFrame = brakeInput && brakeHoldTime <= deltaTime
            if isTapFrame, abs(steeringInput) > 0.25, physics.speed > CarPhysics.driftMinSpeed {
                physics.startDrift(direction: steeringInput > 0 ? 1 : -1)
                driftChargeLevelSeen = 0
                driftReleaseGrace = 0
                driftHopRemaining = 0.16
                onEvent?(.driftStarted)
            }
            return
        }

        var reward = true
        var endNow = false
        // Straightening up (or counter-steering past neutral) ends the drift.
        if steeringInput * physics.driftDirection < 0.15 {
            driftReleaseGrace += deltaTime
            endNow = driftReleaseGrace > 0.12
        } else {
            driftReleaseGrace = 0
        }
        // Holding the brake means the player actually wants to brake.
        if brakeHoldTime > 0.22 { endNow = true; reward = false }
        if physics.speed < CarPhysics.driftMinSpeed { endNow = true; reward = false }

        if endNow {
            let level = physics.endDrift(rewardBoost: reward)
            onEvent?(.driftEnded(boostLevel: level))
        } else if physics.chargeLevel > driftChargeLevelSeen {
            driftChargeLevelSeen = physics.chargeLevel
            onEvent?(.driftChargeLevelUp(driftChargeLevelSeen))
        }
    }

    /// Underglow, boost flame, tire smoke, and drift haptic pulses.
    private func updateDriftEffects(_ deltaTime: TimeInterval) {
        glowBlue?.isEnabled = physics.isDrifting && physics.chargeLevel == 1
        glowOrange?.isEnabled = physics.isDrifting && physics.chargeLevel >= 2
        boostFlame?.isEnabled = physics.isBoosting

        if physics.isDrifting {
            driftPulseTimer -= deltaTime
            if driftPulseTimer <= 0 {
                onEvent?(.driftPulse)
                driftPulseTimer = 0.12
            }
            smokeSpawnTimer -= deltaTime
            if smokeSpawnTimer <= 0 {
                spawnSmokePuff()
                smokeSpawnTimer = 0.045
            }
        } else {
            driftPulseTimer = 0
            smokeSpawnTimer = 0
        }

        let smokeLife: Float = 0.4
        for i in smokePuffs.indices { smokePuffs[i].age += Float(deltaTime) }
        for puff in smokePuffs where puff.age >= smokeLife { puff.entity.removeFromParent() }
        smokePuffs.removeAll { $0.age >= smokeLife }
        for puff in smokePuffs {
            let t = puff.age / smokeLife
            puff.entity.scale = SIMD3(repeating: 0.7 + 1.8 * t)
            puff.entity.components.set(OpacityComponent(opacity: 0.65 * (1 - t)))
        }
    }

    private func spawnSmokePuff() {
        let puff = ModelEntity(mesh: Self.smokeMesh, materials: [Self.smokeMaterial])
        puff.position = car.position - physics.forward * 0.045 + SIMD3(
            Float.random(in: -0.012...0.012), 0.008, Float.random(in: -0.012...0.012)
        )
        puff.components.set(OpacityComponent(opacity: 0.65))
        root.addChild(puff)
        smokePuffs.append((puff, 0))
    }

    private func clearDriftState() {
        physics.endDrift(rewardBoost: false)
        brakeHoldTime = 0
        driftReleaseGrace = 0
        driftChargeLevelSeen = 0
        driftHopRemaining = 0
        for puff in smokePuffs { puff.entity.removeFromParent() }
        smokePuffs.removeAll()
        glowBlue?.isEnabled = false
        glowOrange?.isEnabled = false
        boostFlame?.isEnabled = false
    }

    /// Keeps the player between the barrier walls: projects the car back
    /// inside the corridor and scrubs speed. Returns impact strength 0...1.
    @discardableResult
    private func collidePlayerWithWalls() -> Float {
        let offset = layout.signedOffset(car.position)
        let limit = layout.corridorLimit
        guard abs(offset) > limit else { return 0 }
        let normal = layout.lateralNormal(at: car.position)
        car.position += normal * (max(-limit, min(limit, offset)) - offset)
        return physics.hitWall(normal: normal)
    }

    /// Gently pushes overlapping karts apart (there is no hard collision).
    private func separateCars() {
        guard mode == .race else { return }
        let cars = [car] + aiDrivers.map(\.entity)
        let minGap: Float = 0.05
        for i in 0..<cars.count {
            for j in (i + 1)..<cars.count {
                var delta = cars[j].position - cars[i].position
                delta.y = 0
                let distance = simd_length(delta)
                guard distance > 1e-4, distance < minGap else { continue }
                let push = delta / distance * ((minGap - distance) / 2)
                cars[i].position -= push
                cars[j].position += push
            }
        }
    }

    private func updateGhost() {
        guard mode == .timeAttack, ghostEnabled,
              let pose = ghost.best?.pose(at: currentLapTime) else {
            ghostCar.isEnabled = false
            return
        }
        ghostCar.isEnabled = true
        ghostCar.position = pose.position
        ghostCar.orientation = simd_quatf(angle: pose.heading, axis: [0, 1, 0])
    }

    private func updateRanking() {
        guard mode == .race else { return }
        let s = layout.nearestS(to: car.position, near: playerTrackS)
        playerProgress += layout.progressDelta(from: playerTrackS, to: s)
        playerTrackS = s
        playerPosition = aiDrivers.count { $0.progress > playerProgress } + 1
    }

    // MARK: - Lap logic

    /// Advances `next` when `position` reaches its checkpoint; returns true
    /// when the start line is crossed after all checkpoints (= lap complete).
    /// Ordered checkpoints block course cutting.
    static func advanceCheckpoint(
        _ next: inout Int, position: SIMD3<Float>, checkpoints: [SIMD3<Float>],
        radius: Float
    ) -> Bool {
        let target = checkpoints[next]
        let distance = simd_distance(
            SIMD2(position.x, position.z), SIMD2(target.x, target.z)
        )
        guard distance < radius else { return false }
        let completed = next == 0
        next = (next + 1) % checkpoints.count
        return completed
    }

    private func checkPlayerCheckpoints() {
        guard Self.advanceCheckpoint(
            &nextCheckpoint, position: car.position, checkpoints: checkpoints,
            radius: layout.checkpointRadius
        ) else { return }

        lapCount += 1
        lastLapTime = currentLapTime
        switch mode {
        case .timeAttack:
            let isBest = bestLapTime.map { currentLapTime < $0 } ?? true
            ghost.finishLap(duration: currentLapTime)
            if isBest {
                bestLapTime = currentLapTime
                UserDefaults.standard.set(currentLapTime, forKey: bestLapKey)
            }
            onEvent?(.lapCompleted(isBest: isBest))
            currentLapTime = 0
            ghost.beginLap()
        case .race:
            if lapCount >= Self.raceLapTotal {
                let position = aiFinishedCount + 1
                finalPosition = position
                playerPosition = position
                phase = .finished
                physics.endDrift(rewardBoost: false)
                onEvent?(.raceFinished(position: position))
            } else {
                onEvent?(.lapCompleted(isBest: false))
                currentLapTime = 0
            }
        }
    }

    // MARK: - Grid

    private func placeCarsOnGrid() {
        for driver in aiDrivers { driver.entity.removeFromParent() }
        nextCheckpoint = 1

        switch mode {
        case .timeAttack:
            placePlayer(back: 0.06, lateral: 0)
        case .race:
            let slots: [(back: Float, lateral: Float)] =
                [(0.08, -0.037), (0.08, 0.037), (0.17, -0.037)]
            for (driver, slot) in zip(aiDrivers, slots) {
                driver.place(back: slot.back, lateral: slot.lateral, layout: layout)
                root.addChild(driver.entity)
            }
            placePlayer(back: 0.17, lateral: 0.037)
        }
    }

    private func placePlayer(back: Float, lateral: Float) {
        let s = layout.startOffset - back
        let grid = layout.sample(at: s)
        let side = SIMD3<Float>(-grid.tangent.z, 0, grid.tangent.x)
        car.position = grid.position + side * lateral
        physics.reset(heading: TrackLayout.heading(of: grid.tangent))
        car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])
        playerTrackS = layout.nearestS(to: car.position, near: s)
        playerProgress = 0
    }
}
