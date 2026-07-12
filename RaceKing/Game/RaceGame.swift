//
//  RaceGame.swift
//  RaceKing
//

import Foundation
import Observation
import RealityKit

/// Drives the whole race: owns the scene entities, integrates arcade car
/// physics every frame, and tracks checkpoints, laps, and lap times.
@Observable
final class RaceGame {
    enum Phase: Equatable {
        /// Car on the grid, waiting for the player to start.
        case ready
        case countdown
        case racing
    }

    // MARK: - State observed by the HUD

    private(set) var phase: Phase = .ready
    /// Completed laps since the race started.
    private(set) var lapCount = 0
    private(set) var currentLapTime: TimeInterval = 0
    private(set) var lastLapTime: TimeInterval?
    /// Best lap ever, persisted across launches.
    private(set) var bestLapTime: TimeInterval?
    private(set) var countdownValue = 3
    /// Playful scaled speed for the HUD (the car itself moves at miniature scale).
    private(set) var displaySpeed = 0

    // MARK: - Player input (written by the touch controls)

    /// Steering in -1 (left) ... 1 (right).
    var steeringInput: Float = 0
    var throttleInput = false
    var brakeInput = false

    // MARK: - Scene

    let layout = TrackLayout()
    /// Root of the game scene. On AR devices this gets anchored to the floor.
    let root = Entity()
    private let car: Entity
    private let checkpoints: [SIMD3<Float>]

    /// Car pose in `root`'s space, for follow cameras and tests.
    var carPosition: SIMD3<Float> { car.position }
    var carHeading: Float { heading }

    // MARK: - Simulation

    private var speed: Float = 0
    private var heading: Float = 0
    private var steering: Float = 0
    private var nextCheckpoint = 1
    private var countdownRemaining: TimeInterval = 0

    private static let bestLapKey = "bestLapTime"

    init() {
        car = EntityFactory.makeCar()
        checkpoints = layout.checkpoints
        root.addChild(EntityFactory.makeTrack(layout: layout))
        root.addChild(car)

        let savedBest = UserDefaults.standard.double(forKey: Self.bestLapKey)
        bestLapTime = savedBest > 0 ? savedBest : nil
        placeCarOnGrid()
    }

    func startRace() {
        guard phase == .ready else { return }
        countdownRemaining = 3
        countdownValue = 3
        phase = .countdown
    }

    func reset() {
        phase = .ready
        lapCount = 0
        currentLapTime = 0
        lastLapTime = nil
        displaySpeed = 0
        placeCarOnGrid()
    }

    /// Advances the game by one frame. Called from the scene's update event.
    func update(deltaTime: TimeInterval) {
        switch phase {
        case .ready:
            break
        case .countdown:
            countdownRemaining -= deltaTime
            countdownValue = max(1, Int(countdownRemaining.rounded(.up)))
            if countdownRemaining <= 0 {
                phase = .racing
                currentLapTime = 0
            }
        case .racing:
            currentLapTime += deltaTime
            stepCar(Float(min(deltaTime, 1.0 / 20.0)))
            checkCheckpoints()
        }
    }

    // MARK: - Car physics

    private func stepCar(_ dt: Float) {
        let maxSpeed: Float = 0.65
        let acceleration: Float = 0.55
        let brakeDeceleration: Float = 1.4
        let rollingDrag: Float = 0.35
        let offTrackDrag: Float = 2.2

        // Ease the wheel toward the input so steering isn't twitchy.
        steering += (steeringInput - steering) * min(1, dt * 10)

        if throttleInput { speed += acceleration * dt }
        if brakeInput { speed -= brakeDeceleration * dt }

        // The road has grip; leaving it slows the car down hard.
        var drag = rollingDrag
        if layout.distanceFromCenterline(car.position) > layout.roadWidth / 2 + 0.015 {
            drag += offTrackDrag
        }
        speed -= drag * speed * dt
        speed = max(0, min(speed, maxSpeed))

        // Yaw response grows with speed so the car can't pivot in place.
        let grip = 0.25 + 0.75 * (speed / maxSpeed)
        heading -= steering * 2.8 * grip * dt

        car.orientation = simd_quatf(angle: heading, axis: [0, 1, 0])
        let forward = SIMD3<Float>(sin(heading), 0, cos(heading))
        car.position += forward * speed * dt
        displaySpeed = Int(speed * 400)
    }

    // MARK: - Lap logic

    private func placeCarOnGrid() {
        let grid = layout.sample(at: layout.startOffset - 0.06)
        car.position = grid.position
        heading = TrackLayout.heading(of: grid.tangent)
        car.orientation = simd_quatf(angle: heading, axis: [0, 1, 0])
        speed = 0
        steering = 0
        nextCheckpoint = 1
    }

    /// Checkpoints must be hit in order; passing the start line (checkpoint 0)
    /// after all others completes a lap. This blocks course cutting.
    private func checkCheckpoints() {
        let target = checkpoints[nextCheckpoint]
        let distance = simd_distance(
            SIMD2(car.position.x, car.position.z), SIMD2(target.x, target.z)
        )
        guard distance < 0.13 else { return }
        if nextCheckpoint == 0 {
            completeLap()
        }
        nextCheckpoint = (nextCheckpoint + 1) % checkpoints.count
    }

    private func completeLap() {
        lapCount += 1
        lastLapTime = currentLapTime
        if bestLapTime.map({ currentLapTime < $0 }) ?? true {
            bestLapTime = currentLapTime
            UserDefaults.standard.set(currentLapTime, forKey: Self.bestLapKey)
        }
        currentLapTime = 0
    }
}
