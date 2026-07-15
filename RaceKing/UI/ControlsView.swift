//
//  ControlsView.swift
//  RaceKing
//

import SwiftUI

/// Touch controls: steering on the left, brake and accelerator on the right.
struct ControlsView: View {
    var game: RaceGame
    @State private var steerLeft = false
    @State private var steerRight = false

    var body: some View {
        HStack(alignment: .bottom) {
            if !game.tiltSteeringEnabled {
                HStack(spacing: 16) {
                    HoldButton(systemImage: "steeringwheel.arrowtriangle.left", size: 78, isPressed: $steerLeft)
                    HoldButton(systemImage: "steeringwheel.arrowtriangle.right", size: 78, isPressed: $steerRight)
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 16) {
                HoldButton(
                    systemImage: brakeSystemImage,
                    pressedSystemImage: pressedBrakeSystemImage,
                    size: 72,
                    isPressed: brake
                )
                HoldButton(
                    systemImage: "pedal.accelerator",
                    pressedSystemImage: "pedal.accelerator.fill",
                    size: 88,
                    isPressed: throttle
                )
            }
        }
        .onChange(of: steerLeft) { updateSteering() }
        .onChange(of: steerRight) { updateSteering() }
    }

    private func updateSteering() {
        game.steeringInput = (steerRight ? 1 : 0) - (steerLeft ? 1 : 0)
    }

    private var throttle: Binding<Bool> {
        Binding { game.throttleInput } set: { game.throttleInput = $0 }
    }

    private var brake: Binding<Bool> {
        Binding { game.brakeInput } set: { game.brakeInput = $0 }
    }

    private var brakeSystemImage: String {
        game.speedRatio > 0.01 ? "pedal.brake" : "r.square"
    }

    private var pressedBrakeSystemImage: String {
        game.speedRatio > 0.01 ? "pedal.brake.fill" : "r.square.fill"
    }
}

/// A round button that reports being held down, like a physical pedal.
struct HoldButton: View {
    let systemImage: String
    var pressedSystemImage: String? = nil
    var size: CGFloat = 70
    var tint: Color = .white
    @Binding var isPressed: Bool

    var body: some View {
        Image(systemName: isPressed ? (pressedSystemImage ?? systemImage) : systemImage)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                tint.opacity(isPressed ? 0.75 : 0.35),
                in: Circle()
            )
            .overlay(Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1.5))
            .scaleEffect(isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}
