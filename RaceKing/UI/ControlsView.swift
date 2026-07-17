//
//  ControlsView.swift
//  RaceKing
//

import SwiftUI

/// Touch controls: steering on the left, brake and accelerator on the right.
struct ControlsView: View {
    /// Leaves enough steering range for corners without making short taps too sharp.
    private static let touchSteeringStrength: Float = 0.75

    var game: RaceGame
    @State private var steerLeft = false
    @State private var steerRight = false

    var body: some View {
        HStack(alignment: .bottom) {
            if !game.tiltSteeringEnabled {
                HStack(spacing: 16) {
                    HoldButton(
                        systemImage: "steeringwheel.arrowtriangle.left",
                        accessibilityLabel: "左に曲がる",
                        size: 78,
                        isPressed: $steerLeft
                    )
                    HoldButton(
                        systemImage: "steeringwheel.arrowtriangle.right",
                        accessibilityLabel: "右に曲がる",
                        size: 78,
                        isPressed: $steerRight
                    )
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 16) {
                HoldButton(
                    systemImage: brakeSystemImage,
                    pressedSystemImage: pressedBrakeSystemImage,
                    accessibilityLabel: game.speedRatio > 0.01 ? "ブレーキ" : "バック",
                    size: 72,
                    isPressed: brake
                )
                HoldButton(
                    systemImage: "pedal.accelerator",
                    pressedSystemImage: "pedal.accelerator.fill",
                    accessibilityLabel: "アクセル",
                    size: 88,
                    isPressed: throttle
                )
            }
        }
        .onChange(of: steerLeft) { updateSteering() }
        .onChange(of: steerRight) { updateSteering() }
        .onChange(of: game.tiltSteeringEnabled) {
            guard game.tiltSteeringEnabled else { return }
            steerLeft = false
            steerRight = false
        }
        .onDisappear(perform: releaseAllInputs)
    }

    private func updateSteering() {
        let direction = Float((steerRight ? 1 : 0) - (steerLeft ? 1 : 0))
        game.steeringInput = direction * Self.touchSteeringStrength
    }

    private func releaseAllInputs() {
        steerLeft = false
        steerRight = false
        game.steeringInput = 0
        game.throttleInput = false
        game.brakeInput = false
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
    let accessibilityLabel: String
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isPressed ? "押下中" : "停止中")
            .accessibilityHint("実行するたびに押下と解放を切り替えます")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isPressed.toggle() }
            .onDisappear { isPressed = false }
    }
}
