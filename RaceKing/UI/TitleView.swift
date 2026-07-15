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
            let buttonWidth = min(width - 24, 410)

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
                        Image("PressStart")
                            .resizable()
                            .scaledToFill()
                            .frame(width: buttonWidth, height: buttonWidth * 0.26)
                            .clipped()
                            .scaleEffect(isStartHighlighted ? 1.025 : 1)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
                    .accessibilityLabel("遊ぶモードを選択")
                    .padding(.bottom, max(72, proxy.size.height * 0.12))
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
