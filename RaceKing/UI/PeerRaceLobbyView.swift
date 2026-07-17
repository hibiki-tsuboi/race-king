//
//  PeerRaceLobbyView.swift
//  RaceKing
//

import SwiftUI

/// Nearby-room discovery, readiness, and host start controls.
struct PeerRaceLobbyView: View {
    @Bindable var multiplayer: PeerRaceSession
    var isLocalCourseReady: Bool
    var canResetCoursePlacement: Bool
    var onResetCoursePlacement: () -> Void = {}

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        lobbyContent
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 440 : 340)
        .foregroundStyle(.white)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .confirmationDialog(
            "接続を終了しますか？",
            isPresented: $showingDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("接続を終了", role: .destructive) {
                multiplayer.disconnect()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ルームから退出し、現在の準備状態を破棄します。")
        }
    }

    private var lobbyContent: some View {
        VStack(spacing: 10) {
            if let error = multiplayer.errorMessage {
                errorBanner(error)
            }

            switch multiplayer.state {
            case .idle:
                idleControls
            case .hosting:
                carSelectionControls(showsParticipants: true)
                sectionDivider
                waitingView(
                    "参加者を待っています…（\(multiplayer.participants.count)/\(PeerRaceSession.maximumPlayers)人）",
                    detail: "参加者を待ちながら、ホスト側でコースを配置できます"
                )
                if canResetHostCourse {
                    resetHostCourseButton
                }
            case .browsing:
                roomBrowser
                sectionDivider
                carSelectionControls(showsParticipants: false)
            case .connecting:
                waitingView(
                    "ホストに接続しています…",
                    detail: "コースは接続後にホストから受信します"
                )
            case .connected:
                carSelectionControls(showsParticipants: true)
                sectionDivider
                connectedControls
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
    }

    private var sectionDivider: some View {
        Divider()
            .overlay(.white.opacity(0.25))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption.bold())
                .multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            Button {
                multiplayer.clearError()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("通知を閉じる")
        }
        .padding(9)
        .background(.red.opacity(0.3), in: RoundedRectangle(cornerRadius: 9))
    }

    private func carSelectionControls(showsParticipants: Bool) -> some View {
        VStack(spacing: 7) {
            if showsParticipants {
                HStack {
                    Text("参加者 \(multiplayer.participants.count)/\(PeerRaceSession.maximumPlayers)")
                        .font(.caption.bold())
                    Spacer()
                    if multiplayer.role == .host {
                        Label("ホスト", systemImage: "crown.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.yellow)
                    } else {
                        Label("参加者", systemImage: "person.fill")
                            .font(.caption2.bold())
                            .foregroundStyle(.cyan)
                    }
                }

                VStack(spacing: 4) {
                    ForEach(multiplayer.participants) { participant in
                        participantRow(participant)
                    }
                }
            } else {
                Text("参加に使う車")
                    .font(.caption.bold())
            }

            carPicker

            if multiplayer.isSynchronizingCarModels {
                HStack(spacing: 7) {
                    ProgressView()
                        .tint(.white)
                    Text("カスタム車を参加者と共有しています…")
                        .font(.caption2.bold())
                }
                .foregroundStyle(.cyan)
            } else if let message = multiplayer.carModelErrorMessage {
                Text(message)
                    .font(.caption2.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            } else if multiplayer.localCarChoice == .imported,
                      multiplayer.state != .connected {
                Text("接続時にUSDZを参加者へ送信します")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
            } else if !multiplayer.localImportedCarAvailable {
                Text("歯車からUSDZを読み込むと「取込」を選べます")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
    }

    @ViewBuilder
    private var carPicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Picker("自分の車", selection: localCarChoice) {
                carPickerOptions
            }
            .pickerStyle(.menu)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Picker("自分の車", selection: localCarChoice) {
                carPickerOptions
            }
            .pickerStyle(.segmented)
        }
    }

    private var localCarChoice: Binding<RaceCarChoice> {
        Binding(
            get: { multiplayer.localCarChoice },
            set: { multiplayer.setLocalCarChoice($0) }
        )
    }

    private var carPickerOptions: some View {
        ForEach(multiplayer.availableLocalCarChoices) { choice in
            Text(choice.displayName)
                .tag(choice)
        }
    }

    private func participantRow(_ participant: PeerRaceParticipant) -> some View {
        ViewThatFits(in: .horizontal) {
            participantRegularRow(participant)
            participantCompactRow(participant)
        }
        .font(.caption.bold())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(participantAccessibilityLabel(participant))
    }

    private func participantRegularRow(_ participant: PeerRaceParticipant) -> some View {
        HStack(spacing: 6) {
            Text("#\(participant.slot + 1)")
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
            Image(systemName: "car.side.fill")
                .foregroundStyle(carColor(participant.carChoice))
            if participant.slot == 0,
               multiplayer.role == .host
                || participant.id != multiplayer.localPlayerID {
                Image(systemName: "crown.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
            }
            Text(participant.name)
                .lineLimit(1)
            if participant.id == multiplayer.localPlayerID {
                Text("自分")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.white.opacity(0.18), in: Capsule())
            }
            Spacer(minLength: 4)
            Text(participant.carChoice.displayName)
                .foregroundStyle(carColor(participant.carChoice))
            if multiplayer.state == .connected {
                Image(systemName: participant.isReady
                    ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(participant.isReady
                        ? .green : .white.opacity(0.55))
            }
        }
    }

    private func participantCompactRow(_ participant: PeerRaceParticipant) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("#\(participant.slot + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.65))
                Image(systemName: "car.side.fill")
                    .foregroundStyle(carColor(participant.carChoice))
                Text(participant.name)
                    .lineLimit(2)
                if participant.id == multiplayer.localPlayerID {
                    Text("自分")
                        .font(.caption2.bold())
                        .padding(.horizontal, 4)
                        .background(.white.opacity(0.18), in: Capsule())
                }
            }
            HStack(spacing: 6) {
                Text(participant.carChoice.displayName)
                    .foregroundStyle(carColor(participant.carChoice))
                if multiplayer.state == .connected {
                    Label(
                        participant.isReady ? "準備OK" : "準備中",
                        systemImage: participant.isReady
                            ? "checkmark.circle.fill" : "circle.dotted"
                    )
                    .foregroundStyle(participant.isReady
                        ? .green : .white.opacity(0.65))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func participantAccessibilityLabel(
        _ participant: PeerRaceParticipant
    ) -> String {
        var parts = [
            "\(participant.slot + 1)番、\(participant.name)",
            "車は\(participant.carChoice.displayName)",
        ]
        if participant.id == multiplayer.localPlayerID { parts.append("自分") }
        if multiplayer.state == .connected {
            parts.append(participant.isReady ? "準備OK" : "準備中")
        }
        return parts.joined(separator: "、")
    }

    private func carColor(_ choice: RaceCarChoice?) -> Color {
        switch choice {
        case .green: .green
        case .red: .red
        case .blue: .blue
        case .white: .white
        case .yellow: .yellow
        case .imported: .purple
        case nil: .white.opacity(0.65)
        }
    }

    private var idleControls: some View {
        VStack(spacing: 10) {
            Text("同じWi-Fi・同じ場所にある2〜5台のiPhoneで対戦します")
                .font(.caption.bold())
                .multilineTextAlignment(.center)

            Label("全員で同じ机や床を囲みます（AR必須）", systemImage: "arkit")
                .font(.caption2.bold())
                .foregroundStyle(.cyan)

            VStack(spacing: 8) {
                Button {
                    multiplayer.startHosting()
                } label: {
                    VStack(spacing: 2) {
                        Label("ルームを作る", systemImage: "plus.circle.fill")
                            .font(.headline.bold())
                        Text("ホストとしてこの端末でコースを決めます")
                            .font(.caption2.bold())
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    multiplayer.startBrowsing()
                } label: {
                    VStack(spacing: 2) {
                        Label("ルームに参加", systemImage: "wifi")
                            .font(.headline.bold())
                        Text("ホストが配置したコースを使用します")
                            .font(.caption2.bold())
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
    }

    private func waitingView(_ message: String, detail: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.callout.bold())
            Text(detail)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))
            Button("キャンセル", role: .cancel) {
                multiplayer.disconnect()
            }
            .buttonStyle(.bordered)
        }
    }

    private var roomBrowser: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .tint(.white)
                Text("近くのルーム")
                    .font(.callout.bold())
            }

            Text("コースはホストが用意します。この端末での配置は不要です")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.72))

            if multiplayer.rooms.isEmpty {
                Text("ルームが見つかるまでお待ちください")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                VStack(spacing: 6) {
                    ForEach(multiplayer.rooms) { room in
                        Button {
                            multiplayer.join(room)
                        } label: {
                            HStack {
                                Image(systemName: "iphone")
                                Text(room.name)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .font(.callout.bold())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                .blue.opacity(0.75),
                                in: RoundedRectangle(cornerRadius: 9)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button("キャンセル", role: .cancel) {
                multiplayer.disconnect()
            }
            .buttonStyle(.bordered)
        }
    }

    private var connectedControls: some View {
        VStack(spacing: 9) {
            Label(
                "\(multiplayer.participants.count)人で接続中",
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout.bold())
            .foregroundStyle(.green)

            if multiplayer.role == .host,
               multiplayer.participants.count < PeerRaceSession.maximumPlayers {
                Text("最大5人まで参加できます。新しい参加者が入るとコースを再共有します")
                    .font(.caption2.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.72))
            }

            courseSyncControls

            if multiplayer.isCourseSynchronized && multiplayer.carModelsSynchronized {
                Button {
                    multiplayer.setReady(!multiplayer.localReady)
                } label: {
                    Label(
                        multiplayer.localReady ? "準備OKを取り消す" : "準備OK",
                        systemImage: multiplayer.localReady
                            ? "xmark.circle" : "checkmark.circle"
                    )
                    .font(.headline.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(multiplayer.localReady ? .gray : .green)
                .disabled(!multiplayer.canSetReady || !isLocalCourseReady)
            }

            if multiplayer.role == .host && multiplayer.isCourseSynchronized {
                Button {
                    guard isLocalCourseReady else { return }
                    multiplayer.requestStartRace()
                } label: {
                    Text("レース開始")
                        .font(.headline.weight(.black))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!multiplayer.canStartRace || !isLocalCourseReady)

                if !multiplayer.allParticipantsReady {
                    Text("全員の準備OKを待っています")
                        .font(.caption.bold())
                        .foregroundStyle(.yellow)
                }
            } else if multiplayer.role == .guest && multiplayer.localReady {
                Text(
                    multiplayer.allParticipantsReady
                        ? "ホストのスタートを待っています"
                        : "ほかの参加者の準備OKを待っています"
                )
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
            }

            Button("接続を終了", role: .destructive) {
                showingDisconnectConfirmation = true
            }
            .font(.caption.bold())
        }
    }

    @ViewBuilder
    private var courseSyncControls: some View {
        switch multiplayer.courseSyncState {
        case .unavailable:
            EmptyView()
        case .hostPlacement:
            VStack(spacing: 6) {
                Text("ホストのコースが全端末共通になります")
                    .font(.caption.bold())
                Text("位置・向き・大きさを決めてから共有してください")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.75))
                Button {
                    multiplayer.requestCourseShare()
                } label: {
                    Label("このコースを共有", systemImage: "arkit")
                        .font(.callout.bold())
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .disabled(
                    !multiplayer.canRequestCourseShare || !isLocalCourseReady
                )
                if canResetHostCourse {
                    resetHostCourseButton
                }
                if !isLocalCourseReady {
                    Text("床かテーブルにコースを配置し、位置が確定するまでお待ちください")
                        .font(.caption2.bold())
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.yellow)
                }
            }
        case .waitingForHost:
            courseProgress(
                "ホストのコース共有を待っています",
                detail: "この端末でのコース配置は不要です"
            )
        case .preparingMap:
            courseProgress("AR空間を共有しています", detail: "そのままお待ちください")
        case .waitingForMap:
            courseProgress("コース情報を受信しています", detail: "そのままお待ちください")
        case .relocalizing:
            courseProgress(
                "コースの位置を合わせています",
                detail: "ホストと同じ机・床・周囲をゆっくり映してください"
            )
        case .waitingForGuest:
            if multiplayer.role == .host {
                courseProgress(
                    "参加者がコースを位置合わせ中です",
                    detail: "完了 \(multiplayer.courseSynchronizedGuestCount)/\(multiplayer.remoteParticipants.count)台"
                )
            } else {
                courseProgress(
                    "他の参加者の位置合わせを待っています",
                    detail: "全員が完了すると準備OKに進めます"
                )
            }
        case .synchronized:
            if isLocalCourseReady {
                Label("同じ実空間にコースを配置しました", systemImage: "arkit")
                    .font(.caption.bold())
                    .foregroundStyle(.cyan)
            } else {
                courseProgress(
                    "コース位置を確認しています",
                    detail: "同じ机や床と周囲をゆっくり映してください"
                )
            }
        case .failed(let message):
            VStack(spacing: 6) {
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
                if multiplayer.role == .host {
                    Button("コース共有を再試行") {
                        multiplayer.requestCourseShare()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cyan)
                    .disabled(
                        !multiplayer.canRequestCourseShare || !isLocalCourseReady
                    )
                    if canResetHostCourse {
                        resetHostCourseButton
                    }
                } else {
                    Text("ホスト側から再試行してください")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                }
            }
        }
    }

    private var canResetHostCourse: Bool {
        multiplayer.canEditHostCourse && canResetCoursePlacement
    }

    private var resetHostCourseButton: some View {
        Button(action: onResetCoursePlacement) {
            Label("コースを置き直す", systemImage: "viewfinder")
                .font(.caption.bold())
        }
        .buttonStyle(.bordered)
        .tint(.white)
    }

    private func courseProgress(_ title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 7) {
                ProgressView()
                    .tint(.white)
                Text(title)
                    .font(.caption.bold())
            }
            Text(detail)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
        }
    }

}
