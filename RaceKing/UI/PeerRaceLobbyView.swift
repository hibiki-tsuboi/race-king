//
//  PeerRaceLobbyView.swift
//  RaceKing
//

import SwiftUI

/// Nearby-room discovery, readiness, and host start controls.
struct PeerRaceLobbyView: View {
    @Bindable var multiplayer: PeerRaceSession

    var body: some View {
        VStack(spacing: 10) {
            carSelectionControls

            Divider()
                .overlay(.white.opacity(0.25))

            switch multiplayer.state {
            case .idle:
                idleControls
            case .hosting:
                waitingView("参加者を待っています…（1/5人）")
            case .browsing:
                roomBrowser
            case .connecting:
                waitingView("対戦相手に接続しています…")
            case .connected:
                connectedControls
            }
        }
        .frame(maxWidth: 340)
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private var carSelectionControls: some View {
        VStack(spacing: 7) {
            HStack {
                Text("参加者 \(multiplayer.participants.count)/\(PeerRaceSession.maximumPlayers)")
                    .font(.caption.bold())
                Spacer()
                if multiplayer.role == .host {
                    Label("ホスト", systemImage: "crown.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                }
            }

            VStack(spacing: 4) {
                ForEach(multiplayer.participants) { participant in
                    participantRow(participant)
                }
            }

            Picker(
                "自分の車",
                selection: Binding(
                    get: { multiplayer.localCarChoice },
                    set: { multiplayer.setLocalCarChoice($0) }
                )
            ) {
                ForEach(multiplayer.availableLocalCarChoices) { choice in
                    Text(choice.displayName)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .tag(choice)
                }
            }
            .pickerStyle(.segmented)

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

    private func participantRow(_ participant: PeerRaceParticipant) -> some View {
        HStack(spacing: 6) {
            Text("#\(participant.slot + 1)")
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.65))
            Image(systemName: "car.side.fill")
                .foregroundStyle(carColor(participant.carChoice))
            if participant.slot == 0 {
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
        .font(.caption.bold())
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
            Text("同じWi-Fiにつないだ2〜5台のiPhoneで対戦します")
                .font(.caption.bold())
                .multilineTextAlignment(.center)

            if let error = multiplayer.errorMessage {
                Text(error)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button {
                    multiplayer.startHosting()
                } label: {
                    Label("ルームを作る", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    multiplayer.startBrowsing()
                } label: {
                    Label("参加する", systemImage: "wifi")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
    }

    private func waitingView(_ message: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(message)
                .font(.callout.bold())
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

            if multiplayer.rooms.isEmpty {
                Text("ルームが見つかるまでお待ちください")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                ScrollView {
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
                                .background(.blue.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 120)
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
                Text("このまま最大5人まで参加できます")
                    .font(.caption2.bold())
                    .foregroundStyle(.white.opacity(0.72))
            }

            courseSyncControls

            Button {
                multiplayer.setReady(!multiplayer.localReady)
            } label: {
                Label(
                    multiplayer.localReady ? "準備OKを取り消す" : "準備OK",
                    systemImage: multiplayer.localReady ? "xmark.circle" : "checkmark.circle"
                )
                .font(.headline.bold())
            }
            .buttonStyle(.borderedProminent)
            .tint(multiplayer.localReady ? .gray : .green)
            .disabled(!multiplayer.canSetReady)

            if multiplayer.role == .host {
                Button {
                    multiplayer.requestStartRace()
                } label: {
                    Text("レース開始")
                        .font(.headline.weight(.black))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!multiplayer.canStartRace)
            } else if multiplayer.localReady && multiplayer.allParticipantsReady {
                Text("ホストのスタートを待っています")
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
            }

            Button("接続を終了", role: .destructive) {
                multiplayer.disconnect()
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
                .disabled(!multiplayer.canRequestCourseShare)
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
            Label("同じ実空間にコースを配置しました", systemImage: "arkit")
                .font(.caption.bold())
                .foregroundStyle(.cyan)
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
                    .disabled(!multiplayer.canRequestCourseShare)
                } else {
                    Text("ホスト側から再試行してください")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                }
            }
        }
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
