//
//  ContentView.swift
//  RaceKing
//

import SwiftUI
import RealityKit

struct ContentView: View {
    @State private var game = RaceGame()
    @State private var audio = GameAudio()
    #if os(iOS)
    @State private var haptics = Haptics()
    @State private var tilt = TiltSteering()
    #endif
    @State private var updateSubscription: EventSubscription?

    var body: some View {
        ZStack {
            RealityView { content in
                #if os(iOS) && !targetEnvironment(simulator)
                // AR: show the real room and anchor the circuit to any floor
                // surface that is at least 0.6 x 0.6 m.
                content.camera = .spatialTracking
                game.root.components.set(AnchoringComponent(
                    .plane(.horizontal, classification: .floor, minimumBounds: [0.6, 0.6])
                ))
                #elseif os(macOS) || os(iOS) || os(tvOS)
                // No AR passthrough here: fake a floor and look down at the circuit.
                content.add(EntityFactory.makeFallbackGround())
                let camera = Entity(components: PerspectiveCameraComponent())
                camera.look(at: .zero, from: [0, 1.1, 1.5], relativeTo: nil)
                content.add(camera)
                #endif

                content.add(game.root)
                updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                    game.update(deltaTime: event.deltaTime)
                    audio.setEngine(
                        speedRatio: game.speedRatio,
                        running: game.isEngineRunning,
                        drifting: game.isDrifting
                    )
                }
            }
            #if os(macOS) || (os(iOS) && targetEnvironment(simulator))
            .realityViewCameraControls(.orbit)
            #endif
            .ignoresSafeArea()

            GameOverlayView(game: game)
        }
        .persistentSystemOverlays(.hidden)
        .task {
            game.onEvent = { event in
                audio.handle(event)
                #if os(iOS)
                haptics.handle(event)
                #endif
            }
            updateTiltSteering()
        }
        .onChange(of: game.tiltSteeringEnabled) { updateTiltSteering() }
    }

    private func updateTiltSteering() {
        #if os(iOS)
        if game.tiltSteeringEnabled {
            tilt.start { game.steeringInput = $0 }
        } else {
            tilt.stop()
            game.steeringInput = 0
        }
        #endif
    }
}

#Preview {
    ContentView()
}
