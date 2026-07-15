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
    @Bindable var multiplayer: PeerRaceSession
    var roomPlanSupported = false
    var canScanRoom = false
    var onScanRoom: () -> Void = {}

    var body: some View {
        ZStack {
            VStack {
                HUDView(game: game, onReset: resetRace)
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
            if game.mode != .roomDrive && !game.isCourseAnchored
                && !(game.mode == .peerRace && multiplayer.state == .connected) {
                // AR is still scanning: no horizontal course surface yet.
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("床やテーブルを探しています…\n設置したい面をゆっくり映してください")
                        .font(.callout.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                    if roomPlanSupported && canScanRoom {
                        Button {
                            game.mode = .roomDrive
                            onScanRoom()
                        } label: {
                            Label("部屋をスキャンしてフリー走行", systemImage: "viewfinder")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 10)
                                .background(.blue.gradient, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if game.canOfferVirtualMode {
                        Button {
                            game.activateVirtualMode()
                        } label: {
                            Text("ARなしで遊ぶ")
                                .font(.headline.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 10)
                                .background(.blue.gradient, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
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
                finishedDetails
                if game.mode == .peerRace && !multiplayer.raceComplete {
                    Text("相手のゴールを待っています…")
                        .font(.callout.bold())
                        .foregroundStyle(.yellow)
                }
                Button(action: resetRace) {
                    Text("もう一度")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(.red.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(game.mode == .peerRace && !multiplayer.raceComplete)
            }
            .padding(28)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        }
    }

    @ViewBuilder
    private var finishedDetails: some View {
        switch game.mode {
        case .timeAttack:
            if let sessionBest = game.sessionBestLapTime {
                Text("今回のベスト")
                    .font(.caption.bold())
                    .foregroundStyle(.white.opacity(0.8))
                Text(lapTimeString(sessionBest))
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                if game.sessionSetNewBestLap {
                    Text("NEW RECORD!")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.yellow)
                }
                if let delta = game.sessionBestLapDelta {
                    Text("自己ベスト差  \(signedLapTimeString(delta))")
                        .font(.callout.bold())
                        .monospacedDigit()
                        .foregroundStyle(delta < 0 ? .green : .white)
                }
            }
        case .race, .peerRace:
            if let position = game.finalPosition {
                Text("\(position)位")
                    .font(.system(size: 84, weight: .black, design: .rounded))
                    .foregroundStyle(position == 1 ? .yellow : .white)
            }
            Text("TIME  \(lapTimeString(game.raceTime))")
                .font(.title3.bold())
                .monospacedDigit()
                .foregroundStyle(.white)
        case .roomDrive:
            EmptyView()
        }
    }

    private func signedLapTimeString(_ time: TimeInterval) -> String {
        let sign = time < 0 ? "−" : "+"
        return sign + lapTimeString(abs(time))
    }

    private var readyMenu: some View {
        VStack(spacing: 14) {
                #if !targetEnvironment(simulator)
                Text(placementInstruction)
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                #endif

                Picker("モード", selection: $game.mode) {
                    Text("TIME").tag(RaceGame.Mode.timeAttack)
                    Text("VS AI").tag(RaceGame.Mode.race)
                    Text("2人").tag(RaceGame.Mode.peerRace)
                    if roomPlanSupported {
                        Text("部屋").tag(RaceGame.Mode.roomDrive)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: roomPlanSupported ? 360 : 330)
                .padding(6)
                .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))

                if game.mode == .peerRace {
                    PeerRaceLobbyView(multiplayer: multiplayer)
                } else if game.mode == .roomDrive {
                    roomDriveSetup
                }

                if game.mode != .peerRace && game.canStart {
                    Button {
                        game.startRace()
                    } label: {
                        Text(game.mode == .roomDrive ? "フリー走行" : "START")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 44)
                            .padding(.vertical, 14)
                            .background(.red.gradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
        }
        // Anchored below the HUD instead of screen-centered, so it never
        // collides with the HUD on small screens and leaves the grid visible.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 170)
    }

    private var placementInstruction: String {
        if game.mode == .roomDrive {
            return game.hasScannedRoom
                ? "床に向けてタップでスタート位置を決定"
                : "まず部屋をスキャンしてください"
        }
        if game.mode == .peerRace, multiplayer.state == .connected {
            if multiplayer.role == .guest {
                return "ホストと同じ机・床を映してコースを位置合わせ"
            }
            if multiplayer.isCourseSynchronized {
                return "共有したコースで2台同時にレースします"
            }
            return "ホスト側でコースを配置してから共有"
        }
        return "床やテーブルをタップしてコース移動\nドラッグで移動・二本指でサイズ／向き調整"
    }

    private func resetRace() {
        if game.mode == .peerRace, multiplayer.state == .connected {
            multiplayer.requestResetRace()
        } else {
            game.reset()
        }
    }

    @ViewBuilder
    private var roomDriveSetup: some View {
        if game.hasScannedRoom {
            VStack(spacing: 8) {
                Text("障害物を \(game.roomObstacleCount) 個検出")
                    .font(.caption.bold())
                if game.roomStartPlaced {
                    Label("スタート位置を設定しました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("家具や壁から離れた床をタップしてください")
                        .multilineTextAlignment(.center)
                }

                Divider()
                    .overlay(.white.opacity(0.25))

                Toggle(isOn: $game.roomModelVisible) {
                    Label("スキャンモデルを表示", systemImage: "cube.transparent")
                }
                .tint(.cyan)

                if game.roomModelVisible {
                    HStack(spacing: 8) {
                        Text("表示濃度")
                        Slider(
                            value: $game.roomModelOpacity,
                            in: RaceGame.minimumRoomModelOpacity...RaceGame.maximumRoomModelOpacity
                        )
                        .tint(.cyan)
                        .frame(width: 120)
                        Text("\(Int(game.roomModelOpacity * 100))%")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            Button("部屋をスキャンし直す", action: onScanRoom)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(!canScanRoom)
        } else if canScanRoom {
            Button(action: onScanRoom) {
                Label("部屋をスキャン", systemImage: "viewfinder")
                    .font(.headline.bold())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        } else {
            Text("部屋のスキャンはARなしモードでは利用できません")
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
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
    var onReset: () -> Void = {}
    @State private var showingCarImporter = false
    @State private var importSlot: CarImportSlot = .player
    @State private var importErrorMessage: String?
    @State private var isImportingCar = false

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
                if game.mode == .peerRace {
                    let peerLap = min(game.peerLapCount + 1, RaceGame.raceLapTotal)
                    Text("相手 LAP \(peerLap)/\(RaceGame.raceLapTotal)")
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                }
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

            if (game.mode == .race || game.mode == .peerRace)
                && game.phase == .racing {
                Text("\(game.playerPosition)位")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                Spacer()
            }

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if game.phase != .ready {
                        Button(action: onReset) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title3.bold())
                                .padding(10)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }
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
                        Divider()
                        Text(appVersionText)
                    } label: {
                        Group {
                            if isImportingCar {
                                ProgressView()
                                    .tint(.white)
                                    .font(.title3)
                            } else {
                                Image(systemName: "gearshape.fill")
                                    .font(.title3.bold())
                            }
                        }
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isImportingCar)
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
            let current = min(game.lapCount + 1, RaceGame.timeAttackLapTotal)
            return "LAP \(current)/\(RaceGame.timeAttackLapTotal)"
        case .race:
            let current = min(game.lapCount + 1, RaceGame.raceLapTotal)
            return "LAP \(current)/\(RaceGame.raceLapTotal)"
        case .peerRace:
            let current = min(game.lapCount + 1, RaceGame.raceLapTotal)
            return "LAP \(current)/\(RaceGame.raceLapTotal)"
        case .roomDrive:
            return "FREE DRIVE"
        }
    }

    private var appVersionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, !build.isEmpty else {
            return "バージョン \(version)"
        }
        return "バージョン \(version)（\(build)）"
    }

    private var hasAnyCustomCar: Bool {
        EntityFactory.customCarTemplate != nil
            || EntityFactory.aiCarTemplates.contains { $0 != nil }
    }

    /// Copies the picked USDZ into app storage and applies it to the car
    /// slot the user chose in the menu. Loading runs asynchronously so a
    /// heavy model can't freeze the UI.
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
        } catch {
            importErrorMessage = error.localizedDescription
            return
        }

        isImportingCar = true
        let slot = importSlot
        Task {
            do {
                let template = try await Entity(contentsOf: destination)
                switch slot {
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
            isImportingCar = false
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
