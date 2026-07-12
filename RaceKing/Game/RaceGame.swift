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

    // MARK: - Simulation

    private var physics = CarPhysics()
    private var nextCheckpoint = 1
    private var countdownRemaining: TimeInterval = 0
    private var ghost = GhostRecorder()
    private var playerTrackS: Float = 0
    private var playerProgress: Float = 0
    private var aiFinishedCount = 0
    private var offRoadPulse: TimeInterval = 0
    private var wallHitCooldown: TimeInterval = 0

    private static let bestLapKey = "bestLapTime"

    init() {
        car = EntityFactory.makeCar()
        ghostCar = EntityFactory.makeCar(bodyColor: .init(white: 0.9, alpha: 1))
        ghostCar.components.set(OpacityComponent(opacity: 0.35))
        ghostCar.isEnabled = false
        checkpoints = layout.checkpoints
        aiDrivers = AIDriver.defaultOpponents()
        ghostEnabled = UserDefaults.standard.object(forKey: "ghostEnabled") as? Bool ?? true
        tiltSteeringEnabled = UserDefaults.standard.bool(forKey: "tiltSteering")

        root.addChild(EntityFactory.makeTrack(layout: layout))
        root.addChild(car)
        root.addChild(ghostCar)

        let savedBest = UserDefaults.standard.double(forKey: Self.bestLapKey)
        bestLapTime = savedBest > 0 ? savedBest : nil
        placeCarsOnGrid()
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
            stepAI(dt)
            separateCars()
        }
    }

    // MARK: - Per-frame stepping

    private func stepPlayer(_ dt: Float, deltaTime: TimeInterval) {
        let offRoad = layout.distanceFromCenterline(car.position) > layout.roadWidth / 2 + 0.015
        car.position += physics.step(
            dt: dt, steeringInput: steeringInput,
            throttle: throttleInput, brake: brakeInput, offRoad: offRoad
        )
        car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])

        let impact = collidePlayerWithWalls()
        wallHitCooldown -= deltaTime
        if impact > 0.25, wallHitCooldown <= 0 {
            onEvent?(.wallHit)
            wallHitCooldown = 0.3
        }
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
            if driver.updateLap(checkpoints: checkpoints),
               driver.lapCount >= Self.raceLapTotal, !driver.finished {
                driver.finished = true
                aiFinishedCount += 1
            }
        }
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
        _ next: inout Int, position: SIMD3<Float>, checkpoints: [SIMD3<Float>]
    ) -> Bool {
        let target = checkpoints[next]
        let distance = simd_distance(
            SIMD2(position.x, position.z), SIMD2(target.x, target.z)
        )
        guard distance < 0.13 else { return false }
        let completed = next == 0
        next = (next + 1) % checkpoints.count
        return completed
    }

    private func checkPlayerCheckpoints() {
        guard Self.advanceCheckpoint(
            &nextCheckpoint, position: car.position, checkpoints: checkpoints
        ) else { return }

        lapCount += 1
        lastLapTime = currentLapTime
        switch mode {
        case .timeAttack:
            let isBest = bestLapTime.map { currentLapTime < $0 } ?? true
            ghost.finishLap(duration: currentLapTime)
            if isBest {
                bestLapTime = currentLapTime
                UserDefaults.standard.set(currentLapTime, forKey: Self.bestLapKey)
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
