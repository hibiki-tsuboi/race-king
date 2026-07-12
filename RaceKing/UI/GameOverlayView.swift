//
//  GameOverlayView.swift
//  RaceKing
//

import SwiftUI

/// HUD, touch controls, countdown, and start button layered over the AR view.
struct GameOverlayView: View {
    var game: RaceGame

    var body: some View {
        ZStack {
            VStack {
                HUDView(game: game)
                Spacer()
                ControlsView(game: game)
            }
            .padding()

            centerMessage
        }
    }

    @ViewBuilder
    private var centerMessage: some View {
        switch game.phase {
        case .ready:
            VStack(spacing: 16) {
                #if os(iOS) && !targetEnvironment(simulator)
                Text("端末を動かして床を映すと\nコースが置かれます")
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                #endif
                Button {
                    game.startRace()
                } label: {
                    Text("START")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 14)
                        .background(.red.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        case .countdown:
            Text("\(game.countdownValue)")
                .font(.system(size: 130, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 8)
                .contentTransition(.numericText(countsDown: true))
                .animation(.snappy, value: game.countdownValue)
        case .racing:
            if game.lapCount == 0 && game.currentLapTime < 0.9 {
                Text("GO!")
                    .font(.system(size: 100, weight: .black, design: .rounded))
                    .foregroundStyle(.yellow)
                    .shadow(color: .black.opacity(0.6), radius: 8)
            }
        }
    }
}

/// Lap counter and timers along the top edge.
struct HUDView: View {
    var game: RaceGame

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.phase == .racing ? "LAP \(game.lapCount + 1)" : "LAP –")
                    .font(.headline.weight(.black))
                Text(lapTimeString(game.currentLapTime))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let last = game.lastLapTime {
                    Text("LAST  \(lapTimeString(last))")
                        .font(.caption.bold())
                        .monospacedDigit()
                }
                if let best = game.bestLapTime {
                    Text("BEST  \(lapTimeString(best))")
                        .font(.caption.bold())
                        .monospacedDigit()
                        .foregroundStyle(.purple)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                if game.phase != .ready {
                    Button {
                        game.reset()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.title3.bold())
                            .padding(10)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Text("\(game.displaySpeed) km/h")
                    .font(.title3.weight(.heavy))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private func lapTimeString(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let hundredths = Int(time * 100) % 100
        return String(format: "%d:%02d.%02d", minutes, seconds, hundredths)
    }
}
