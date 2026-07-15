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
    private enum AppScreen: Equatable {
        case title
        case modeSelection
        case game
    }

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
    @State private var spatialTrackingGeneration: UInt = 0
    @State private var spatialTrackingOperation: Task<Void, Never>?
    @State private var roomScanError: String?
    @State private var courseScaleAtPinchStart: Float?
    @State private var courseRotationAtGestureStart: Float?
    @State private var realityViewSize = CGSize.zero
    @State private var updateSubscription: EventSubscription?
    @State private var screen: AppScreen = .title
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            persistentRealityView
                .opacity(screen == .game ? 1 : 0)
                .allowsHitTesting(screen == .game)
                .accessibilityHidden(screen != .game)

            switch screen {
            case .game:
                GameOverlayView(
                    game: game,
                    multiplayer: multiplayer,
                    roomPlanSupported: roomPlanSupported && !game.virtualModeActive,
                    canScanRoom: canScanRoom,
                    onScanRoom: startRoomScan,
                    onChooseMode: returnToModeSelection,
                    onReturnToTitle: returnToTitle
                )

                if cameraAccessDenied && !game.virtualModeActive {
                    CameraDeniedView { game.activateVirtualMode() }
                }
            case .modeSelection:
                ModeSelectionView(
                    roomDriveAvailable: roomPlanSupported
                        && !game.virtualModeActive
                        && !cameraAccessDenied,
                    onSelect: enterGame,
                    onBack: returnToTitle
                )
                // Keep the top edge fixed while switching from the title.
                .transition(.opacity)
            case .title:
                TitleView(onStart: showModeSelection)
                    .transition(.opacity)
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
            guard screen == .game else { return }
            updateTiltSteering()
        }
        .onChange(of: game.mode) {
            if game.mode != .peerRace, multiplayer.state != .idle {
                multiplayer.disconnect()
            }
        }
        .onChange(of: game.virtualModeActive) {
            guard game.virtualModeActive else { return }
            requestSpatialTrackingStop()
            arSession.pause()
        }
        .onChange(of: scenePhase) {
            if screen == .game, scenePhase == .active {
                refreshCameraAuthorization()
                requestSpatialTracking()
            } else if screen == .game {
                if !showingRoomScan {
                    requestSpatialTrackingStop()
                    arSession.pause()
                }
                if scenePhase == .background, game.mode == .peerRace {
                    multiplayer.disconnect()
                }
            }
        }
        .fullScreenCover(
            isPresented: $showingRoomScan,
            onDismiss: {
                guard screen == .game else { return }
                requestSpatialTracking()
            }
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

    /// Keeps one RealityView and one RealityKit scene alive across title and
    /// mode screens so retained entities never move between scene instances.
    private var persistentRealityView: some View {
        RealityView { content in
            #if targetEnvironment(simulator)
            // No AR passthrough here: fake a floor and look down at the circuit.
            content.add(EntityFactory.makeFallbackGround())
            let camera = Entity(components: PerspectiveCameraComponent())
            camera.look(at: .zero, from: [0, 1.9, 2.4], relativeTo: nil)
            content.add(camera)
            #else
            content.camera = screen == .game && !game.virtualModeActive
                ? .spatialTracking
                : .virtual
            game.cameraRig.components.set(AnchoringComponent(.camera))
            content.add(game.cameraRig)
            #endif

            content.add(game.anchorRoot)
            content.add(game.roomRoot)
            updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                guard screen == .game else { return }
                game.update(deltaTime: event.deltaTime)
                if game.mode == .peerRace {
                    multiplayer.sendCarState(
                        game.peerCarState(), deltaTime: event.deltaTime
                    )
                    peerCourse.updateRelocalization(deltaTime: event.deltaTime)
                }
                audio.setEngine(
                    speedRatio: game.speedRatio,
                    running: game.isEngineRunning,
                    drifting: game.isDrifting
                )
            }
        } update: { content in
            #if !targetEnvironment(simulator)
            content.camera = screen == .game && !game.virtualModeActive
                ? .spatialTracking
                : .virtual
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
    }

    private func showModeSelection() {
        refreshCameraAuthorization()
        withAnimation(.easeInOut(duration: 0.3)) {
            screen = .modeSelection
        }
    }

    private func enterGame(_ mode: RaceGame.Mode) {
        if game.phase != .ready {
            game.reset()
        }
        if multiplayer.state != .idle {
            multiplayer.disconnect()
        }
        game.mode = mode
        #if !targetEnvironment(simulator)
        if game.virtualModeActive || mode == .roomDrive {
            game.removeCourseSurfaceAnchor()
        } else {
            game.installCourseSurfaceAnchor()
        }
        #endif
        withAnimation(.easeInOut(duration: 0.35)) {
            screen = .game
        }
        updateTiltSteering()
        refreshCameraAuthorization()
        requestSpatialTracking()
    }

    private func returnToModeSelection() {
        leaveGame(for: .modeSelection)
    }

    private func returnToTitle() {
        guard screen == .game else {
            withAnimation(.easeInOut(duration: 0.3)) {
                screen = .title
            }
            return
        }
        leaveGame(for: .title)
    }

    /// Stops every live game service before leaving gameplay.
    private func leaveGame(for destination: AppScreen) {
        multiplayer.disconnect()
        tilt.stop()
        game.steeringInput = 0
        game.throttleInput = false
        game.brakeInput = false
        if game.phase != .ready {
            game.reset()
        }
        audio.setEngine(speedRatio: 0, running: false)
        isPreparingRoomScan = false
        courseScaleAtPinchStart = nil
        courseRotationAtGestureStart = nil
        requestSpatialTrackingStop()
        arSession.pause()
        withAnimation(.easeInOut(duration: 0.3)) {
            screen = destination
        }
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
        multiplayer.onCarState = { [weak game] playerID, state in
            game?.applyPeerCarState(playerID: playerID, state: state)
        }
        multiplayer.onLocalCarChoiceChanged = { [weak game] choice in
            game?.setPeerRaceLocalCar(choice)
        }
        multiplayer.onParticipantsChanged = { [weak game] participants, localID in
            game?.configurePeerRaceParticipants(
                participants,
                localPlayerID: localID
            )
        }
        multiplayer.onRemoteImportedCarModel = {
            [weak game, weak multiplayer] playerID, data, flipped, id in
            let temporaryURL = FileManager.default.temporaryDirectory
                .appending(
                    path: "RaceKing-PeerCar-\(playerID.uuidString)-\(id.uuidString).usdz"
                )
            Task {
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                do {
                    try data.write(to: temporaryURL, options: .atomic)
                    let template = try await Entity(contentsOf: temporaryURL)
                    guard let game, let multiplayer,
                          multiplayer.isCurrentRemoteImportedCarModel(
                            playerID: playerID,
                            id: id
                          ) else {
                        return
                    }
                    game.setPeerRaceRemoteImportedCar(
                        playerID: playerID,
                        template: template,
                        flipped: flipped
                    )
                    multiplayer.confirmRemoteImportedCarModel(
                        playerID: playerID,
                        id: id
                    )
                } catch {
                    guard let multiplayer,
                          multiplayer.isCurrentRemoteImportedCarModel(
                            playerID: playerID,
                            id: id
                          ) else {
                        return
                    }
                    multiplayer.failRemoteImportedCarModel(
                        playerID: playerID,
                        id: id,
                        message: "カスタム車を読み込めませんでした: \(error.localizedDescription)"
                    )
                }
            }
        }
        multiplayer.onFinishResult = { [weak game] position, raceTime in
            game?.finishPeerRace(position: position, raceTime: raceTime)
        }
        multiplayer.onConnectionChanged = { [weak peerCourse] connected in
            peerCourse?.connectionChanged(connected)
        }
        game.onPeerRaceLocalFinish = { [weak multiplayer] raceTime in
            multiplayer?.reportLocalFinish(raceTime: raceTime)
        }
        game.setPeerRaceLocalCar(multiplayer.localCarChoice)
        game.configurePeerRaceParticipants(
            multiplayer.participants,
            localPlayerID: multiplayer.localPlayerID
        )
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
            && !isConfiguringSpatialTracking
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
        guard !cameraAccessDenied, !isPreparingRoomScan,
              !isConfiguringSpatialTracking else { return }

        isPreparingRoomScan = true
        enqueueSpatialTrackingOperation { generation in
            await spatialTrackingSession.stop()
            guard generation == spatialTrackingGeneration,
                  isPreparingRoomScan,
                  screen == .game,
                  game.mode == .roomDrive,
                  scenePhase == .active,
                  !showingRoomScan,
                  !game.virtualModeActive,
                  !cameraAccessDenied else {
                isPreparingRoomScan = false
                return
            }
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

    /// Schedules RealityKit tracking after any earlier run/stop operation.
    private func requestSpatialTracking() {
        #if !targetEnvironment(simulator)
        guard screen == .game,
              scenePhase == .active,
              !showingRoomScan,
              !isPreparingRoomScan,
              !game.virtualModeActive,
              !isConfiguringSpatialTracking else { return }
        isConfiguringSpatialTracking = true
        enqueueSpatialTrackingOperation { generation in
            await runSpatialTracking(generation: generation)
        }
        #endif
    }

    /// Stops tracking in the same serial operation chain as startup. A newer
    /// request invalidates the completion of this one before it can mutate AR.
    private func requestSpatialTrackingStop() {
        #if !targetEnvironment(simulator)
        isConfiguringSpatialTracking = false
        isPreparingRoomScan = false
        enqueueSpatialTrackingOperation { generation in
            await spatialTrackingSession.stop()
            guard generation == spatialTrackingGeneration else { return }
            arSession.pause()
        }
        #endif
    }

    /// Runs RealityKit on the same ARSession RoomPlan uses, preserving the
    /// scanned room's world coordinate system when capture finishes.
    private func runSpatialTracking(generation: UInt) async {
        #if !targetEnvironment(simulator)
        defer {
            if generation == spatialTrackingGeneration {
                isConfiguringSpatialTracking = false
            }
        }

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
        guard generation == spatialTrackingGeneration else { return }
        if unavailable?.missingCameraAuthorization == true {
            cameraAccessDenied = true
            return
        }
        guard screen == .game,
              scenePhase == .active,
              !showingRoomScan,
              !isPreparingRoomScan,
              !game.virtualModeActive else { return }
        // With the custom-session overload, the app owns the ARSession
        // lifecycle. SpatialTrackingSession connects it to RealityKit, but
        // doesn't start camera capture on the app's behalf.
        arSession.run(arConfiguration)
        #endif
    }

    /// Serializes SpatialTrackingSession operations and gives each request a
    /// generation token so stale async completions cannot restart tracking.
    private func enqueueSpatialTrackingOperation(
        _ operation: @escaping @MainActor (UInt) async -> Void
    ) {
        spatialTrackingGeneration &+= 1
        let generation = spatialTrackingGeneration
        let previousOperation = spatialTrackingOperation
        spatialTrackingOperation = Task { @MainActor in
            await previousOperation?.value
            guard !Task.isCancelled,
                  generation == spatialTrackingGeneration else { return }
            await operation(generation)
        }
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
