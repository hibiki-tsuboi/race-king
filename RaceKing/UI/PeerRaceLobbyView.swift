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
            switch multiplayer.state {
            case .idle:
                idleControls
            case .hosting:
                waitingView("相手の参加を待っています…")
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

    private var idleControls: some View {
        VStack(spacing: 10) {
            Text("同じWi-Fiにつないだ2台のiPhoneで対戦します")
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
                "\(multiplayer.peerName ?? "対戦相手")と接続しました",
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout.bold())
            .foregroundStyle(.green)

            courseSyncControls

            HStack(spacing: 16) {
                readinessLabel("自分", ready: multiplayer.localReady)
                readinessLabel("相手", ready: multiplayer.remoteReady)
            }

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
            .disabled(!multiplayer.isCourseSynchronized)

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
            } else if multiplayer.localReady && multiplayer.remoteReady {
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
                Text("ホストのコースが2台共通になります")
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
            courseProgress(
                "相手がコースを位置合わせ中です",
                detail: "相手のiPhoneで同じ場所を映してください"
            )
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

    private func readinessLabel(_ title: String, ready: Bool) -> some View {
        Label(
            "\(title): \(ready ? "準備OK" : "準備中")",
            systemImage: ready ? "checkmark.circle.fill" : "circle.dotted"
        )
        .font(.caption.bold())
        .foregroundStyle(ready ? .green : .white.opacity(0.75))
    }
}
