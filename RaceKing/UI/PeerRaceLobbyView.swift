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

    private func readinessLabel(_ title: String, ready: Bool) -> some View {
        Label(
            "\(title): \(ready ? "準備OK" : "準備中")",
            systemImage: ready ? "checkmark.circle.fill" : "circle.dotted"
        )
        .font(.caption.bold())
        .foregroundStyle(ready ? .green : .white.opacity(0.75))
    }
}
