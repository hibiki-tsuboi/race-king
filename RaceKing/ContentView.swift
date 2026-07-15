//
//  ContentView.swift
//  RaceKing
//

import ARKit
import AVFoundation
import RealityKit
import RoomPlan
import SwiftUI

struct ContentView: View {
    @State private var game = RaceGame()
    @State private var audio = GameAudio()
    @State private var haptics = Haptics()
    @State private var tilt = TiltSteering()
    @State private var multiplayer = PeerRaceSession()
    @State private var peerCourse = PeerCourseCoordinator()
    @State private var arSession = ARSession()
    @State private var spatialTrackingSession = SpatialTrackingSession()
    @State private var cameraAccessDenied = false
    @State private var showingRoomScan = false
    @State private var isPreparingRoomScan = false
    @State private var isConfiguringSpatialTracking = false
    @State private var roomScanError: String?
    @State private var courseScaleAtPinchStart: Float?
    @State private var courseRotationAtGestureStart: Float?
    @State private var realityViewSize = CGSize.zero
    @State private var updateSubscription: EventSubscription?
    @State private var hasEnteredGame = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if hasEnteredGame {
                RealityView { content in
                    #if targetEnvironment(simulator)
                    // No AR passthrough here: fake a floor and look down at the circuit.
                    content.add(EntityFactory.makeFallbackGround())
                    let camera = Entity(components: PerspectiveCameraComponent())
                    camera.look(at: .zero, from: [0, 1.9, 2.4], relativeTo: nil)
                    content.add(camera)
                    #else
                    // AR: show the real room and anchor the circuit to the floor.
                    content.camera = .spatialTracking
                    game.installCourseSurfaceAnchor()
                    // Camera pose feed for aim-based course placement.
                    game.cameraRig.components.set(AnchoringComponent(.camera))
                    content.add(game.cameraRig)
                    #endif

                    content.add(game.anchorRoot)
                    content.add(game.roomRoot)
                    updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                        game.update(deltaTime: event.deltaTime)
                        if game.mode == .peerRace {
                            multiplayer.sendCarState(
                                game.peerCarState(), deltaTime: event.deltaTime
                            )
                            peerCourse.updateRelocalization(
                                deltaTime: event.deltaTime
                            )
                        }
                        audio.setEngine(
                            speedRatio: game.speedRatio,
                            running: game.isEngineRunning,
                            drifting: game.isDrifting
                        )
                    }
                } update: { content in
                    #if !targetEnvironment(simulator)
                    // One-way switch to the non-AR presentation.
                    if game.virtualModeActive {
                        content.camera = .virtual
                    }
                    #endif
                }
                #if targetEnvironment(simulator)
                .realityViewCameraControls(.orbit)
                #else
                .realityViewCameraControls(game.virtualModeActive ? .orbit : .none)
                // AR: use the actual touch location rather than the camera center.
                .onTapGesture(coordinateSpace: .local) { location in
                    placeCourse(at: location)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15)
                        .onChanged { value in
                            if game.mode != .roomDrive,
                               courseScaleAtPinchStart == nil,
                               courseRotationAtGestureStart == nil {
                                placeCourse(at: value.location)
                            }
                        }
                )
                .simultaneousGesture(courseScaleGesture)
                .simultaneousGesture(courseRotationGesture)
                #endif
                .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                    realityViewSize = $0
                }
                .ignoresSafeArea()

                GameOverlayView(
                    game: game,
                    multiplayer: multiplayer,
                    roomPlanSupported: roomPlanSupported && !game.virtualModeActive,
                    canScanRoom: canScanRoom,
                    onScanRoom: startRoomScan
                )

                if cameraAccessDenied && !game.virtualModeActive {
                    CameraDeniedView { game.activateVirtualMode() }
                }
            } else {
                TitleView(onStart: enterGame)
            }
        }
        .persistentSystemOverlays(.hidden)
        .task {
            game.onEvent = { event in
                audio.handle(event)
                haptics.handle(event)
            }
            configureMultiplayer()
        }
        .onChange(of: game.tiltSteeringEnabled) {
            guard hasEnteredGame else { return }
            updateTiltSteering()
        }
        .onChange(of: game.mode) {
            if game.mode != .peerRace, multiplayer.state != .idle {
                multiplayer.disconnect()
            }
        }
        .onChange(of: multiplayer.role) {
            if let role = multiplayer.role {
                game.setPeerRole(isHost: role == .host)
            }
        }
        .onChange(of: scenePhase) {
            if hasEnteredGame, scenePhase == .active {
                refreshCameraAuthorization()
                Task { await runSpatialTracking() }
            } else if scenePhase == .background, game.mode == .peerRace {
                multiplayer.disconnect()
            }
        }
        .fullScreenCover(
            isPresented: $showingRoomScan,
            onDismiss: { Task { await runSpatialTracking() } }
        ) {
            RoomScanView(
                arSession: arSession,
                onComplete: finishRoomScan,
                onCancel: { showingRoomScan = false },
                onError: { message in
                    roomScanError = message
                    showingRoomScan = false
                }
            )
        }
        .alert(
            "部屋をスキャンできませんでした",
            isPresented: Binding(
                get: { roomScanError != nil },
                set: { if !$0 { roomScanError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(roomScanError ?? "")
        }
    }

    private func enterGame() {
        withAnimation(.easeInOut(duration: 0.35)) {
            hasEnteredGame = true
        }
        updateTiltSteering()
        refreshCameraAuthorization()
        Task { await runSpatialTracking() }
    }

    private func configureMultiplayer() {
        let game = game
        let multiplayer = multiplayer
        let peerCourse = peerCourse
        peerCourse.configure(
            arSession: arSession,
            game: game,
            multiplayer: multiplayer
        )
        multiplayer.onStartRace = { [weak game] in
            game?.startRace()
        }
        multiplayer.onResetRace = { [weak game] in
            game?.reset()
        }
        multiplayer.onCarState = { [weak game] state in
            game?.applyPeerCarState(state)
        }
        multiplayer.onLocalCarChoiceChanged = { [weak game] choice in
            game?.setPeerRaceLocalCar(choice)
        }
        multiplayer.onRemoteCarChoiceChanged = { [weak game] choice in
            game?.setPeerRaceRemoteCar(choice)
        }
        multiplayer.onFinishResult = { [weak game] position, raceTime in
            game?.finishPeerRace(position: position, raceTime: raceTime)
        }
        multiplayer.onConnectionChanged = { [weak game, weak peerCourse] connected in
            game?.setPeerConnected(connected)
            peerCourse?.connectionChanged(connected)
        }
        game.onPeerRaceLocalFinish = { [weak multiplayer] raceTime in
            multiplayer?.reportLocalFinish(raceTime: raceTime)
        }
        game.setPeerRaceLocalCar(multiplayer.localCarChoice)
        game.setPeerRaceRemoteCar(multiplayer.remoteCarChoice)
    }

    private var roomPlanSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        RoomCaptureSession.isSupported
        #endif
    }

    private var canScanRoom: Bool {
        roomPlanSupported
            && !game.virtualModeActive
            && !cameraAccessDenied
            && !isPreparingRoomScan
    }

    private func refreshCameraAuthorization() {
        #if !targetEnvironment(simulator)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAccessDenied = status == .denied || status == .restricted
        #endif
    }

    private func startRoomScan() {
        guard roomPlanSupported else {
            roomScanError = "部屋フリー走行には、LiDARスキャナを搭載したiPhoneまたはiPadが必要です。"
            return
        }
        guard !game.virtualModeActive else {
            roomScanError = "部屋のスキャンはARなしモードでは利用できません。アプリを再起動してARを有効にしてください。"
            return
        }
        guard !cameraAccessDenied, !isPreparingRoomScan else { return }

        isPreparingRoomScan = true
        Task {
            await spatialTrackingSession.stop()
            showingRoomScan = true
            isPreparingRoomScan = false
        }
    }

    private func finishRoomScan(_ room: CapturedRoom) {
        do {
            game.configureRoom(try RoomDriveEnvironment(capturedRoom: room))
        } catch {
            roomScanError = error.localizedDescription
        }
        showingRoomScan = false
    }

    /// Runs RealityKit on the same ARSession RoomPlan uses, preserving the
    /// scanned room's world coordinate system when capture finishes.
    private func runSpatialTracking() async {
        #if !targetEnvironment(simulator)
        guard !showingRoomScan, !game.virtualModeActive,
              !isConfiguringSpatialTracking else { return }
        isConfiguringSpatialTracking = true
        defer { isConfiguringSpatialTracking = false }

        let spatialConfiguration = SpatialTrackingSession.Configuration(
            tracking: [.camera, .world, .plane],
            sceneUnderstanding: [.shadow, .occlusion],
            camera: .back
        )
        let arConfiguration = PeerCourseCoordinator.worldTrackingConfiguration()
        let unavailable = await spatialTrackingSession.run(
            spatialConfiguration,
            session: arSession,
            arConfiguration: arConfiguration
        )
        if unavailable?.missingCameraAuthorization == true {
            cameraAccessDenied = true
            return
        }
        // With the custom-session overload, the app owns the ARSession
        // lifecycle. SpatialTrackingSession connects it to RealityKit, but
        // doesn't start camera capture on the app's behalf.
        arSession.run(arConfiguration)
        #endif
    }

    #if !targetEnvironment(simulator)
    private var courseScaleGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                guard game.phase == .ready, game.mode != .roomDrive,
                      !game.virtualModeActive, canEditCoursePlacement else {
                    courseScaleAtPinchStart = nil
                    return
                }
                if courseScaleAtPinchStart == nil {
                    courseScaleAtPinchStart = game.courseScale
                }
                guard let initialScale = courseScaleAtPinchStart else { return }
                game.setCourseScale(initialScale * Float(value.magnification))
            }
            .onEnded { _ in
                courseScaleAtPinchStart = nil
            }
    }

    private var courseRotationGesture: some Gesture {
        RotateGesture(minimumAngleDelta: .degrees(0.5))
            .onChanged { value in
                guard game.phase == .ready, game.mode != .roomDrive,
                      !game.virtualModeActive, canEditCoursePlacement else {
                    courseRotationAtGestureStart = nil
                    return
                }
                if courseRotationAtGestureStart == nil {
                    courseRotationAtGestureStart = game.courseRotation
                }
                guard let initialRotation = courseRotationAtGestureStart else { return }
                // SwiftUI angles follow screen coordinates; RealityKit's
                // positive Y rotation runs the opposite way when viewed above.
                game.setCourseRotation(
                    initialRotation - Float(value.rotation.radians)
                )
            }
            .onEnded { _ in
                courseRotationAtGestureStart = nil
            }
    }

    /// Converts the touched viewport point into an AR ray. Normal circuits
    /// use the first horizontal surface hit; RoomPlan intersects the same ray
    /// with its captured floor so both modes honor the visible tap location.
    private func placeCourse(at screenPoint: CGPoint) {
        guard !game.virtualModeActive,
              game.mode == .roomDrive || canEditCoursePlacement,
              realityViewSize.width > 0, realityViewSize.height > 0,
              let frame = arSession.currentFrame else { return }

        let normalizedViewPoint = CGPoint(
            x: max(0, min(1, screenPoint.x / realityViewSize.width)),
            y: max(0, min(1, screenPoint.y / realityViewSize.height))
        )
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .effectiveGeometry.interfaceOrientation ?? .portrait
        let viewToImage = frame.displayTransform(
            for: orientation, viewportSize: realityViewSize
        ).inverted()
        let imagePoint = normalizedViewPoint.applying(viewToImage)
        let query = frame.raycastQuery(
            from: imagePoint, allowing: .estimatedPlane, alignment: .horizontal
        )

        if game.mode == .roomDrive {
            game.placeRoomStart(
                alongRayFrom: query.origin, direction: query.direction
            )
        } else if let result = arSession.raycast(query).first {
            let translation = result.worldTransform.columns.3
            game.moveCourse(toWorldPoint: [
                translation.x, translation.y, translation.z,
            ])
        }
    }
    #endif

    private var canEditCoursePlacement: Bool {
        guard game.mode == .peerRace, multiplayer.state == .connected else {
            return true
        }
        guard multiplayer.role == .host else { return false }
        switch multiplayer.courseSyncState {
        case .hostPlacement, .failed(_):
            return true
        default:
            return false
        }
    }

    private func updateTiltSteering() {
        if game.tiltSteeringEnabled {
            tilt.start { game.steeringInput = $0 }
        } else {
            tilt.stop()
            game.steeringInput = 0
        }
    }
}

/// Shown when camera access was denied: AR cannot run without it,
/// but the game still can, with a virtual camera.
private struct CameraDeniedView: View {
    var onPlayWithoutAR: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
            Text("カメラへのアクセスが必要です")
                .font(.headline.weight(.black))
            Text("AR表示と部屋のスキャンにカメラを使用します。\n設定アプリで許可してください。")
                .font(.callout)
                .multilineTextAlignment(.center)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            } label: {
                Text("設定を開く")
                    .font(.headline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.red.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
            Button {
                onPlayWithoutAR()
            } label: {
                Text("ARなしで遊ぶ")
                    .font(.headline.bold())
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(.blue.gradient, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(26)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
        .padding()
    }
}

#Preview {
    ContentView()
}
