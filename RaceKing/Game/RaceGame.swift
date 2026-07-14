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

/// Drives the whole game: owns the scene entities, integrates car physics,
/// and runs circuit races or a RoomPlan-powered free drive.
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
        case roomDrive
    }

    /// Laps to the checkered flag in VS race mode.
    static let raceLapTotal = 3
    static let minimumCourseScale: Float = 0.5
    static let maximumCourseScale: Float = 2.0

    // MARK: - State observed by the HUD

    private(set) var phase: Phase = .ready
    /// False while AR is still searching for a horizontal course surface;
    /// always true on platforms without a surface anchor (simulator, macOS).
    private(set) var isCourseAnchored = true
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
    /// RoomPlan scan state used by the free-drive setup UI.
    private(set) var hasScannedRoom = false
    private(set) var roomStartPlaced = false
    private(set) var roomObstacleCount = 0
    /// Uniform scale of the circuit root, including every kart and effect.
    private(set) var courseScale: Float = 1

    var canStart: Bool { mode != .roomDrive || roomStartPlaced }

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
    /// Receives the AR floor anchor; the course moves freely inside it.
    let anchorRoot = Entity()
    /// Root of the course and cars, repositionable on the floor by the player.
    let root = Entity()
    /// World-origin anchor for RoomPlan geometry, which is already expressed
    /// in the shared ARSession's coordinate space.
    let roomRoot = Entity()
    /// Follows the AR camera so course placement can use the aim direction.
    let cameraRig = Entity()

    // MARK: - Non-AR fallback

    /// True after the player opts into playing without AR (dark rooms,
    /// undetectable floors, or a denied camera permission).
    private(set) var virtualModeActive = false
    /// Turns true once floor detection has struggled for a while.
    private(set) var canOfferVirtualMode = false
    private var floorSearchTime: TimeInterval = 0
    /// Camera entity for the non-AR mode (configured on activation).
    let virtualCamera = Entity()

    /// Switches to a fixed virtual camera over a grass floor — the same
    /// presentation the simulator uses. One-way until the next launch.
    func activateVirtualMode() {
        guard !virtualModeActive else { return }
        if mode == .roomDrive { mode = .timeAttack }
        virtualModeActive = true
        anchorRoot.components.remove(AnchoringComponent.self)
        anchorRoot.transform = .identity
        root.transform = .identity
        root.scale = SIMD3(repeating: courseScale)
        anchorRoot.addChild(EntityFactory.makeFallbackGround())
        virtualCamera.components.set(PerspectiveCameraComponent())
        virtualCamera.look(at: .zero, from: [0, 1.9, 2.4], relativeTo: nil)
        anchorRoot.addChild(virtualCamera)
    }
    private let car: Entity
    private let ghostCar: Entity
    private let checkpoints: [SIMD3<Float>]
    private var aiDrivers: [AIDriver] = []
    private var roomEnvironment: RoomDriveEnvironment?
    private var roomOcclusionRoot: Entity?
    private var roomStartPosition: SIMD3<Float>?
    private var roomStartHeading: Float = 0

    /// Car pose in its active scene root's space, for follow cameras and tests.
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
    private var playerTouchingWall = false

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

        anchorRoot.addChild(root)
        roomRoot.components.set(AnchoringComponent(.world(transform: matrix_identity_float4x4)))
        roomRoot.isEnabled = false
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

    /// Initial AR target. A modest unclassified horizontal plane lets the
    /// circuit start on either a floor or a tabletop.
    static var courseSurfaceAnchorTarget: AnchoringComponent.Target {
        .plane(.horizontal, classification: .any, minimumBounds: [0.3, 0.3])
    }

    /// Anchors the scene to the first usable course surface found by AR.
    func installCourseSurfaceAnchor() {
        anchorRoot.components.set(AnchoringComponent(Self.courseSurfaceAnchorTarget))
    }

    /// Moves the course center to a point in `anchorRoot` space, including its
    /// height so a tabletop does not collapse back down onto the floor.
    func moveCourse(to point: SIMD3<Float>) {
        guard phase == .ready, mode != .roomDrive else { return }
        root.position = point
    }

    /// Converts a raycast result from the shared AR world into the current
    /// anchor's local coordinates before moving the circuit.
    func moveCourse(toWorldPoint point: SIMD3<Float>) {
        guard phase == .ready, mode != .roomDrive, isCourseAnchored else { return }
        moveCourse(to: anchorRoot.convert(position: point, from: nil))
    }

    /// Spins the whole course 45° on the floor, for rooms where the long
    /// side doesn't match the anchor's orientation.
    func rotateCourse() {
        guard phase == .ready, mode != .roomDrive else { return }
        root.orientation = simd_quatf(angle: .pi / 4, axis: [0, 1, 0]) * root.orientation
    }

    /// Resizes the whole circuit in local space, keeping gameplay proportions
    /// identical while fitting anything from a tabletop to a large floor.
    func setCourseScale(_ newScale: Float) {
        guard phase == .ready, mode != .roomDrive else { return }
        courseScale = max(
            Self.minimumCourseScale,
            min(Self.maximumCourseScale, newScale)
        )
        root.scale = SIMD3(repeating: courseScale)
    }

    func adjustCourseScale(by amount: Float) {
        setCourseScale(courseScale + amount)
    }

    func resetCourseScale() {
        setCourseScale(1)
    }

    // MARK: - Room free drive

    /// Installs one RoomPlan result in the still-running AR world. The player
    /// chooses a safe start point afterward by aiming at the scanned floor.
    func configureRoom(_ environment: RoomDriveEnvironment) {
        roomEnvironment = environment
        hasScannedRoom = true
        roomStartPlaced = false
        roomStartPosition = nil
        roomObstacleCount = environment.obstacles.count

        roomOcclusionRoot?.removeFromParent()
        let occlusionRoot = environment.makeOcclusionRoot()
        roomOcclusionRoot = occlusionRoot
        roomRoot.addChild(occlusionRoot)

        if mode != .roomDrive { mode = .roomDrive }
        placeCarsOnGrid()
    }

    /// Places the car where the camera is aiming. Returns false when the ray
    /// misses the scanned floor or lands too close to furniture or a wall.
    @discardableResult
    func placeRoomStart(
        alongRayFrom origin: SIMD3<Float>, direction: SIMD3<Float>
    ) -> Bool {
        guard mode == .roomDrive, phase == .ready,
              let environment = roomEnvironment,
              let point = environment.placementPoint(
                  rayOrigin: origin, direction: direction
              ) else { return false }

        let horizontal = SIMD2(direction.x, direction.z)
        roomStartHeading = simd_length(horizontal) > 0.05
            ? atan2(direction.x, direction.z)
            : 0
        roomStartPosition = point
        roomStartPlaced = true
        placeCarsOnGrid()
        return true
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

    /// Applies an imported model to one AI kart (nil restores its tinted kart).
    func setAICarModel(_ template: Entity?, at index: Int) {
        guard aiDrivers.indices.contains(index) else { return }
        aiDrivers[index].applyModel(template)
    }

    func startRace() {
        guard phase == .ready, canStart else { return }
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
        let anchored = mode == .roomDrive
            || !anchorRoot.components.has(AnchoringComponent.self)
            || anchorRoot.isAnchored
        if anchored != isCourseAnchored { isCourseAnchored = anchored }

        // Offer the non-AR mode when floor detection keeps struggling.
        if mode != .roomDrive, phase == .ready, !anchored, !virtualModeActive {
            floorSearchTime += deltaTime
            if floorSearchTime >= 8, !canOfferVirtualMode {
                canOfferVirtualMode = true
            }
        }

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
            let movement = physics.step(
                dt: dt, steeringInput: 0, throttle: false,
                brake: physics.speed > 0.01, offRoad: false
            )
            car.position += movement
            let wallNormal = constrainPlayerToWalls()
            _ = resolvePlayerWallContact(normal: wallNormal, travel: movement)
            car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])
            updateDriftEffects(deltaTime)
            stepAI(dt)
            separateCars()
        }
    }

    // MARK: - Per-frame stepping

    private func stepPlayer(_ dt: Float, deltaTime: TimeInterval) {
        updateDrift(deltaTime)
        var offRoad = false
        var impact: Float = 0
        var wallNormal: SIMD3<Float>?
        var travel = SIMD3<Float>.zero
        let baseHeight: Float

        if mode == .roomDrive, let environment = roomEnvironment {
            baseHeight = environment.floorHeight
            var previous = car.position
            previous.y = baseHeight
            travel = physics.step(
                dt: dt, steeringInput: steeringInput,
                throttle: throttleInput,
                brake: brakeInput && !physics.isDrifting,
                offRoad: false
            )
            var proposed = previous + travel
            proposed.y = baseHeight
            if let collision = environment.collision(from: previous, to: proposed) {
                car.position = collision.position
                wallNormal = collision.normal
            } else {
                car.position = proposed
            }
        } else {
            baseHeight = 0
            offRoad = layout.distanceFromCenterline(car.position)
                > layout.roadWidth / 2 + 0.015
            travel = physics.step(
                dt: dt, steeringInput: steeringInput,
                throttle: throttleInput,
                brake: brakeInput && !physics.isDrifting,
                offRoad: offRoad
            )
            car.position += travel
            wallNormal = constrainPlayerToWalls()
        }
        impact = resolvePlayerWallContact(normal: wallNormal, travel: travel)

        // A small hop when the drift kicks in.
        driftHopRemaining = max(0, driftHopRemaining - deltaTime)
        car.position.y = baseHeight + (driftHopRemaining > 0
            ? sin(.pi * Float(1 - driftHopRemaining / 0.16)) * 0.01
            : 0)
        car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])

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
        if mode != .roomDrive { checkPlayerCheckpoints() }
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
        car.parent?.addChild(puff)
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

    /// Keeps the player between the barrier walls while retaining movement
    /// along them. The collision response is applied separately on contact.
    private func constrainPlayerToWalls() -> SIMD3<Float>? {
        let offset = layout.signedOffset(car.position)
        let limit = layout.corridorLimit
        guard abs(offset) > limit else { return nil }
        let normal = layout.lateralNormal(at: car.position)
        car.position += normal * (max(-limit, min(limit, offset)) - offset)
        return normal
    }

    /// Applies one impulse when contact begins. Sustained glancing contact is
    /// constrained geometrically instead of draining speed every frame.
    private func resolvePlayerWallContact(
        normal: SIMD3<Float>?, travel: SIMD3<Float>
    ) -> Float {
        guard let normal else {
            playerTouchingWall = false
            return 0
        }
        guard !playerTouchingWall else { return 0 }
        playerTouchingWall = true
        return physics.hitWall(normal: normal, travel: travel)
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
        case .roomDrive:
            break
        }
    }

    // MARK: - Grid

    private func placeCarsOnGrid() {
        for driver in aiDrivers { driver.entity.removeFromParent() }
        nextCheckpoint = 1
        playerTouchingWall = false

        switch mode {
        case .timeAttack:
            root.isEnabled = true
            roomRoot.isEnabled = false
            movePlayer(to: root)
            car.isEnabled = true
            placePlayer(back: 0.06, lateral: 0)
        case .race:
            root.isEnabled = true
            roomRoot.isEnabled = false
            movePlayer(to: root)
            car.isEnabled = true
            let slots: [(back: Float, lateral: Float)] =
                [(0.08, -0.037), (0.08, 0.037), (0.17, -0.037)]
            for (driver, slot) in zip(aiDrivers, slots) {
                driver.place(back: slot.back, lateral: slot.lateral, layout: layout)
                root.addChild(driver.entity)
            }
            placePlayer(back: 0.17, lateral: 0.037)
        case .roomDrive:
            root.isEnabled = false
            roomRoot.isEnabled = roomEnvironment != nil
            movePlayer(to: roomRoot)
            guard let position = roomStartPosition else {
                car.isEnabled = false
                physics.reset(heading: 0)
                return
            }
            car.isEnabled = true
            car.position = position
            physics.reset(heading: roomStartHeading)
            car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])
        }
    }

    private func movePlayer(to parent: Entity) {
        guard car.parent !== parent else { return }
        car.removeFromParent()
        parent.addChild(car)
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
