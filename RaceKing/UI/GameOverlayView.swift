//
//  GameOverlayView.swift
//  RaceKing
//

import SwiftUI
import RealityKit
import UniformTypeIdentifiers

/// HUD, touch controls, race setup, and results layered over the AR view.
struct GameOverlayView: View {
    private enum ExitDestination {
        case modeSelection
        case title
    }

    @Bindable var game: RaceGame
    @Bindable var multiplayer: PeerRaceSession
    var canScanRoom = false
    var roomScanUnavailableMessage: String? = nil
    var onScanRoom: () -> Void = {}
    var onResetCoursePlacement: () -> Void = {}
    var onPlaceAtCenter: (() -> Void)? = nil
    var onRotateCourseLeft: (() -> Void)? = nil
    var onRotateCourseRight: (() -> Void)? = nil
    var onScaleCourseDown: (() -> Void)? = nil
    var onScaleCourseUp: (() -> Void)? = nil
    var onChooseMode: () -> Void = {}
    var onReturnToTitle: () -> Void = {}
    @State private var pendingExitDestination: ExitDestination?
    @State private var showingRaceResetConfirmation = false
    @State private var showingCourseResetConfirmation = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            VStack {
                HUDView(
                    game: game,
                    onReset: requestRaceReset,
                    onChooseMode: { requestExit(to: .modeSelection) },
                    onReturnToTitle: { requestExit(to: .title) },
                    onSettingsPresentationChanged: handleSettingsPresentation,
                    onImportedCarChanged: multiplayer.refreshLocalImportedCar,
                    peerParticipants: multiplayer.remoteParticipants,
                    showsRaceMetrics: game.phase != .ready && !isPeerLobby,
                    canResetRace: canResetRace
                )
                Spacer()
                if !isPeerLobby {
                    ControlsView(game: game)
                }
            }
            .padding()

            centerMessage
        }
        .confirmationDialog(
            exitDialogTitle,
            isPresented: Binding(
                get: { pendingExitDestination != nil },
                set: { if !$0 { pendingExitDestination = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(exitConfirmationTitle, role: .destructive) {
                guard let destination = pendingExitDestination else { return }
                pendingExitDestination = nil
                game.resumeSoloRace(for: .confirmation)
                performExit(to: destination)
            }
            Button("キャンセル", role: .cancel) {
                pendingExitDestination = nil
                game.resumeSoloRace(for: .confirmation)
            }
        } message: {
            Text(exitDialogMessage)
        }
        .confirmationDialog(
            raceResetDialogTitle,
            isPresented: $showingRaceResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("リセット", role: .destructive) {
                game.resumeSoloRace(for: .confirmation)
                resetRace()
            }
            Button("キャンセル", role: .cancel) {
                game.resumeSoloRace(for: .confirmation)
            }
        } message: {
            Text(raceResetDialogMessage)
        }
        .confirmationDialog(
            "コースを置き直しますか？",
            isPresented: $showingCourseResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("置き直す", role: .destructive, action: onResetCoursePlacement)
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("現在のコース位置・向き・大きさは破棄されます。")
        }
        .onChange(of: pendingExitDestination) {
            if pendingExitDestination == nil {
                game.resumeSoloRace(for: .confirmation)
            }
        }
        .onChange(of: showingRaceResetConfirmation) {
            if !showingRaceResetConfirmation {
                game.resumeSoloRace(for: .confirmation)
            }
        }
        .onDisappear {
            game.resumeSoloRace(for: .confirmation)
            game.resumeSoloRace(for: .settings)
            game.steeringInput = 0
            game.throttleInput = false
            game.brakeInput = false
        }
    }

    @ViewBuilder
    private var centerMessage: some View {
        switch game.phase {
        case .ready:
            if game.mode != .roomDrive,
               game.mode != .peerRace,
               !game.isCourseAnchored {
                // AR is still scanning: no horizontal course surface yet.
                ViewThatFits(in: .vertical) {
                    placementSearchPanel
                    ScrollView {
                        placementSearchPanel
                            .padding(.vertical, 140)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
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
            ViewThatFits(in: .vertical) {
                finishedPanel
                ScrollView {
                    finishedPanel
                        .padding(.vertical, 120)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var finishedPanel: some View {
        VStack(spacing: 12) {
            Text("🏁 FINISH!")
                .font(.largeTitle.weight(.black))
                .fontDesign(.rounded)
                .foregroundStyle(.white)
            finishedDetails
            if game.mode == .peerRace && !multiplayer.raceComplete {
                Text("ほかの参加者のゴールを待っています…")
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
            }
            if game.mode == .peerRace && multiplayer.role == .host {
                Button(action: requestRaceReset) {
                    Text("全員のレースをリセット")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(.red.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if game.mode != .peerRace {
                Button(action: resetRace) {
                    Text("もう一度")
                        .font(.headline.weight(.black))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 10)
                        .background(.red.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if multiplayer.raceComplete {
                Text("ホストが次のレースを準備するのを待っています")
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.yellow)
            }
        }
        .padding(28)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 22))
        .padding(.horizontal, 12)
    }

    private var placementSearchPanel: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(placementSearchMessage)
                .font(.callout.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            if let onPlaceAtCenter, !game.isCoursePlaced {
                Button(action: onPlaceAtCenter) {
                    Label("画面中央にコースを置く", systemImage: "scope")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
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
            Button(action: onChooseMode) {
                Label("モード選択に戻る", systemImage: "chevron.left")
                    .font(.callout.bold())
            }
            .buttonStyle(.bordered)
            .tint(.white)
            if game.isCoursePlaced
                && game.mode.reusesLocalCoursePlacement
                && !game.virtualModeActive {
                Button(action: requestCourseReset) {
                    Label(
                        "コース配置をやり直す",
                        systemImage: "arrow.counterclockwise"
                    )
                    .font(.callout.bold())
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(22)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
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
                    .font(
                        dynamicTypeSize.isAccessibilitySize
                            ? .title.weight(.black)
                            : .system(size: 44, weight: .black, design: .rounded)
                    )
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
                    .font(
                        dynamicTypeSize.isAccessibilitySize
                            ? .largeTitle.weight(.black)
                            : .system(size: 84, weight: .black, design: .rounded)
                    )
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
        ViewThatFits(in: .vertical) {
            readyMenuContent
                .frame(maxWidth: .infinity)
                .padding(.top, readyMenuTopPadding)
                .padding(.horizontal, 12)
                .padding(.bottom, 130)

            ScrollView {
                readyMenuContent
                    .frame(maxWidth: .infinity)
                    .padding(.top, readyMenuTopPadding)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 130)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyMenuContent: some View {
        VStack(spacing: 14) {
            Label(selectedModeTitle, systemImage: selectedModeSystemImage)
                .font(.callout.weight(.black))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.black.opacity(0.45), in: Capsule())

            #if !targetEnvironment(simulator)
            Text(placementInstruction)
                .font(.callout.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityActions {
                    if canAdjustCoursePlacement {
                        if let onPlaceAtCenter {
                            Button("画面中央へ移動", action: onPlaceAtCenter)
                        }
                        if let onRotateCourseLeft {
                            Button("左に15度回転", action: onRotateCourseLeft)
                        }
                        if let onRotateCourseRight {
                            Button("右に15度回転", action: onRotateCourseRight)
                        }
                        if let onScaleCourseDown {
                            Button("小さくする", action: onScaleCourseDown)
                        }
                        if let onScaleCourseUp {
                            Button("大きくする", action: onScaleCourseUp)
                        }
                    }
                }
            #endif

            if game.mode == .peerRace {
                PeerRaceLobbyView(
                    multiplayer: multiplayer,
                    isLocalCourseReady: game.canStart,
                    canResetCoursePlacement: canResetPeerCoursePlacement,
                    onResetCoursePlacement: requestCourseReset
                )
            } else if game.mode == .roomDrive {
                roomDriveSetup
            }

            if game.mode != .roomDrive,
               !game.isCoursePlaced,
               game.mode != .peerRace || multiplayer.canEditHostCourse,
               let onPlaceAtCenter {
                Button(action: onPlaceAtCenter) {
                    Label("画面中央にコースを置く", systemImage: "scope")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
            }

            if game.mode != .peerRace && game.canStart {
                Button {
                    game.startRace()
                } label: {
                    Text(game.mode == .roomDrive ? "フリー走行" : "START")
                        .font(
                            dynamicTypeSize.isAccessibilitySize
                                ? .title.weight(.black)
                                : .system(size: 30, weight: .black, design: .rounded)
                        )
                        .foregroundStyle(.white)
                        .padding(.horizontal, 44)
                        .padding(.vertical, 14)
                        .background(.red.gradient, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            if (game.mode.reusesLocalCoursePlacement
                || game.mode == .peerRace && multiplayer.canEditHostCourse),
               game.canStart,
               !game.virtualModeActive {
                Button(action: requestCourseReset) {
                    Label(
                        "コースを置き直す",
                        systemImage: "viewfinder"
                    )
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .font(.caption.bold())
            }
        }
    }

    private var readyMenuTopPadding: CGFloat {
        if dynamicTypeSize.isAccessibilitySize {
            return game.mode == .peerRace ? 100 : 110
        }
        return game.mode == .peerRace ? 72 : 90
    }

    private var canAdjustCoursePlacement: Bool {
        game.phase == .ready
            && game.mode != .roomDrive
            && game.isCoursePlaced
            && !game.virtualModeActive
            && (game.mode != .peerRace || multiplayer.canEditHostCourse)
    }

    private var selectedModeTitle: String {
        switch game.mode {
        case .timeAttack: "タイムアタック"
        case .race: "CPU対戦"
        case .peerRace: "ネットワーク対戦"
        case .roomDrive: "フリー走行"
        }
    }

    private var selectedModeSystemImage: String {
        switch game.mode {
        case .timeAttack: "stopwatch.fill"
        case .race: "person.3.fill"
        case .peerRace: "wifi"
        case .roomDrive: "viewfinder"
        }
    }

    private var placementSearchMessage: String {
        game.isCoursePlaced
            ? "コース位置を復元しています…\n同じ床やテーブルをゆっくり映してください"
            : "床やテーブルを映して\nコースを置きたい場所をタップしてください"
    }

    private var placementInstruction: String {
        if game.mode == .roomDrive {
            return game.hasScannedRoom
                ? "床に向けてタップでスタート位置を決定"
                : "まず部屋をスキャンしてください"
        }
        if game.mode == .peerRace {
            return peerPlacementInstruction
        }
        if !game.isCoursePlaced {
            return "床やテーブルをタップしてコースを配置"
        }
        return "床やテーブルをタップしてコース移動\nドラッグで移動・二本指でサイズ／向き調整"
    }

    private func resetRace() {
        if game.mode == .peerRace, multiplayer.state == .connected {
            guard multiplayer.role == .host else { return }
            multiplayer.requestResetRace()
        } else {
            game.reset()
        }
    }

    private func requestRaceReset() {
        _ = game.suspendSoloRace(for: .confirmation)
        showingRaceResetConfirmation = true
    }

    private func requestCourseReset() {
        showingCourseResetConfirmation = true
    }

    private func handleSettingsPresentation(_ isPresented: Bool) {
        if isPresented {
            _ = game.suspendSoloRace(for: .settings)
        } else {
            game.resumeSoloRace(for: .settings)
        }
    }

    private var isPeerLobby: Bool {
        game.mode == .peerRace && game.phase == .ready
    }

    private var canResetPeerCoursePlacement: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        game.isCoursePlaced && !game.virtualModeActive
        #endif
    }

    private var canResetRace: Bool {
        game.mode != .peerRace || multiplayer.role == .host
    }

    private var peerPlacementInstruction: String {
        switch multiplayer.role {
        case nil:
            return "まずルームを作るか参加してください"
        case .host:
            switch multiplayer.courseSyncState {
            case .hostPlacement, .failed(_):
                if !game.isCoursePlaced {
                    return "床やテーブルをタップしてコースを配置"
                }
                if !game.isCourseAnchored {
                    return "コース位置を確認しています…"
                }
                return "ドラッグで移動・二本指でサイズ／向き調整"
            case .preparingMap:
                return "AR空間を共有しています…"
            case .waitingForGuest:
                return "参加者の位置合わせを待っています"
            case .synchronized:
                return game.isCourseAnchored
                    ? "コース同期完了。全員で準備OKにしてください"
                    : "コース位置を復元しています。同じ机や床を映してください"
            default:
                return "ホストのコースを準備しています"
            }
        case .guest:
            switch multiplayer.state {
            case .browsing:
                return "参加するルームを選んでください。コース配置は不要です"
            case .connecting:
                return "ホストに接続しています。コース配置は不要です"
            case .idle:
                return "ルームに参加するとホストのコースを受信します"
            case .hosting:
                return "コース配置はホストが行います"
            case .connected:
                switch multiplayer.courseSyncState {
                case .waitingForHost:
                    return "ホストがコースを準備しています。配置操作は不要です"
                case .waitingForMap:
                    return "ホストのコース情報を受信しています…"
                case .relocalizing:
                    return "ホストと同じ机・床・周囲をゆっくり映してください"
                case .waitingForGuest:
                    return "位置合わせが完了しました。ほかの参加者を待っています"
                case .synchronized:
                    return game.isCourseAnchored
                        ? "コース同期完了。準備OKにしてください"
                        : "コース位置を復元しています。同じ机や床を映してください"
                case .failed(_):
                    return "ホストがコースを再共有するまでお待ちください"
                default:
                    return "ホストのコースを準備しています"
                }
            }
        }
    }

    private func requestExit(to destination: ExitDestination) {
        let raceInProgress = game.phase == .countdown || game.phase == .racing
        let peerSessionActive = game.mode == .peerRace && multiplayer.state != .idle
        let roomScanWouldBeLost = game.mode == .roomDrive && game.hasScannedRoom
        guard raceInProgress || peerSessionActive || roomScanWouldBeLost else {
            performExit(to: destination)
            return
        }
        _ = game.suspendSoloRace(for: .confirmation)
        pendingExitDestination = destination
    }

    private func performExit(to destination: ExitDestination) {
        switch destination {
        case .modeSelection:
            onChooseMode()
        case .title:
            onReturnToTitle()
        }
    }

    private var exitConfirmationTitle: String {
        switch pendingExitDestination {
        case .modeSelection:
            "モード選択に戻る"
        case .title:
            "タイトルに戻る"
        case nil:
            "終了する"
        }
    }

    private var exitDialogTitle: String {
        if game.phase == .countdown || game.phase == .racing {
            return "レースを終了しますか？"
        }
        if game.mode == .peerRace && multiplayer.state != .idle {
            return "ネットワーク対戦から退出しますか？"
        }
        return "フリー走行の準備を終了しますか？"
    }

    private var exitDialogMessage: String {
        if game.phase == .countdown || game.phase == .racing {
            return game.mode == .peerRace
                ? "対戦から退出し、現在のレースを終了します。"
                : "進行中のレースはリセットされます。"
        }
        if game.mode == .peerRace && multiplayer.state != .idle {
            return "ルームとの接続と現在の準備状態を破棄します。"
        }
        return "スキャンした部屋とスタート位置を破棄します。"
    }

    private var raceResetDialogTitle: String {
        game.mode == .peerRace
            ? "全員のレースをリセットしますか？"
            : "レースをリセットしますか？"
    }

    private var raceResetDialogMessage: String {
        game.mode == .peerRace
            ? "全参加者のレース進行が最初からになります。"
            : "現在の周回とタイムを破棄してスタート前に戻ります。"
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
                    if let onPlaceAtCenter {
                        Button(action: onPlaceAtCenter) {
                            Label("画面中央をスタート位置にする", systemImage: "scope")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                    }
                }

                Divider()
                    .overlay(.white.opacity(0.25))

                Toggle(isOn: $game.roomModelVisible) {
                    Label("スキャンモデルを表示", systemImage: "cube.transparent")
                }
                .tint(.cyan)

                if game.roomModelVisible {
                    ViewThatFits(in: .horizontal) {
                        roomOpacityControls
                        VStack(alignment: .leading, spacing: 4) {
                            Text("表示濃度 \(Int(game.roomModelOpacity * 100))%")
                                .monospacedDigit()
                            Slider(
                                value: $game.roomModelOpacity,
                                in: RaceGame.minimumRoomModelOpacity...RaceGame.maximumRoomModelOpacity
                            )
                            .tint(.cyan)
                        }
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
        } else if let roomScanUnavailableMessage {
            Text(roomScanUnavailableMessage)
                .font(.callout.bold())
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("部屋のスキャンを準備しています…")
                    .font(.callout.bold())
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        }
    }

    private var roomOpacityControls: some View {
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

/// Lap counter, timers, race position, and settings along the top edge.
struct HUDView: View {
    /// Which car the next file import applies to.
    private enum CarImportSlot {
        case player
        case ai(Int)
    }

    @Bindable var game: RaceGame
    var onReset: () -> Void = {}
    var onChooseMode: () -> Void = {}
    var onReturnToTitle: () -> Void = {}
    var onSettingsPresentationChanged: (Bool) -> Void = { _ in }
    var onImportedCarChanged: () -> Void = {}
    var peerParticipants: [PeerRaceParticipant] = []
    var showsRaceMetrics = true
    var canResetRace = true
    @State private var showingCarImporter = false
    @State private var importSlot: CarImportSlot = .player
    @State private var importErrorMessage: String?
    @State private var isImportingCar = false
    @State private var showingSettings = false
    @State private var showingRevertConfirmation = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        hudContent
            .popover(isPresented: $showingSettings) {
                settingsView
                    .presentationCompactAdaptation(.sheet)
            }
            .onChange(of: showingSettings) {
                onSettingsPresentationChanged(showingSettings)
            }
            .onDisappear {
                if showingSettings { onSettingsPresentationChanged(false) }
            }
    }

    @ViewBuilder
    private var hudContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            accessibilityHUDContent
        } else {
            regularHUDContent
        }
    }

    private var regularHUDContent: some View {
        HStack(alignment: .top) {
            if showsRaceMetrics {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lapLabel)
                        .font(.headline.weight(.black))
                    Text(lapTimeString(game.currentLapTime))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    if game.mode == .peerRace {
                        ForEach(peerParticipants) { participant in
                            let peerLap = min(
                                game.peerLapCount(for: participant.id) + 1,
                                RaceGame.raceLapTotal
                            )
                            Text(
                                "#\(participant.slot + 1) \(participant.name)  LAP \(peerLap)/\(RaceGame.raceLapTotal)"
                            )
                            .lineLimit(1)
                            .font(.caption2.bold())
                            .foregroundStyle(.cyan)
                        }
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
            }

            Spacer()

            if (game.mode == .race || game.mode == .peerRace)
                && game.phase == .racing {
                Text("\(game.playerPosition)位")
                    .font(.system(size: 36, weight: .black, design: .rounded))
                Spacer()
            }

            VStack(alignment: .trailing, spacing: 8) {
                hudActionButtons
                if showsRaceMetrics {
                    Text("\(game.displaySpeed) km/h")
                        .font(.title3.weight(.heavy))
                        .monospacedDigit()
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private var accessibilityHUDContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if (game.mode == .race || game.mode == .peerRace),
                   game.phase == .racing {
                    Text("\(game.playerPosition)位")
                        .font(.title.weight(.black))
                }
                Spacer(minLength: 4)
                hudActionButtons
            }

            if showsRaceMetrics {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(lapLabel)
                            .font(.headline.weight(.black))
                        Text(lapTimeString(game.currentLapTime))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        Text("\(game.displaySpeed) km/h")
                            .font(.headline.weight(.heavy))
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(lapLabel)
                            .font(.headline.weight(.black))
                        Text(lapTimeString(game.currentLapTime))
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        Text("\(game.displaySpeed) km/h")
                            .font(.headline.weight(.heavy))
                            .monospacedDigit()
                    }
                }

                if game.mode == .peerRace {
                    ForEach(peerParticipants) { participant in
                        let peerLap = min(
                            game.peerLapCount(for: participant.id) + 1,
                            RaceGame.raceLapTotal
                        )
                        Text(
                            "#\(participant.slot + 1) \(participant.name)  LAP \(peerLap)/\(RaceGame.raceLapTotal)"
                        )
                        .font(.caption.bold())
                        .foregroundStyle(.cyan)
                    }
                } else if game.mode == .timeAttack {
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
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private var hudActionButtons: some View {
        HStack(spacing: 8) {
            Menu {
                Button(action: onChooseMode) {
                    Label("モード選択に戻る", systemImage: "square.grid.2x2")
                }
                Button(action: onReturnToTitle) {
                    Label("タイトルに戻る", systemImage: "house.fill")
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.backward.fill")
                    .font(.title3.bold())
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("戻る")

            if game.phase != .ready && canResetRace {
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.title3.bold())
                        .padding(10)
                        .background(.black.opacity(0.45), in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("レースをリセット")
            }

            Button {
                showingSettings = true
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
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isImportingCar)
            .accessibilityLabel(isImportingCar ? "車モデルを読み込み中" : "設定")
        }
    }

    private var settingsView: some View {
        NavigationStack {
            List {
                Section("操作") {
                    Toggle("傾きで操作", isOn: $game.tiltSteeringEnabled)
                    Toggle("ゴースト表示", isOn: $game.ghostEnabled)
                }

                Section("車モデル") {
                    Button {
                        importSlot = .player
                        showingCarImporter = true
                    } label: {
                        Label("自分の車を読み込む…", systemImage: "square.and.arrow.down")
                    }

                    ForEach(EntityFactory.aiCarTemplates.indices, id: \.self) { index in
                        Button {
                            importSlot = .ai(index)
                            showingCarImporter = true
                        } label: {
                            Label(
                                "AI \(index + 1) の車を読み込む…",
                                systemImage: "square.and.arrow.down.on.square"
                            )
                        }
                    }

                    if hasAnyCustomCar {
                        Button {
                            EntityFactory.customCarFlipped.toggle()
                            reapplyCustomCars()
                        } label: {
                            Label("車の前後を反転", systemImage: "arrow.left.arrow.right")
                        }

                        Button(role: .destructive) {
                            showingRevertConfirmation = true
                        } label: {
                            Label("すべて標準の車に戻す", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                .disabled(isImportingCar)

                Section {
                    Text(appVersionText)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { showingSettings = false }
                        .disabled(isImportingCar)
                }
            }
        }
        .frame(idealWidth: 420, idealHeight: 580)
        .interactiveDismissDisabled(isImportingCar)
        .fileImporter(
            isPresented: $showingCarImporter,
            allowedContentTypes: [.usdz]
        ) { result in
            switch result {
            case .success(let url):
                importCarModel(from: url)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "すべて標準の車に戻しますか？",
            isPresented: $showingRevertConfirmation,
            titleVisibility: .visible
        ) {
            Button("標準の車に戻す", role: .destructive) {
                revertCarModels()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("読み込んだプレイヤー車とAI車のモデルを削除します。")
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
        EntityFactory.hasImportedPlayerCar
            || EntityFactory.aiCarTemplates.indices.contains { index in
                FileManager.default.fileExists(
                    atPath: EntityFactory.importedAICarURL(index: index).path
                )
            }
    }

    /// Validates the picked USDZ in a staging file, then atomically commits
    /// it only after RealityKit has successfully loaded the model.
    private func importCarModel(from url: URL) {
        guard !isImportingCar else { return }
        isImportingCar = true

        let destination: URL
        switch importSlot {
        case .player: destination = EntityFactory.importedCarURL
        case .ai(let index): destination = EntityFactory.importedAICarURL(index: index)
        }

        let slot = importSlot
        let directory = destination.deletingLastPathComponent()
        let stagingURL = EntityFactory.stagingURL(for: destination)

        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
                try? FileManager.default.removeItem(at: stagingURL)
                isImportingCar = false
            }

            do {
                try await Task.detached(priority: .userInitiated) {
                    let fileManager = FileManager.default
                    try EntityFactory.validateImportedCar(at: url)
                    try fileManager.createDirectory(
                        at: directory,
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: url, to: stagingURL)
                    try EntityFactory.validateImportedCar(at: stagingURL)
                }.value
                guard !Task.isCancelled else { return }
                let template = try await Entity(contentsOf: stagingURL)
                guard !Task.isCancelled else { return }
                try EntityFactory.commitImportedCar(
                    from: stagingURL,
                    to: destination
                )

                switch slot {
                case .player:
                    EntityFactory.customCarFlipped = false
                    EntityFactory.customCarTemplate = template
                    game.setCustomCarModel(template)
                    onImportedCarChanged()
                case .ai(let index):
                    EntityFactory.aiCarTemplates[index] = template
                    game.setAICarModel(template, at: index)
                }
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    /// Re-populates every custom car, e.g. after toggling the flip setting.
    private func reapplyCustomCars() {
        game.setCustomCarModel(EntityFactory.customCarTemplate)
        onImportedCarChanged()
        for (index, template) in EntityFactory.aiCarTemplates.enumerated() where template != nil {
            game.setAICarModel(template, at: index)
        }
    }

    /// Deletes imported files and restores the bundled default cars.
    private func revertCarModels() {
        try? FileManager.default.removeItem(at: EntityFactory.importedCarURL)
        EntityFactory.customCarFlipped = false
        let bundled = try? Entity.load(named: "PlayerCar")
        EntityFactory.customCarTemplate = bundled
        game.setCustomCarModel(bundled)
        onImportedCarChanged()
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
