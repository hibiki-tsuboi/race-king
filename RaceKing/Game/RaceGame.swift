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
    case timeAttackFinished(isNewBest: Bool)
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
        case peerRace
        case roomDrive
    }

    /// Laps available for setting the fastest time in time attack mode.
    static let timeAttackLapTotal = 3
    /// Laps to the checkered flag in VS race mode.
    static let raceLapTotal = 3
    static let minimumCourseScale: Float = 0.5
    static let maximumCourseScale: Float = 2.0
    static let minimumRoomModelOpacity: Float = 0.08
    static let maximumRoomModelOpacity: Float = 0.65

    // MARK: - State observed by the HUD

    private(set) var phase: Phase = .ready
    /// False while AR is still searching for a horizontal course surface;
    /// always true on platforms without a surface anchor (simulator, macOS).
    private(set) var isCourseAnchored = true
    var mode: Mode = .timeAttack {
        didSet {
            guard phase == .ready, mode != oldValue else { return }
            applyPlayerCarModel()
            placeCarsOnGrid()
        }
    }
    private(set) var lapCount = 0
    private(set) var currentLapTime: TimeInterval = 0
    private(set) var lastLapTime: TimeInterval?
    /// Best lap ever (time attack), persisted across launches.
    private(set) var bestLapTime: TimeInterval?
    /// Fastest lap recorded during the current time attack.
    private(set) var sessionBestLapTime: TimeInterval?
    /// Session best minus the record at the start; negative means faster.
    private(set) var sessionBestLapDelta: TimeInterval?
    private(set) var sessionSetNewBestLap = false
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
    /// Y-axis rotation accumulated by the two-finger rotation gesture.
    private(set) var courseRotation: Float = 0
    /// Whether a nearby opponent is currently available for two-player mode.
    private(set) var peerConnected = false

    var canStart: Bool { mode != .roomDrive || roomStartPlaced }

    // MARK: - Settings (persisted)

    var ghostEnabled: Bool {
        didSet { UserDefaults.standard.set(ghostEnabled, forKey: "ghostEnabled") }
    }
    var tiltSteeringEnabled: Bool {
        didSet { UserDefaults.standard.set(tiltSteeringEnabled, forKey: "tiltSteering") }
    }
    var roomModelVisible: Bool {
        didSet {
            UserDefaults.standard.set(roomModelVisible, forKey: "roomModelVisible")
            applyRoomVisualizationSettings()
        }
    }
    var roomModelOpacity: Float {
        didSet {
            UserDefaults.standard.set(roomModelOpacity, forKey: "roomModelOpacity")
            applyRoomVisualizationSettings()
        }
    }

    // MARK: - Player input (written by touch controls or tilt)

    /// Steering in -1 (left) ... 1 (right).
    var steeringInput: Float = 0
    var throttleInput = false
    var brakeInput = false

    /// Hook for audio and haptics.
    var onEvent: ((GameEvent) -> Void)?
    /// Reports the local checkered-flag time to the nearby-session host.
    var onPeerRaceLocalFinish: ((TimeInterval) -> Void)?

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
        root.orientation = simd_quatf(angle: courseRotation, axis: [0, 1, 0])
        anchorRoot.addChild(EntityFactory.makeFallbackGround())
        virtualCamera.components.set(PerspectiveCameraComponent())
        virtualCamera.look(at: .zero, from: [0, 1.9, 2.4], relativeTo: nil)
        anchorRoot.addChild(virtualCamera)
    }
    private let car: Entity
    private let ghostCar: Entity
    private let peerCar: Entity
    private let checkpoints: [SIMD3<Float>]
    private var aiDrivers: [AIDriver] = []
    private var roomEnvironment: RoomDriveEnvironment?
    private var roomOcclusionRoot: Entity?
    private var roomVisualizationRoot: Entity?
    private var roomStartPosition: SIMD3<Float>?
    private var roomStartHeading: Float = 0
    private var roomCarFootprint = RoomDriveEnvironment.CarFootprint(
        halfWidth: 0.026,
        halfLength: 0.048,
        safetyMargin: 0.012
    )

    /// Car pose in its active scene root's space, for follow cameras and tests.
    var carPosition: SIMD3<Float> { car.position }
    var carHeading: Float { physics.heading }
    var speedRatio: Float { physics.speed / CarPhysics.maxSpeed }
    var isEngineRunning: Bool {
        (phase == .countdown || phase == .racing) && !peerLocalFinished
    }
    var isDrifting: Bool { physics.isDrifting }

    // MARK: - Simulation

    private var physics = CarPhysics()
    private var nextCheckpoint = 1
    private var countdownRemaining: TimeInterval = 0
    private var ghost: GhostRecorder
    private var bestLapTimeAtStart: TimeInterval?
    private var playerTrackS: Float = 0
    private var playerProgress: Float = 0
    private var aiFinishedCount = 0
    private var offRoadPulse: TimeInterval = 0
    private var wallHitCooldown: TimeInterval = 0
    private var playerTouchingWall = false
    private var peerIsHost = true
    private var peerLocalCarChoice: RaceCarChoice = .green
    private var peerLocalFinished = false
    private var peerProgress: Float = 0
    private(set) var peerLapCount = 0
    private var peerFinished = false
    private var peerTargetPosition = SIMD3<Float>.zero
    private var peerTargetHeading: Float = 0
    private var peerDisplayedHeading: Float = 0
    private var hasPeerCarState = false
    private var peerGlowBlue: Entity?
    private var peerGlowOrange: Entity?
    private var peerBoostFlame: Entity?

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
        peerCar = EntityFactory.makeCar(
            bodyColor: .init(red: 0.2, green: 0.45, blue: 0.95, alpha: 1),
            allowCustomModel: false
        )
        ghostCar.components.set(OpacityComponent(opacity: 0.35))
        ghostCar.isEnabled = false
        peerCar.isEnabled = false
        checkpoints = layout.checkpoints
        aiDrivers = AIDriver.defaultOpponents()
        ghostEnabled = UserDefaults.standard.object(forKey: "ghostEnabled") as? Bool ?? true
        tiltSteeringEnabled = UserDefaults.standard.bool(forKey: "tiltSteering")
        roomModelVisible = UserDefaults.standard.object(forKey: "roomModelVisible")
            as? Bool ?? true
        let savedRoomModelOpacity = UserDefaults.standard.object(
            forKey: "roomModelOpacity"
        ) == nil ? 0.28 : UserDefaults.standard.float(forKey: "roomModelOpacity")
        roomModelOpacity = min(
            Self.maximumRoomModelOpacity,
            max(Self.minimumRoomModelOpacity, savedRoomModelOpacity)
        )

        anchorRoot.addChild(root)
        roomRoot.components.set(AnchoringComponent(.world(transform: matrix_identity_float4x4)))
        roomRoot.isEnabled = false
        root.addChild(EntityFactory.makeTrack(layout: layout))
        root.addChild(car)
        root.addChild(ghostCar)
        refreshPlayerCarEffects()
        refreshPeerCarEffects()
        refreshRoomCarFootprint()

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

    /// Captures the course root in AR world coordinates for a nearby guest.
    func sharedCoursePlacement() -> PeerRacePacket.CoursePlacement? {
        guard phase == .ready, mode == .peerRace, isCourseAnchored else { return nil }

        let matrix = root.transformMatrix(relativeTo: nil)
        let xAxis = SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)
        let yAxis = SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)
        let zAxis = SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
        let xLength = simd_length(xAxis)
        let yLength = simd_length(yAxis)
        let zLength = simd_length(zAxis)
        guard xLength.isFinite, yLength.isFinite, zLength.isFinite,
              xLength > 0.0001, yLength > 0.0001, zLength > 0.0001 else { return nil }

        let rotationMatrix = simd_float3x3(columns: (
            xAxis / xLength,
            yAxis / yLength,
            zAxis / zLength
        ))
        let quaternion = simd_normalize(simd_quatf(rotationMatrix)).vector
        let translation = matrix.columns.3
        guard translation.x.isFinite, translation.y.isFinite, translation.z.isFinite,
              quaternion.x.isFinite, quaternion.y.isFinite,
              quaternion.z.isFinite, quaternion.w.isFinite else { return nil }

        return PeerRacePacket.CoursePlacement(
            x: translation.x,
            y: translation.y,
            z: translation.z,
            quaternionX: quaternion.x,
            quaternionY: quaternion.y,
            quaternionZ: quaternion.z,
            quaternionW: quaternion.w,
            scale: courseScale
        )
    }

    /// Hides the guest's independent course until ARKit shares the host world.
    func prepareForSharedCourse() {
        guard phase == .ready, mode == .peerRace else { return }
        root.isEnabled = false
    }

    func cancelSharedCoursePreparation() {
        root.isEnabled = true
    }

    /// Returns a guest to an independently tracked surface after leaving a shared world.
    func restoreLocalCoursePlacement() {
        guard !virtualModeActive else {
            root.isEnabled = true
            return
        }
        anchorRoot.transform = .identity
        anchorRoot.components.set(AnchoringComponent(Self.courseSurfaceAnchorTarget))
        root.position = .zero
        root.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
        root.scale = SIMD3(repeating: courseScale)
        courseRotation = 0
        isCourseAnchored = false
        root.isEnabled = true
    }

    /// Places the course at the host's pose after both sessions share a world origin.
    func applySharedCoursePlacement(
        _ placement: PeerRacePacket.CoursePlacement,
        spatiallyAnchored: Bool
    ) -> Bool {
        let quaternionVector = SIMD4(
            placement.quaternionX,
            placement.quaternionY,
            placement.quaternionZ,
            placement.quaternionW
        )
        let quaternionLength = simd_length(quaternionVector)
        guard phase == .ready, mode == .peerRace,
              placement.x.isFinite, placement.y.isFinite, placement.z.isFinite,
              abs(placement.x) < 1_000, abs(placement.y) < 1_000,
              abs(placement.z) < 1_000,
              quaternionLength.isFinite, quaternionLength > 0.0001,
              placement.scale.isFinite,
              (Self.minimumCourseScale...Self.maximumCourseScale).contains(placement.scale)
        else { return false }

        let rotation = simd_quatf(vector: quaternionVector / quaternionLength)
        anchorRoot.transform = .identity
        if spatiallyAnchored {
            var worldTransform = simd_float4x4(rotation)
            worldTransform.columns.3 = SIMD4(
                placement.x, placement.y, placement.z, 1
            )
            anchorRoot.components.set(
                AnchoringComponent(.world(transform: worldTransform))
            )
            root.position = .zero
            root.orientation = simd_quatf(angle: 0, axis: [0, 1, 0])
            isCourseAnchored = false
        } else {
            anchorRoot.components.remove(AnchoringComponent.self)
            root.position = [placement.x, placement.y, placement.z]
            root.orientation = rotation
            isCourseAnchored = true
        }
        courseScale = placement.scale
        courseRotation = 0
        root.scale = SIMD3(repeating: placement.scale)
        root.isEnabled = true
        return true
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

    /// Rotates the circuit and every child around its center without changing
    /// the real-world surface where it was placed.
    func setCourseRotation(_ angle: Float) {
        guard phase == .ready, mode != .roomDrive else { return }
        courseRotation = atan2(sin(angle), cos(angle))
        root.orientation = simd_quatf(angle: courseRotation, axis: [0, 1, 0])
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

        roomVisualizationRoot?.removeFromParent()
        let visualizationRoot = environment.makeVisualizationRoot()
        roomVisualizationRoot = visualizationRoot
        roomRoot.addChild(visualizationRoot)
        applyRoomVisualizationSettings()

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
        EntityFactory.populate(
            ghostCar,
            bodyColor: EntityFactory.ghostBodyColor,
            customTemplate: template
        )
        applyPlayerCarModel(customTemplate: template)
    }

    /// Applies an imported model to one AI kart (nil restores its tinted kart).
    func setAICarModel(_ template: Entity?, at index: Int) {
        guard aiDrivers.indices.contains(index) else { return }
        aiDrivers[index].applyModel(template)
    }

    // MARK: - Nearby two-player race

    func setPeerRaceLocalCar(_ choice: RaceCarChoice) {
        peerLocalCarChoice = choice
        if mode == .peerRace {
            applyPlayerCarModel()
        }
    }

    func setPeerRaceRemoteCar(_ choice: RaceCarChoice?) {
        EntityFactory.populateRaceCar(peerCar, choice: choice ?? .blue)
        refreshPeerCarEffects()
    }

    func setPeerRole(isHost: Bool) {
        guard phase == .ready else { return }
        peerIsHost = isHost
        if mode == .peerRace { placeCarsOnGrid() }
    }

    func setPeerConnected(_ connected: Bool) {
        peerConnected = connected
        peerCar.isEnabled = connected && mode == .peerRace
        if !connected, mode == .peerRace, phase != .ready {
            reset()
        }
    }

    /// A compact course-local snapshot; independent AR placement stays local.
    func peerCarState() -> PeerRacePacket.CarState {
        PeerRacePacket.CarState(
            x: car.position.x,
            y: car.position.y,
            z: car.position.z,
            heading: physics.heading,
            progress: playerProgress,
            lapCount: lapCount,
            finished: peerLocalFinished,
            drifting: physics.isDrifting,
            boosting: physics.isBoosting,
            driftChargeLevel: physics.chargeLevel
        )
    }

    /// Applies only finite, plausible values received from the nearby peer.
    func applyPeerCarState(_ state: PeerRacePacket.CarState) {
        guard mode == .peerRace,
              state.x.isFinite, state.y.isFinite, state.z.isFinite,
              state.heading.isFinite, state.progress.isFinite,
              abs(state.x) < 5, abs(state.y) < 2, abs(state.z) < 5,
              abs(state.progress) < 10_000,
              (0...Self.raceLapTotal).contains(state.lapCount),
              (0...2).contains(state.driftChargeLevel) else { return }

        peerTargetPosition = [state.x, state.y, state.z]
        peerTargetHeading = state.heading
        peerProgress = state.progress
        peerLapCount = state.lapCount
        peerFinished = state.finished
        peerGlowBlue?.isEnabled = state.drifting && state.driftChargeLevel == 1
        peerGlowOrange?.isEnabled = state.drifting && state.driftChargeLevel >= 2
        peerBoostFlame?.isEnabled = state.boosting

        if !hasPeerCarState {
            peerCar.position = peerTargetPosition
            peerDisplayedHeading = peerTargetHeading
            peerCar.orientation = simd_quatf(angle: peerDisplayedHeading, axis: [0, 1, 0])
            hasPeerCarState = true
        }
    }

    /// Applies the host-authoritative result after this player finishes.
    func finishPeerRace(position: Int, raceTime: TimeInterval) {
        guard mode == .peerRace, peerLocalFinished,
              (1...2).contains(position), raceTime.isFinite else { return }
        self.raceTime = max(0, raceTime)
        finalPosition = position
        playerPosition = position
        phase = .finished
        physics.endDrift(rewardBoost: false)
        onEvent?(.raceFinished(position: position))
    }

    func startRace() {
        guard phase == .ready, canStart,
              mode != .peerRace || peerConnected else { return }
        if mode == .timeAttack {
            sessionBestLapTime = nil
            sessionBestLapDelta = nil
            sessionSetNewBestLap = false
            bestLapTimeAtStart = bestLapTime
        }
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
        sessionBestLapTime = nil
        sessionBestLapDelta = nil
        sessionSetNewBestLap = false
        bestLapTimeAtStart = nil
        raceTime = 0
        displaySpeed = 0
        playerPosition = 1
        finalPosition = nil
        aiFinishedCount = 0
        peerLocalFinished = false
        peerFinished = false
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

        if mode == .peerRace { updatePeerCar(deltaTime) }

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
            if mode == .race || mode == .peerRace { raceTime += deltaTime }
            if mode == .peerRace, peerLocalFinished {
                coastPlayer(dt, deltaTime: deltaTime)
            } else {
                stepPlayer(dt, deltaTime: deltaTime)
            }
            stepAI(dt)
            separateCars()
            updateGhost()
            updateRanking()
        case .finished:
            coastPlayer(dt, deltaTime: deltaTime)
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
            if let collision = environment.collision(
                from: previous,
                to: proposed,
                heading: physics.heading,
                footprint: roomCarFootprint
            ) {
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

    /// Rolls a finished car to a halt without allowing reverse acceleration.
    private func coastPlayer(_ dt: Float, deltaTime: TimeInterval) {
        let movement = physics.step(
            dt: dt, steeringInput: 0, throttle: false,
            brake: physics.speed > 0.01, offRoad: false
        )
        car.position += movement
        let wallNormal = constrainPlayerToWalls()
        _ = resolvePlayerWallContact(normal: wallNormal, travel: movement)
        car.orientation = simd_quatf(angle: physics.heading, axis: [0, 1, 0])
        updateDriftEffects(deltaTime)
        displaySpeed = Int(abs(physics.speed) * 400)
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
        guard phase == .racing, mode == .timeAttack, ghostEnabled,
              let pose = ghost.best?.pose(at: currentLapTime) else {
            ghostCar.isEnabled = false
            return
        }
        ghostCar.isEnabled = true
        ghostCar.position = pose.position
        ghostCar.orientation = simd_quatf(angle: pose.heading, axis: [0, 1, 0])
    }

    /// Smooths 20 Hz network snapshots at the display frame rate.
    private func updatePeerCar(_ deltaTime: TimeInterval) {
        guard peerConnected, hasPeerCarState else { return }
        let positionBlend = min(1, Float(deltaTime) * 12)
        peerCar.position += (peerTargetPosition - peerCar.position) * positionBlend

        let headingDelta = atan2(
            sin(peerTargetHeading - peerDisplayedHeading),
            cos(peerTargetHeading - peerDisplayedHeading)
        )
        peerDisplayedHeading += headingDelta * min(1, Float(deltaTime) * 14)
        peerCar.orientation = simd_quatf(angle: peerDisplayedHeading, axis: [0, 1, 0])
    }

    private func updateRanking() {
        guard mode == .race || mode == .peerRace else { return }
        if !peerLocalFinished {
            let s = layout.nearestS(to: car.position, near: playerTrackS)
            playerProgress += layout.progressDelta(from: playerTrackS, to: s)
            playerTrackS = s
        }
        if mode == .race {
            playerPosition = aiDrivers.count { $0.progress > playerProgress } + 1
        } else if finalPosition == nil {
            if peerFinished {
                playerPosition = 2
            } else if peerLocalFinished {
                playerPosition = 1
            } else {
                playerPosition = peerProgress > playerProgress ? 2 : 1
            }
        }
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
            sessionBestLapTime = min(sessionBestLapTime ?? currentLapTime, currentLapTime)
            ghost.finishLap(duration: currentLapTime)
            if isBest {
                bestLapTime = currentLapTime
                UserDefaults.standard.set(currentLapTime, forKey: bestLapKey)
            }
            if lapCount >= Self.timeAttackLapTotal {
                if let sessionBestLapTime {
                    if let bestLapTimeAtStart {
                        sessionBestLapDelta = sessionBestLapTime - bestLapTimeAtStart
                        sessionSetNewBestLap = sessionBestLapTime < bestLapTimeAtStart
                    } else {
                        sessionSetNewBestLap = true
                    }
                }
                phase = .finished
                ghostCar.isEnabled = false
                physics.endDrift(rewardBoost: false)
                onEvent?(.timeAttackFinished(isNewBest: sessionSetNewBestLap))
            } else {
                onEvent?(.lapCompleted(isBest: isBest))
                currentLapTime = 0
                ghost.beginLap()
            }
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
        case .peerRace:
            if lapCount >= Self.raceLapTotal {
                peerLocalFinished = true
                physics.endDrift(rewardBoost: false)
                onPeerRaceLocalFinish?(raceTime)
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
        peerCar.removeFromParent()
        peerCar.isEnabled = false
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
        case .peerRace:
            root.isEnabled = true
            roomRoot.isEnabled = false
            movePlayer(to: root)
            car.isEnabled = true
            root.addChild(peerCar)
            let localLateral: Float = peerIsHost ? -0.037 : 0.037
            placePlayer(back: 0.08, lateral: localLateral)
            placePeer(back: 0.08, lateral: -localLateral)
            peerCar.isEnabled = peerConnected
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

    /// Uses synchronized built-in models only for nearby races; the regular
    /// imported player model remains intact for every other game mode.
    private func applyPlayerCarModel(
        customTemplate: Entity? = EntityFactory.customCarTemplate
    ) {
        if mode == .peerRace {
            EntityFactory.populateRaceCar(car, choice: peerLocalCarChoice)
        } else {
            EntityFactory.populate(
                car,
                bodyColor: EntityFactory.playerBodyColor,
                customTemplate: customTemplate
            )
        }
        refreshPlayerCarEffects()
        refreshRoomCarFootprint()
    }

    private func refreshPlayerCarEffects() {
        glowBlue = car.findEntity(named: "glowBlue")
        glowOrange = car.findEntity(named: "glowOrange")
        boostFlame = car.findEntity(named: "boostFlame")
    }

    private func refreshPeerCarEffects() {
        peerGlowBlue = peerCar.findEntity(named: "glowBlue")
        peerGlowOrange = peerCar.findEntity(named: "glowOrange")
        peerBoostFlame = peerCar.findEntity(named: "boostFlame")
    }

    private func applyRoomVisualizationSettings() {
        roomVisualizationRoot?.isEnabled = roomModelVisible
        roomVisualizationRoot?.components.set(
            OpacityComponent(opacity: roomModelOpacity)
        )
    }

    /// Includes imported models and their normalized yaw so collision follows
    /// the body the player actually sees, rather than a fixed center point.
    private func refreshRoomCarFootprint() {
        let effectNames: Set<String> = ["glowBlue", "glowOrange", "boostFlame"]
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        var foundBody = false
        for child in car.children where !effectNames.contains(child.name) {
            let bounds = child.visualBounds(relativeTo: car)
            minimum = simd_min(minimum, bounds.min)
            maximum = simd_max(maximum, bounds.max)
            foundBody = true
        }
        guard foundBody else { return }
        let extents = maximum - minimum
        guard extents.x.isFinite, extents.z.isFinite else { return }
        roomCarFootprint = RoomDriveEnvironment.CarFootprint(
            halfWidth: min(0.065, max(0.026, extents.x / 2)),
            halfLength: min(0.065, max(0.048, extents.z / 2)),
            safetyMargin: 0.012
        )
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

    private func placePeer(back: Float, lateral: Float) {
        let s = layout.startOffset - back
        let grid = layout.sample(at: s)
        let side = SIMD3<Float>(-grid.tangent.z, 0, grid.tangent.x)
        peerCar.position = grid.position + side * lateral
        peerDisplayedHeading = TrackLayout.heading(of: grid.tangent)
        peerTargetPosition = peerCar.position
        peerTargetHeading = peerDisplayedHeading
        peerCar.orientation = simd_quatf(angle: peerDisplayedHeading, axis: [0, 1, 0])
        peerProgress = 0
        peerLapCount = 0
        peerFinished = false
        hasPeerCarState = false
        peerGlowBlue?.isEnabled = false
        peerGlowOrange?.isEnabled = false
        peerBoostFlame?.isEnabled = false
    }
}
