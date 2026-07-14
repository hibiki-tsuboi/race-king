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
    @State private var arSession = ARSession()
    @State private var spatialTrackingSession = SpatialTrackingSession()
    @State private var cameraAccessDenied = false
    @State private var showingRoomScan = false
    @State private var isPreparingRoomScan = false
    @State private var isConfiguringSpatialTracking = false
    @State private var roomScanError: String?
    @State private var courseScaleAtPinchStart: Float?
    @State private var realityViewSize = CGSize.zero
    @State private var updateSubscription: EventSubscription?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
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
                        if game.mode != .roomDrive { placeCourse(at: value.location) }
                    }
            )
            .simultaneousGesture(courseScaleGesture)
            #endif
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                realityViewSize = $0
            }
            .ignoresSafeArea()

            GameOverlayView(
                game: game,
                roomPlanSupported: roomPlanSupported && !game.virtualModeActive,
                canScanRoom: canScanRoom,
                onScanRoom: startRoomScan
            )

            if cameraAccessDenied && !game.virtualModeActive {
                CameraDeniedView { game.activateVirtualMode() }
            }
        }
        .persistentSystemOverlays(.hidden)
        .task {
            game.onEvent = { event in
                audio.handle(event)
                haptics.handle(event)
            }
            updateTiltSteering()
            refreshCameraAuthorization()
            await runSpatialTracking()
        }
        .onChange(of: game.tiltSteeringEnabled) { updateTiltSteering() }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                refreshCameraAuthorization()
                Task { await runSpatialTracking() }
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
        let arConfiguration = ARWorldTrackingConfiguration()
        arConfiguration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            arConfiguration.sceneReconstruction = .mesh
        }
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
                      !game.virtualModeActive else {
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

    /// Converts the touched viewport point into an AR ray. Normal circuits
    /// use the first horizontal surface hit; RoomPlan intersects the same ray
    /// with its captured floor so both modes honor the visible tap location.
    private func placeCourse(at screenPoint: CGPoint) {
        guard !game.virtualModeActive,
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
