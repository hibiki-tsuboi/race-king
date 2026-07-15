//
//  TitleView.swift
//  RaceKing
//

import SwiftUI

/// Branded entry screen shown before game-mode selection begins.
struct TitleView: View {
    var onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isStartHighlighted = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let buttonWidth = min(width - 56, 360)

            ZStack {
                Image("TitleBackground")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .ignoresSafeArea()
                    .accessibilityLabel("Anywhere GP。どこでも、そこがサーキット。")

                VStack(spacing: 0) {
                    Spacer()

                    Button(action: onStart) {
                        HStack(spacing: 12) {
                            Image(systemName: "play.fill")
                            Text("PRESS START")
                        }
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: buttonWidth)
                        .padding(.vertical, 17)
                        .background(
                            LinearGradient(
                                colors: [.red, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(.white.opacity(0.7), lineWidth: 2)
                        )
                        .shadow(color: .red.opacity(0.55), radius: 20, y: 8)
                        .scaleEffect(isStartHighlighted ? 1.025 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("遊ぶモードを選択")
                    .padding(.bottom, max(104, proxy.size.height * 0.16))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay(alignment: .bottom) {
                Text("VERSION \(appVersion)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.38))
                    .padding(.bottom, max(12, proxy.safeAreaInsets.bottom))
                    .accessibilityLabel("バージョン \(appVersion)")
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isStartHighlighted = true
            }
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

#Preview {
    TitleView(onStart: {})
}
