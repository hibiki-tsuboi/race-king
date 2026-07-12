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
            if !game.isCourseAnchored {
                // AR is still scanning: no course to race on yet.
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("床を探しています…\n端末をゆっくり動かして床を映してください")
                        .font(.callout.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .padding(22)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
            } else {
                readyMenu
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

    private var readyMenu: some View {
        VStack(spacing: 18) {
                #if !targetEnvironment(simulator)
                Text("床に向けてタップでコース移動\n長押しドラッグで追従")
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
        // Sit above the circuit so the menu doesn't hide the grid
        // or the placement reticle at the screen center.
        .offset(y: -150)
    }
}

/// Lap counter, timers, race position, and settings along the top edge.
struct HUDView: View {
    /// Which car the next file import applies to.
    private enum CarImportSlot {
        case player
        case ai(Int)
    }

    @Bindable var game: RaceGame
    @State private var showingCarImporter = false
    @State private var importSlot: CarImportSlot = .player
    @State private var importErrorMessage: String?

    var body: some View {
        hudContent
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
                    #if !targetEnvironment(simulator)
                    if game.phase == .ready {
                        // Spins the course a quarter turn on the floor.
                        Button {
                            game.rotateCourse()
                        } label: {
                            Image(systemName: "rotate.right")
                                .font(.title3.bold())
                                .padding(10)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    #endif
                    Menu {
                        Toggle("傾きで操作", isOn: $game.tiltSteeringEnabled)
                        Toggle("ゴースト表示", isOn: $game.ghostEnabled)
                        Divider()
                        Button {
                            importSlot = .player
                            showingCarImporter = true
                        } label: {
                            Label("自分の車を読み込む…", systemImage: "square.and.arrow.down")
                        }
                        Menu {
                            ForEach(0..<3, id: \.self) { index in
                                Button("AI \(index + 1)…") {
                                    importSlot = .ai(index)
                                    showingCarImporter = true
                                }
                            }
                        } label: {
                            Label("AIの車を読み込む", systemImage: "square.and.arrow.down.on.square")
                        }
                        if hasAnyCustomCar {
                            Button {
                                EntityFactory.customCarFlipped.toggle()
                                reapplyCustomCars()
                            } label: {
                                Label("車の前後を反転", systemImage: "arrow.left.arrow.right")
                            }
                            Button("すべて標準の車に戻す") { revertCarModels() }
                        }
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

    private var hasAnyCustomCar: Bool {
        EntityFactory.customCarTemplate != nil
            || EntityFactory.aiCarTemplates.contains { $0 != nil }
    }

    /// Copies the picked USDZ into app storage and applies it to the car
    /// slot the user chose in the menu.
    private func importCarModel(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let destination: URL
        switch importSlot {
        case .player: destination = EntityFactory.importedCarURL
        case .ai(let index): destination = EntityFactory.importedAICarURL(index: index)
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            let template = try Entity.load(contentsOf: destination)
            switch importSlot {
            case .player:
                EntityFactory.customCarFlipped = false
                EntityFactory.customCarTemplate = template
                game.setCustomCarModel(template)
            case .ai(let index):
                EntityFactory.aiCarTemplates[index] = template
                game.setAICarModel(template, at: index)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            importErrorMessage = error.localizedDescription
        }
    }

    /// Re-populates every custom car, e.g. after toggling the flip setting.
    private func reapplyCustomCars() {
        game.setCustomCarModel(EntityFactory.customCarTemplate)
        for (index, template) in EntityFactory.aiCarTemplates.enumerated() where template != nil {
            game.setAICarModel(template, at: index)
        }
    }

    /// Deletes imported files and restores the bundled default cars.
    private func revertCarModels() {
        try? FileManager.default.removeItem(at: EntityFactory.importedCarURL)
        let bundled = try? Entity.load(named: "PlayerCar")
        EntityFactory.customCarTemplate = bundled
        game.setCustomCarModel(bundled)
        for index in EntityFactory.aiCarTemplates.indices {
            try? FileManager.default.removeItem(at: EntityFactory.importedAICarURL(index: index))
            let template = EntityFactory.bundledAICarTemplate(index: index)
            EntityFactory.aiCarTemplates[index] = template
            game.setAICarModel(template, at: index)
        }
    }
}

func lapTimeString(_ time: TimeInterval) -> String {
    let minutes = Int(time) / 60
    let seconds = Int(time) % 60
    let hundredths = Int(time * 100) % 100
    return String(format: "%d:%02d.%02d", minutes, seconds, hundredths)
}
