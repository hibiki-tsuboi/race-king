//
//  ContentView.swift
//  RaceKing
//

import SwiftUI
import RealityKit
import AVFoundation

struct ContentView: View {
    @State private var game = RaceGame()
    @State private var audio = GameAudio()
    @State private var haptics = Haptics()
    @State private var tilt = TiltSteering()
    @State private var cameraAccessDenied = false
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
                game.installFloorAnchor()
                // Camera pose feed for aim-based course placement.
                game.cameraRig.components.set(AnchoringComponent(.camera))
                content.add(game.cameraRig)
                #endif

                content.add(game.anchorRoot)
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
            // AR: tap moves the course to the aimed floor point; holding a
            // drag carries it along the aim continuously.
            .onTapGesture { moveCourseTowardAim() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 15)
                    .onChanged { _ in moveCourseTowardAim() }
            )
            #endif
            .ignoresSafeArea()

            GameOverlayView(game: game)

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
        }
        .onChange(of: game.tiltSteeringEnabled) { updateTiltSteering() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { refreshCameraAuthorization() }
        }
    }

    private func refreshCameraAuthorization() {
        #if !targetEnvironment(simulator)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        cameraAccessDenied = status == .denied || status == .restricted
        #endif
    }

    #if !targetEnvironment(simulator)
    /// Casts the camera's aim onto the floor and moves the course there.
    private func moveCourseTowardAim() {
        guard !game.virtualModeActive else { return }
        let transform = game.cameraRig.transformMatrix(relativeTo: nil)
        let origin = SIMD3<Float>(
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z
        )
        let forward = -SIMD3<Float>(
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z
        )
        game.moveCourse(alongRayFrom: origin, direction: forward)
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
            Text("ARでレースコースを床に表示するために\nカメラを使用します。設定アプリで許可してください。")
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
