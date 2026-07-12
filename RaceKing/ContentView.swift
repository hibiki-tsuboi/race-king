//
//  ContentView.swift
//  RaceKing
//

import SwiftUI
import RealityKit

struct ContentView: View {
    @State private var game = RaceGame()
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
                }
            }
            #if os(macOS) || (os(iOS) && targetEnvironment(simulator))
            .realityViewCameraControls(.orbit)
            #endif
            .ignoresSafeArea()

            GameOverlayView(game: game)
        }
        .persistentSystemOverlays(.hidden)
    }
}

#Preview {
    ContentView()
}
