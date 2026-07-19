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
    @State private var remoteCarModelLoader = RemoteCarModelLoader()
    @State private var arSession = ARSession()
    @State private var arSessionMonitor = ARSessionMonitor()
    @State private var spatialTrackingSession = SpatialTrackingSession()
    @State private var cameraAccessDenied = false
    @State private var showingRoomScan = false
    @State private var isPreparingRoomScan = false
    @State private var isConfiguringSpatialTracking = false
    @State private var isSpatialTrackingSessionRunning = false
    @State private var shouldInstallRoomWorldAnchorOnNextRun = false
    @State private var pendingSpatialTrackingStopCount = 0
    @State private var spatialTrackingGeneration: UInt = 0
    @State private var spatialTrackingOperation: Task<Void, Never>?
    @State private var roomScanError: String?
    @State private var courseDragOffset: SIMD3<Float>?
    @State private var courseScaleAtPinchStart: Float?
    @State private var courseRotationAtGestureStart: Float?
    @State private var realityViewSize = CGSize.zero
    @State private var updateSubscription: EventSubscription?
    @State private var screen: AppScreen = .title
    @State private var arTrackingMessage: String?
    @State private var arCameraTrackingNormal = false
    @State private var appNotice: String?
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
                    canScanRoom: canScanRoom,
                    roomScanUnavailableMessage: roomScanUnavailableMessage,
                    onScanRoom: startRoomScan,
                    onResetCoursePlacement: resetCoursePlacement,
                    onPlaceAtCenter: placeAtCenterAction,
                    onRotateCourseLeft: rotateCourseLeftAction,
                    onRotateCourseRight: rotateCourseRightAction,
                    onScaleCourseDown: scaleCourseDownAction,
                    onScaleCourseUp: scaleCourseUpAction,
                    onChooseMode: returnToModeSelection,
                    onReturnToTitle: returnToTitle
                )

                if cameraAccessDenied && !game.virtualModeActive {
                    CameraDeniedView(
                        allowsPlayWithoutAR: game.mode != .peerRace
                            && game.mode != .roomDrive,
                        requiresRoomScanning: game.mode == .roomDrive,
                        onPlayWithoutAR: activateVirtualModeAfterTrackingFailure,
                        onChooseMode: returnToModeSelection
                    )
                } else if let arTrackingMessage,
                          !game.virtualModeActive {
                    ARRecoveryView(
                        message: arTrackingMessage,
                        allowsPlayWithoutAR: game.mode != .peerRace
                            && game.mode != .roomDrive,
                        onRetry: retryARTracking,
                        onPlayWithoutAR: activateVirtualModeAfterTrackingFailure,
                        onChooseMode: returnToModeSelection
                    )
                }
            case .modeSelection:
                ModeSelectionView(
                    roomDriveAvailable: roomPlanSupported
                        && !game.virtualModeActive
                        && !cameraAccessDenied,
                    peerRaceAvailable: peerRaceAvailable,
                    isPreparing: pendingSpatialTrackingStopCount > 0,
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
            configureARSessionMonitoring()
            await loadPersistedCarModels()
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
        .onChange(of: multiplayer.role) {
            guard screen == .game, game.mode == .peerRace else { return }
            courseDragOffset = nil
            courseScaleAtPinchStart = nil
            courseRotationAtGestureStart = nil
            if multiplayer.role == .host {
                game.cancelSharedCoursePreparation()
            } else {
                game.prepareForSharedCourse()
            }
        }
        .onChange(of: game.canStart) {
            guard screen == .game,
                  game.mode == .peerRace,
                  multiplayer.localReady,
                  !game.canStart else { return }
            multiplayer.setReady(false)
        }
        .onChange(of: game.virtualModeActive) {
            guard game.virtualModeActive else { return }
            requestSpatialTrackingStop()
            arSession.pause()
        }
        .onChange(of: scenePhase) {
            if screen == .game, scenePhase == .active {
                refreshCameraAuthorization()
                updateTiltSteering()
                if game.virtualModeActive {
                    game.resumeSoloRace(for: .appInactive)
                    game.resumeSoloRace(for: .arRecovery)
                } else {
                    _ = game.suspendSoloRace(for: .arRecovery)
                    game.resumeSoloRace(for: .appInactive)
                    requestSpatialTracking()
                    #if targetEnvironment(simulator)
                    game.resumeSoloRace(for: .arRecovery)
                    #endif
                }
            } else if scenePhase != .active {
                if screen == .game {
                    tilt.stop()
                    if game.mode == .peerRace {
                        if multiplayer.state != .idle {
                            appNotice = "アプリがバックグラウンドへ移動したため、ネットワーク対戦から退出しました。"
                        }
                        multiplayer.disconnect()
                    } else {
                        _ = game.suspendSoloRace(for: .appInactive)
                    }
                    clearDrivingInput()
                    audio.setEngine(speedRatio: 0, running: false)
                }
                // Menus keep BGM running, so pause it on every screen.
                audio.pauseMusic()
                if !showingRoomScan {
                    arSession.pause()
                    if scenePhase == .background {
                        requestSpatialTrackingStop()
                    }
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
            roomScanError == nil ? "お知らせ" : "部屋をスキャンできませんでした",
            isPresented: Binding(
                get: { roomScanError != nil || appNotice != nil },
                set: {
                    if !$0 {
                        roomScanError = nil
                        appNotice = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(roomScanError ?? appNotice ?? "")
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
                audio.setMusic(
                    track: currentMusicTrack,
                    suspended: game.isSuspended
                )
                guard screen == .game else { return }
                game.update(deltaTime: event.deltaTime)
                completeARRecoveryIfReady()
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
                    dragCourse(
                        from: value.startLocation,
                        to: value.location
                    )
                }
                .onEnded { _ in
                    courseDragOffset = nil
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

    /// The BGM to loop right now: `opening` on the title/menu screens,
    /// `setting` while preparing a race (course placement, lobby, room
    /// setup), then a random race tune — or the free-drive one — during
    /// play. Results (`finished`) fade to silence.
    private var currentMusicTrack: GameAudio.MusicTrack? {
        if screen != .game { return .opening }
        switch game.phase {
        case .ready:
            return .setting
        case .countdown, .racing:
            return game.mode == .roomDrive ? .free : .race
        case .finished:
            return nil
        }
    }

    private func showModeSelection() {
        refreshCameraAuthorization()
        withAnimation(.easeInOut(duration: 0.3)) {
            screen = .modeSelection
        }
    }

    private func enterGame(_ mode: RaceGame.Mode) {
        guard pendingSpatialTrackingStopCount == 0 else { return }
        #if !targetEnvironment(simulator)
        guard mode != .peerRace || !game.virtualModeActive else { return }
        #endif
        if game.phase != .ready {
            game.reset()
        }
        if multiplayer.state != .idle {
            multiplayer.disconnect()
        }
        clearARRecoveryState()
        let reusesCoursePlacement = game.mode.reusesLocalCoursePlacement
            && mode.reusesLocalCoursePlacement
            && game.hasReusableCoursePlacement
        game.mode = mode
        shouldInstallRoomWorldAnchorOnNextRun = mode == .roomDrive
        #if targetEnvironment(simulator)
        game.resetFallbackCoursePlacement()
        #else
        if game.virtualModeActive {
            game.resetFallbackCoursePlacement()
        } else if mode == .roomDrive {
            game.prepareCourseSurfacePlacement()
            game.removeCourseSurfaceAnchor()
        } else if reusesCoursePlacement,
                  game.resumeReusableCoursePlacement() {
            // The world anchor and course transform survive the solo-mode swap.
        } else {
            game.prepareCourseSurfacePlacement()
        }
        #endif
        if mode == .peerRace {
            // The course stays hidden until this device chooses to host.
            game.prepareForSharedCourse()
        }
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
            if screen == .modeSelection {
                game.prepareCourseSurfacePlacement()
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                screen = .title
            }
            return
        }
        leaveGame(for: .title)
    }

    /// Stops gameplay and AR services before returning to a menu.
    private func leaveGame(for destination: AppScreen) {
        remoteCarModelLoader.cancelAll()
        multiplayer.disconnect()
        tilt.stop()
        clearDrivingInput()
        clearARRecoveryState()
        if game.phase != .ready {
            game.reset()
        }
        audio.setEngine(speedRatio: 0, running: false)
        isPreparingRoomScan = false
        game.clearRoomDriveSetup()
        if destination == .title {
            game.prepareCourseSurfacePlacement()
        }
        courseDragOffset = nil
        courseScaleAtPinchStart = nil
        courseRotationAtGestureStart = nil
        // Camera tracking stops in menus, while a solo world anchor remains
        // available for the next time-attack or CPU-race entry.
        requestSpatialTrackingStop()
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
            game?.startRace() ?? false
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
            [weak game, weak multiplayer, weak remoteCarModelLoader]
            playerID, data, flipped, id in
            remoteCarModelLoader?.enqueue(
                playerID: playerID,
                modelID: id,
                data: data,
                isCurrent: {
                    multiplayer?.isCurrentRemoteImportedCarModel(
                        playerID: playerID,
                        id: id
                    ) == true
                },
                onLoaded: { template in
                    guard let game, let multiplayer else { return }
                    game.setPeerRaceRemoteImportedCar(
                        playerID: playerID,
                        template: template,
                        flipped: flipped
                    )
                    multiplayer.confirmRemoteImportedCarModel(
                        playerID: playerID,
                        id: id
                    )
                },
                onFailure: { message in
                    guard let multiplayer else { return }
                    multiplayer.failRemoteImportedCarModel(
                        playerID: playerID,
                        id: id,
                        message: "カスタム車を読み込めませんでした: \(message)"
                    )
                }
            )
        }
        multiplayer.onFinishResult = { [weak game] position, raceTime in
            game?.finishPeerRace(position: position, raceTime: raceTime)
        }
        multiplayer.onConnectionChanged = { [weak game, weak peerCourse] connected in
            if !connected, let game,
               game.mode == .peerRace, game.phase != .ready {
                game.reset()
            }
            if !connected {
                remoteCarModelLoader.cancelAll()
            }
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

    private func configureARSessionMonitoring() {
        #if !targetEnvironment(simulator)
        arSession.delegate = arSessionMonitor
        arSessionMonitor.onInterrupted = {
            guard screen == .game, scenePhase == .active,
                  !game.virtualModeActive else { return }
            clearDrivingInput()
            arCameraTrackingNormal = false
            audio.setEngine(speedRatio: 0, running: false)
            audio.pauseMusic()
            if game.mode == .peerRace {
                multiplayer.disconnect()
                if game.phase != .ready { game.reset() }
                appNotice = "ARが中断されたため、ネットワーク対戦から退出しました。"
            } else {
                _ = game.suspendSoloRace(for: .arRecovery)
            }
            arTrackingMessage = "ARが中断されました。カメラを再開しています…"
        }
        arSessionMonitor.onInterruptionEnded = {
            guard screen == .game, scenePhase == .active,
                  !game.virtualModeActive else { return }
            arTrackingMessage = "周囲を映してコース位置を復元してください…"
            arCameraTrackingNormal = false
            isSpatialTrackingSessionRunning = false
            requestSpatialTrackingStop()
            requestSpatialTracking()
        }
        arSessionMonitor.onFailure = { message in
            guard screen == .game, !game.virtualModeActive else { return }
            isSpatialTrackingSessionRunning = false
            arCameraTrackingNormal = false
            clearDrivingInput()
            audio.setEngine(speedRatio: 0, running: false)
            audio.pauseMusic()
            if game.mode == .peerRace {
                multiplayer.disconnect()
                if game.phase != .ready { game.reset() }
            } else {
                _ = game.suspendSoloRace(for: .arRecovery)
            }
            if game.mode == .roomDrive {
                if game.phase != .ready { game.reset() }
                game.clearRoomDriveSetup()
                appNotice = "ARの位置を復元できなかったため、部屋をもう一度スキャンしてください。"
            }
            requestSpatialTrackingStop()
            arTrackingMessage = "ARを継続できませんでした。\n\(message)"
        }
        arSessionMonitor.onTrackingNormal = {
            guard screen == .game, scenePhase == .active,
                  !game.virtualModeActive else { return }
            arCameraTrackingNormal = true
            completeARRecoveryIfReady()
        }
        arSessionMonitor.onTrackingLimited = { message in
            guard screen == .game, scenePhase == .active,
                  !game.virtualModeActive else { return }
            arCameraTrackingNormal = false
            _ = game.suspendSoloRace(for: .arRecovery)
            clearDrivingInput()
            audio.setEngine(speedRatio: 0, running: false)
            audio.pauseMusic()
            // Initial placement intentionally has no anchor yet. Keep the
            // placement controls interactive instead of covering them with
            // the full-screen recovery view.
            if game.phase == .ready,
               game.mode != .roomDrive,
               !game.isCoursePlaced {
                arTrackingMessage = nil
            } else {
                arTrackingMessage = message
            }
        }
        #endif
    }

    /// Loads persisted imports one at a time after the first frame. Invalid
    /// files are removed so they cannot create a repeat-launch crash loop.
    private func loadPersistedCarModels() async {
        var discardedModel = false
        let playerURL = EntityFactory.importedCarURL
        do {
            if let template = try await loadPersistedCarModel(at: playerURL) {
                guard !Task.isCancelled else { return }
                EntityFactory.customCarTemplate = template
                game.setCustomCarModel(template)
                multiplayer.refreshLocalImportedCar()
            }
        } catch {
            discardedModel = true
        }

        for index in 0..<EntityFactory.aiCarCount {
            let url = EntityFactory.importedAICarURL(index: index)
            do {
                guard let template = try await loadPersistedCarModel(at: url) else {
                    continue
                }
                guard !Task.isCancelled else { return }
                EntityFactory.aiCarTemplates[index] = template
                game.setAICarModel(template, at: index)
            } catch {
                discardedModel = true
            }
        }
        if discardedModel {
            multiplayer.refreshLocalImportedCar()
            appNotice = "安全に読み込めない保存済み車モデルを削除し、標準モデルへ戻しました。"
        }
    }

    private func loadPersistedCarModel(at url: URL) async throws -> Entity? {
        let manager = FileManager.default
        let loadingURL = EntityFactory.loadingURL(for: url)
        // A leftover loading file means RealityKit did not complete the prior
        // parse. Never feed it to the parser again.
        try? manager.removeItem(at: loadingURL)
        guard manager.fileExists(atPath: url.path) else { return nil }

        try manager.moveItem(at: url, to: loadingURL)
        do {
            try EntityFactory.validateImportedCar(at: loadingURL)
            let template = try await Entity(contentsOf: loadingURL)
            guard !Task.isCancelled else {
                try? manager.removeItem(at: loadingURL)
                return nil
            }
            try EntityFactory.commitImportedCar(
                from: loadingURL,
                to: url
            )
            return template
        } catch {
            try? manager.removeItem(at: loadingURL)
            throw error
        }
    }

    private func clearDrivingInput() {
        game.steeringInput = 0
        game.throttleInput = false
        game.brakeInput = false
    }

    private func clearARRecoveryState() {
        arTrackingMessage = nil
        arCameraTrackingNormal = false
        game.resumeSoloRace(for: .arRecovery)
    }

    private func retryARTracking() {
        guard scenePhase == .active else { return }
        arCameraTrackingNormal = false
        _ = game.suspendSoloRace(for: .arRecovery)
        arTrackingMessage = "周囲を映してコース位置を復元してください…"
        isSpatialTrackingSessionRunning = false
        requestSpatialTracking()
    }

    private func activateVirtualModeAfterTrackingFailure() {
        arTrackingMessage = nil
        arCameraTrackingNormal = false
        game.activateVirtualMode()
        game.resumeSoloRace(for: .arRecovery)
        game.resumeSoloRace(for: .appInactive)
    }

    private func completeARRecoveryIfReady() {
        guard arCameraTrackingNormal,
              screen == .game,
              scenePhase == .active,
              !game.virtualModeActive else { return }
        // A fresh placement has no anchor by design. Only an already placed
        // course can be waiting for its RealityKit anchor to reconnect.
        guard game.mode == .roomDrive
                || !game.isCoursePlaced
                || game.isCourseAnchored else {
            arTrackingMessage = "コース位置を復元しています。元の床やテーブルを映してください…"
            return
        }
        arTrackingMessage = nil
        game.resumeSoloRace(for: .arRecovery)
    }

    private var roomPlanSupported: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        RoomCaptureSession.isSupported
        #endif
    }

    private var peerRaceAvailable: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        !game.virtualModeActive
        #endif
    }

    private var canScanRoom: Bool {
        roomPlanSupported
            && !game.virtualModeActive
            && !cameraAccessDenied
            && !isPreparingRoomScan
            && !isConfiguringSpatialTracking
    }

    private var roomScanUnavailableMessage: String? {
        if !roomPlanSupported {
            return "部屋のスキャンにはLiDAR対応端末が必要です。"
        }
        if cameraAccessDenied {
            return "部屋のスキャンにはカメラの許可が必要です。"
        }
        if game.virtualModeActive {
            return "部屋のスキャンはARなしモードでは利用できません。"
        }
        return nil
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
            isSpatialTrackingSessionRunning = false
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
              !cameraAccessDenied else { return }
        // A mode entry can arrive while RoomPlan's tracking handoff is still
        // configuring. Enqueue it anyway: the generation token suppresses the
        // stale operation and guarantees the latest mode resumes ARSession.
        isConfiguringSpatialTracking = true
        enqueueSpatialTrackingOperation { generation in
            await runSpatialTracking(generation: generation)
        }
        #endif
    }

    /// Stops tracking in the same serial operation chain as startup. A newer
    /// start waits for this entire camera and RealityKit shutdown to finish.
    private func requestSpatialTrackingStop() {
        #if !targetEnvironment(simulator)
        isConfiguringSpatialTracking = false
        isPreparingRoomScan = false
        pendingSpatialTrackingStopCount += 1
        enqueueSpatialTrackingOperation(skipIfSuperseded: false) { _ in
            defer {
                pendingSpatialTrackingStopCount = max(
                    0, pendingSpatialTrackingStopCount - 1
                )
            }
            arSession.pause()
            await spatialTrackingSession.stop()
            isSpatialTrackingSessionRunning = false
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

        let arConfiguration = PeerCourseCoordinator.worldTrackingConfiguration()
        if !isSpatialTrackingSessionRunning {
            let spatialConfiguration = SpatialTrackingSession.Configuration(
                tracking: [.camera, .world, .plane],
                sceneUnderstanding: [.shadow, .occlusion],
                camera: .back
            )
            let unavailable = await spatialTrackingSession.run(
                spatialConfiguration,
                session: arSession,
                arConfiguration: arConfiguration
            )
            if unavailable?.missingCameraAuthorization == true {
                isSpatialTrackingSessionRunning = false
                if generation == spatialTrackingGeneration {
                    cameraAccessDenied = true
                }
                return
            }
            // Record completion before the generation check. If this start was
            // superseded, its queued stop will run next and clear the state.
            isSpatialTrackingSessionRunning = true
        }
        guard generation == spatialTrackingGeneration else { return }
        guard screen == .game,
              scenePhase == .active,
              !showingRoomScan,
              !isPreparingRoomScan,
              !game.virtualModeActive else { return }
        // With the custom-session overload, the app owns the ARSession
        // lifecycle. SpatialTrackingSession connects it to RealityKit, but
        // doesn't start camera capture on the app's behalf.
        // Stopping SpatialTrackingSession is enough to rebuild RealityKit's
        // plane provider at a mode boundary. Resetting the ARSession here can
        // race camera capture startup and leave VIO permanently uninitialized.
        // RoomPlan may temporarily install its own delegate on the shared
        // session, so restore lifecycle monitoring before resuming gameplay.
        arSession.delegate = arSessionMonitor
        arSession.run(arConfiguration)
        if shouldInstallRoomWorldAnchorOnNextRun {
            if game.mode == .roomDrive { game.installRoomWorldAnchor() }
            shouldInstallRoomWorldAnchorOnNextRun = false
        }
        #endif
    }

    /// Serializes SpatialTrackingSession operations and gives each request a
    /// generation token so stale async starts cannot restart tracking. Stops
    /// can opt into running even when superseded so a later start awaits them.
    private func enqueueSpatialTrackingOperation(
        skipIfSuperseded: Bool = true,
        _ operation: @escaping @MainActor (UInt) async -> Void
    ) {
        spatialTrackingGeneration &+= 1
        let generation = spatialTrackingGeneration
        let previousOperation = spatialTrackingOperation
        spatialTrackingOperation = Task { @MainActor in
            await previousOperation?.value
            guard !Task.isCancelled else { return }
            if skipIfSuperseded, generation != spatialTrackingGeneration {
                return
            }
            await operation(generation)
        }
    }

    #if !targetEnvironment(simulator)
    private var courseScaleGesture: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                guard game.phase == .ready, game.mode != .roomDrive,
                      game.isCoursePlaced,
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
                      game.isCoursePlaced,
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

    /// Moves the circuit by the finger's surface delta so grabbing anywhere
    /// on it does not snap its center underneath the touch.
    private func dragCourse(from startPoint: CGPoint, to currentPoint: CGPoint) {
        guard game.phase == .ready, game.mode != .roomDrive,
              (!game.isCoursePlaced || game.isCourseAnchored),
              !game.virtualModeActive,
              canEditCoursePlacement,
              courseScaleAtPinchStart == nil,
              courseRotationAtGestureStart == nil else {
            courseDragOffset = nil
            return
        }
        guard let currentWorldPoint = courseSurfacePoint(at: currentPoint) else {
            return
        }

        if !game.isCoursePlaced {
            courseDragOffset = .zero
            game.moveCourse(toWorldPoint: currentWorldPoint)
            return
        }

        let currentLocalPoint = game.anchorRoot.convert(
            position: currentWorldPoint,
            from: nil
        )
        if courseDragOffset == nil {
            let startWorldPoint = courseSurfacePoint(at: startPoint)
                ?? currentWorldPoint
            let startLocalPoint = game.anchorRoot.convert(
                position: startWorldPoint,
                from: nil
            )
            courseDragOffset = game.root.position - startLocalPoint
        }
        guard let courseDragOffset else { return }
        game.moveCourse(to: currentLocalPoint + courseDragOffset)
    }

    /// Recenters a normal circuit at the touched surface point. RoomPlan uses
    /// the same ray to place its start marker on the captured floor.
    private func placeCourse(at screenPoint: CGPoint) {
        guard !game.virtualModeActive,
              game.mode == .roomDrive || canEditCoursePlacement,
              let query = courseRaycastQuery(at: screenPoint) else { return }

        if game.mode == .roomDrive {
            game.placeRoomStart(
                alongRayFrom: query.origin, direction: query.direction
            )
        } else if let result = arSession.raycast(query).first {
            game.placeCourse(atWorldTransform: result.worldTransform)
        }
    }

    private func courseSurfacePoint(at screenPoint: CGPoint) -> SIMD3<Float>? {
        guard let query = courseRaycastQuery(at: screenPoint),
              let result = arSession.raycast(query).first else { return nil }
        let translation = result.worldTransform.columns.3
        return [translation.x, translation.y, translation.z]
    }

    /// Converts a viewport point into an AR ray against horizontal surfaces.
    private func courseRaycastQuery(at screenPoint: CGPoint) -> ARRaycastQuery? {
        guard realityViewSize.width > 0, realityViewSize.height > 0,
              let frame = arSession.currentFrame else { return nil }

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
        return frame.raycastQuery(
            from: imagePoint, allowing: .estimatedPlane, alignment: .horizontal
        )
    }
    #endif

    private var canEditCoursePlacement: Bool {
        guard game.mode == .peerRace else { return true }
        return multiplayer.canEditHostCourse
    }

    private var placeAtCenterAction: (() -> Void)? {
        #if targetEnvironment(simulator)
        nil
        #else
        { placeCourse(at: CGPoint(
            x: realityViewSize.width / 2,
            y: realityViewSize.height / 2
        )) }
        #endif
    }

    private var rotateCourseLeftAction: (() -> Void)? {
        #if targetEnvironment(simulator)
        nil
        #else
        { adjustCourseRotation(by: -.pi / 12) }
        #endif
    }

    private var rotateCourseRightAction: (() -> Void)? {
        #if targetEnvironment(simulator)
        nil
        #else
        { adjustCourseRotation(by: .pi / 12) }
        #endif
    }

    private var scaleCourseDownAction: (() -> Void)? {
        #if targetEnvironment(simulator)
        nil
        #else
        { adjustCourseScale(by: 0.9) }
        #endif
    }

    private var scaleCourseUpAction: (() -> Void)? {
        #if targetEnvironment(simulator)
        nil
        #else
        { adjustCourseScale(by: 1.1) }
        #endif
    }

    private func adjustCourseRotation(by amount: Float) {
        guard game.phase == .ready, game.mode != .roomDrive,
              game.isCoursePlaced, !game.virtualModeActive,
              canEditCoursePlacement else { return }
        game.setCourseRotation(game.courseRotation + amount)
    }

    private func adjustCourseScale(by factor: Float) {
        guard game.phase == .ready, game.mode != .roomDrive,
              game.isCoursePlaced, !game.virtualModeActive,
              canEditCoursePlacement else { return }
        game.setCourseScale(game.courseScale * factor)
    }

    /// Clears an editable course placement; the next valid surface tap creates it.
    private func resetCoursePlacement() {
        let canResetPeerPlacement = game.mode == .peerRace
            && multiplayer.canEditHostCourse
            && game.isCoursePlaced
        guard screen == .game,
              game.phase == .ready,
              game.mode.reusesLocalCoursePlacement || canResetPeerPlacement,
              !game.virtualModeActive else { return }
        courseDragOffset = nil
        courseScaleAtPinchStart = nil
        courseRotationAtGestureStart = nil
        arTrackingMessage = nil
        game.resumeSoloRace(for: .arRecovery)
        game.prepareCourseSurfacePlacement()
    }

    private func updateTiltSteering() {
        if game.tiltSteeringEnabled {
            let started = tilt.start(
                orientation: { currentInterfaceOrientation },
                onSteer: { game.steeringInput = $0 },
                onUnavailable: {
                    game.steeringInput = 0
                    if game.tiltSteeringEnabled {
                        game.tiltSteeringEnabled = false
                        appNotice = "傾きセンサーを利用できないため、タッチ操作へ戻しました。"
                    }
                }
            )
            if !started {
                game.steeringInput = 0
            }
        } else {
            tilt.stop()
            game.steeringInput = 0
        }
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .effectiveGeometry.interfaceOrientation ?? .portrait
    }
}

/// Shown when camera access was denied. Solo modes can fall back to a virtual
/// camera, while network play must return to an AR-capable state.
private struct CameraDeniedView: View {
    var allowsPlayWithoutAR = true
    var requiresRoomScanning = false
    var onPlayWithoutAR: () -> Void
    var onChooseMode: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.largeTitle)
                    .accessibilityHidden(true)
                Text("カメラへのアクセスが必要です")
                    .font(.headline.bold())
                Text(cameraMessage)
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
                if allowsPlayWithoutAR {
                    Button {
                        onPlayWithoutAR()
                    } label: {
                        Text("ARなしのタイムアタックで遊ぶ")
                            .font(.headline.bold())
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(.blue.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onChooseMode) {
                        Label("モード選択に戻る", systemImage: "chevron.left")
                            .font(.headline.bold())
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
            }
            .foregroundStyle(.white)
            .padding(26)
            .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var cameraMessage: String {
        if requiresRoomScanning {
            return "フリー走行の部屋スキャンにはカメラとARが必要です。\n設定アプリで許可してください。"
        }
        if allowsPlayWithoutAR {
            return "AR表示にカメラを使用します。\n許可するか、ARなしのタイムアタックへ切り替えてください。"
        }
        return "ネットワーク対戦にはカメラとARが必要です。\n設定アプリで許可してください。"
    }
}

private struct ARRecoveryView: View {
    let message: String
    var allowsPlayWithoutAR = false
    var onRetry: () -> Void
    var onPlayWithoutAR: () -> Void
    var onChooseMode: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text("ARを再調整しています")
                    .font(.headline.weight(.black))
                Text(message)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("再試行", action: onRetry)
                    .buttonStyle(.borderedProminent)
                if allowsPlayWithoutAR {
                    Button("ARなしのタイムアタックへ切り替える", action: onPlayWithoutAR)
                        .buttonStyle(.bordered)
                }
                Button("モード選択に戻る", action: onChooseMode)
                    .buttonStyle(.bordered)
            }
            .foregroundStyle(.white)
            .padding(26)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

#Preview {
    ContentView()
}
