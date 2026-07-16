//
//  ModeSelectionView.swift
//  RaceKing
//

import SwiftUI

/// Chooses one game mode before AR tracking and course placement begin.
struct ModeSelectionView: View {
    var roomDriveAvailable: Bool
    var isPreparing = false
    var onSelect: (RaceGame.Mode) -> Void
    var onBack: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = proxy.size.width < 430 ? 20 : 32
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: proxy.size.width >= 700 ? 4 : 2
            )

            ZStack {
                VStack(spacing: 18) {
                    HStack {
                        Button(action: onBack) {
                            Image("ToTitle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 150)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparing)
                        .opacity(isPreparing ? 0.45 : 1)
                        .accessibilityLabel("タイトルに戻る")

                        Spacer()

                        Text("ANYWHERE GP")
                            .font(.caption.weight(.black))
                            .tracking(2)
                            .foregroundStyle(.white.opacity(0.65))
                    }

                    VStack(spacing: 5) {
                        Text("遊ぶモードを選択")
                            .font(.system(size: 30, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                        Text("モードを決めてからコースの準備を始めます")
                            .font(.callout.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.7))

                        if isPreparing {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .tint(.white)
                                Text("カメラを終了しています…")
                                    .font(.caption.bold())
                            }
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.top, 5)
                        }
                    }

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(options) { option in
                                modeButton(option)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.hidden)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, max(16, proxy.safeAreaInsets.top))
                .padding(.bottom, max(16, proxy.safeAreaInsets.bottom))
            }
            .background { background }
        }
    }

    private var options: [ModeOption] {
        [
            ModeOption(
                id: "timeAttack",
                mode: .timeAttack,
                title: "タイムアタック",
                detail: "ベストラップに挑戦",
                imageName: "MenuTimeAttack"
            ),
            ModeOption(
                id: "cpuRace",
                mode: .race,
                title: "CPU対戦",
                detail: "ライバルたちと順位を競う",
                imageName: "MenuCPURace"
            ),
            ModeOption(
                id: "peerRace",
                mode: .peerRace,
                title: "ネットワーク対戦",
                detail: "同じWi-FiにつないだiPhone同士で対戦",
                imageName: "MenuNetworkRace"
            ),
            ModeOption(
                id: "roomDrive",
                mode: .roomDrive,
                title: "フリー走行",
                detail: roomDriveAvailable
                    ? "部屋をスキャンして自由に走る"
                    : "LiDAR対応端末とカメラ許可が必要です",
                imageName: roomDriveAvailable
                    ? "MenuFreeDrive"
                    : "MenuFreeDriveUnavailable",
                isEnabled: roomDriveAvailable
            ),
        ]
    }

    private func modeButton(_ option: ModeOption) -> some View {
        Button {
            onSelect(option.mode)
        } label: {
            Image(option.imageName)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled || isPreparing)
        .accessibilityLabel(option.title)
        .accessibilityValue(
            isPreparing
                ? "準備中"
                : option.isEnabled ? "利用可能" : "利用できません"
        )
        .accessibilityHint(option.detail)
    }

    private var background: some View {
        Image("MenuBackground")
            .resizable()
            .scaledToFill()
            .overlay(.black.opacity(0.18))
            .accessibilityHidden(true)
            .ignoresSafeArea()
    }
}

private struct ModeOption: Identifiable {
    let id: String
    let mode: RaceGame.Mode
    let title: String
    let detail: String
    let imageName: String
    var isEnabled = true
}

#Preview {
    ModeSelectionView(
        roomDriveAvailable: true,
        onSelect: { _ in },
        onBack: {}
    )
}
