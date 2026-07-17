//
//  ModeSelectionView.swift
//  RaceKing
//

import SwiftUI

/// Chooses one game mode before AR tracking and course placement begin.
struct ModeSelectionView: View {
    var roomDriveAvailable: Bool
    var peerRaceAvailable = true
    var isPreparing = false
    var onSelect: (RaceGame.Mode) -> Void
    var onBack: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { proxy in
            let horizontalPadding: CGFloat = proxy.size.width < 430 ? 20 : 32
            let columnCount = dynamicTypeSize.isAccessibilitySize
                ? 1 : proxy.size.width >= 700 ? 4 : 2
            let columns = Array(
                repeating: GridItem(.flexible(), spacing: 12),
                count: columnCount
            )

            ZStack {
                ScrollView {
                    VStack(spacing: 18) {
                        HStack {
                            Button(action: onBack) {
                                Image("ToTitle")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: min(150, proxy.size.width * 0.45))
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                    .accessibilityHidden(true)
                            }
                            .buttonStyle(.plain)
                            .disabled(isPreparing)
                            .opacity(isPreparing ? 0.45 : 1)
                            .accessibilityLabel("タイトルに戻る")

                            Spacer()
                        }

                        VStack(spacing: 5) {
                            Text("遊ぶモードを選択")
                                .font(.largeTitle.weight(.black))
                                .fontDesign(.rounded)
                                .multilineTextAlignment(.center)
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
                                .accessibilityElement(children: .combine)
                            }
                        }

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(options) { option in
                                modeButton(option)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, max(16, proxy.safeAreaInsets.top))
                    .padding(.bottom, max(16, proxy.safeAreaInsets.bottom))
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
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
                detail: peerRaceAvailable
                    ? "同じWi-Fi・同じ場所にある2〜5台で対戦"
                    : "ネットワーク対戦にはARが必要です",
                imageName: "MenuNetworkRace",
                isEnabled: peerRaceAvailable,
                unavailableMessage: peerRaceAvailable
                    ? nil
                    : "ARモードが必要です\nアプリを再起動してください"
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
            VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 10 : 0) {
                ZStack {
                    Image(option.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .accessibilityHidden(true)

                    if let message = option.unavailableMessage,
                       !dynamicTypeSize.isAccessibilitySize {
                        Text(message)
                            .font(.caption.bold())
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                .black.opacity(0.78),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                    }
                }

                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 4) {
                        Text(option.title)
                            .font(.headline.weight(.black))
                        Text(option.detail)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(
                dynamicTypeSize.isAccessibilitySize
                    ? AnyShapeStyle(.black.opacity(0.5))
                    : AnyShapeStyle(.clear),
                in: RoundedRectangle(cornerRadius: 18)
            )
            .contentShape(Rectangle())
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
    var unavailableMessage: String? = nil
}

#Preview {
    ModeSelectionView(
        roomDriveAvailable: true,
        onSelect: { _ in },
        onBack: {}
    )
}
