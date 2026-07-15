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
                background

                VStack(spacing: 18) {
                    HStack {
                        Button(action: onBack) {
                            Label("タイトル", systemImage: "chevron.left")
                                .font(.callout.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparing)

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
        }
    }

    private var options: [ModeOption] {
        [
            ModeOption(
                id: "timeAttack",
                mode: .timeAttack,
                title: "タイムアタック",
                detail: "3周でベストラップに挑戦",
                systemImage: "stopwatch.fill",
                color: .orange
            ),
            ModeOption(
                id: "cpuRace",
                mode: .race,
                title: "CPU対戦",
                detail: "4台のライバルと5台で順位を競う",
                systemImage: "person.3.fill",
                color: .red
            ),
            ModeOption(
                id: "peerRace",
                mode: .peerRace,
                title: "ネットワーク対戦",
                detail: "同じWi-FiのiPhone 2台で対戦",
                systemImage: "wifi",
                color: .blue
            ),
            ModeOption(
                id: "roomDrive",
                mode: .roomDrive,
                title: "フリー走行",
                detail: roomDriveAvailable
                    ? "部屋をスキャンして自由に走る"
                    : "LiDAR対応端末とカメラ許可が必要です",
                systemImage: "viewfinder",
                color: .cyan,
                isEnabled: roomDriveAvailable
            ),
        ]
    }

    private func modeButton(_ option: ModeOption) -> some View {
        Button {
            onSelect(option.mode)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: option.systemImage)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(option.color.gradient, in: Circle())

                Text(option.title)
                    .font(.headline.weight(.black))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(option.detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Label(
                    option.isEnabled ? "このモードで遊ぶ" : "利用できません",
                    systemImage: option.isEnabled ? "play.fill" : "lock.fill"
                )
                    .font(.caption2.bold())
                    .foregroundStyle(option.isEnabled ? option.color : .white.opacity(0.5))
            }
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .padding(15)
            .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(option.color.opacity(option.isEnabled ? 0.55 : 0.18))
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .opacity(option.isEnabled ? 1 : 0.62)
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled || isPreparing)
        .accessibilityHint(option.detail)
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.025, blue: 0.06),
                    Color(red: 0.03, green: 0.12, blue: 0.22),
                    Color(red: 0.02, green: 0.02, blue: 0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(.blue.opacity(0.24))
                .frame(width: 380, height: 380)
                .blur(radius: 90)
                .offset(x: 150, y: -220)

            Circle()
                .fill(.red.opacity(0.16))
                .frame(width: 320, height: 320)
                .blur(radius: 90)
                .offset(x: -170, y: 270)
        }
        .ignoresSafeArea()
    }
}

private struct ModeOption: Identifiable {
    let id: String
    let mode: RaceGame.Mode
    let title: String
    let detail: String
    let systemImage: String
    let color: Color
    var isEnabled = true
}

#Preview {
    ModeSelectionView(
        roomDriveAvailable: true,
        onSelect: { _ in },
        onBack: {}
    )
}
