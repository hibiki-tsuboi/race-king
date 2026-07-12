//
//  GameOverlayView.swift
//  RaceKing
//

import SwiftUI
import RealityKit
import UniformTypeIdentifiers

/// HUD, touch controls, countdown, mode select, and results layered over the AR view.
struct GameOverlayView: View {
    @Bindable var game: RaceGame

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
            VStack(spacing: 18) {
                #if os(iOS) && !targetEnvironment(simulator)
                Text("端末を動かして床を映すと\nコースが置かれます")
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                #endif

                Picker("モード", selection: $game.mode) {
                    Text("タイムアタック").tag(RaceGame.Mode.timeAttack)
                    Text("VS AIレース").tag(RaceGame.Mode.race)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 290)
                .padding(6)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                Text("コーナー中にブレーキをタップでドリフト!\n長く滑るほどミニターボ")
                    .font(.caption.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

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
            // Sit above the circuit so the menu doesn't hide the grid.
            .offset(y: -150)
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
        case .finished:
            VStack(spacing: 12) {
                Text("🏁 FINISH!")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                if let position = game.finalPosition {
                    Text("\(position)位")
                        .font(.system(size: 84, weight: .black, design: .rounded))
                        .foregroundStyle(position == 1 ? .yellow : .white)
                }
                Text("TIME  \(lapTimeString(game.raceTime))")
                    .font(.title3.bold())
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Button {
                    game.reset()
                } label: {
                    Text("もう一度")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(.red.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(28)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

/// Lap counter, timers, race position, and settings along the top edge.
struct HUDView: View {
    @Bindable var game: RaceGame
    @State private var showingCarImporter = false
    @State private var importErrorMessage: String?

    var body: some View {
        hudContent
        #if !os(tvOS)
            .fileImporter(
                isPresented: $showingCarImporter,
                allowedContentTypes: [.usdz]
            ) { result in
                if case .success(let url) = result {
                    importCarModel(from: url)
                }
            }
            .alert(
                "モデルを読み込めませんでした",
                isPresented: Binding(
                    get: { importErrorMessage != nil },
                    set: { if !$0 { importErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "")
            }
        #endif
    }

    private var hudContent: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lapLabel)
                    .font(.headline.weight(.black))
                Text(lapTimeString(game.currentLapTime))
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if game.mode == .timeAttack {
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
            }

            Spacer()

            if game.mode == .race && game.phase == .racing {
                Text("\(game.playerPosition)位")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                Spacer()
            }

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
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
                    Menu {
                        #if os(iOS)
                        Toggle("傾きで操作", isOn: $game.tiltSteeringEnabled)
                        #endif
                        Toggle("ゴースト表示", isOn: $game.ghostEnabled)
                        #if !os(tvOS)
                        Divider()
                        Button {
                            showingCarImporter = true
                        } label: {
                            Label("車の3Dモデルを読み込む…", systemImage: "square.and.arrow.down")
                        }
                        if EntityFactory.customCarTemplate != nil {
                            Button {
                                EntityFactory.customCarFlipped.toggle()
                                game.setCustomCarModel(EntityFactory.customCarTemplate)
                            } label: {
                                Label("車の前後を反転", systemImage: "arrow.left.arrow.right")
                            }
                            Button("標準の車に戻す") { revertCarModel() }
                        }
                        #endif
                    } label: {
                        Image(systemName: "gearshape.fill")
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

    private var lapLabel: String {
        switch game.mode {
        case .timeAttack:
            return game.phase == .racing ? "LAP \(game.lapCount + 1)" : "LAP –"
        case .race:
            let current = min(game.lapCount + 1, RaceGame.raceLapTotal)
            return "LAP \(current)/\(RaceGame.raceLapTotal)"
        }
    }

    #if !os(tvOS)
    /// Copies the picked USDZ into app storage and applies it immediately.
    private func importCarModel(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let destination = EntityFactory.importedCarURL
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            let template = try Entity.load(contentsOf: destination)
            EntityFactory.customCarFlipped = false
            EntityFactory.customCarTemplate = template
            game.setCustomCarModel(template)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            importErrorMessage = error.localizedDescription
        }
    }

    private func revertCarModel() {
        try? FileManager.default.removeItem(at: EntityFactory.importedCarURL)
        let bundled = try? Entity.load(named: "PlayerCar")
        EntityFactory.customCarTemplate = bundled
        game.setCustomCarModel(bundled)
    }
    #endif
}

func lapTimeString(_ time: TimeInterval) -> String {
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    let hundredths = Int(time * 100) % 100
    return String(format: "%d:%02d.%02d", minutes, seconds, hundredths)
}
