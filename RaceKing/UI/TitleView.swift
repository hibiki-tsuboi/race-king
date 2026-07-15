//
//  TitleView.swift
//  RaceKing
//

import SwiftUI

/// Branded entry screen shown before AR and course placement begin.
struct TitleView: View {
    var onStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isStartHighlighted = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let logoWidth = min(width - 48, 390)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.02, green: 0.03, blue: 0.06),
                        Color(red: 0.02, green: 0.10, blue: 0.19),
                        Color(red: 0.01, green: 0.02, blue: 0.04),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Circle()
                    .fill(Color.blue.opacity(0.3))
                    .frame(width: width * 1.15, height: width * 1.15)
                    .blur(radius: 70)
                    .offset(y: proxy.size.height * 0.16)
                    .ignoresSafeArea()

                racingBackdrop
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: max(36, proxy.size.height * 0.08))

                    ZStack {
                        Image(systemName: "flag.checkered.2.crossed")
                            .font(.system(size: min(84, width * 0.2), weight: .bold))
                            .foregroundStyle(.white.opacity(0.9))
                        Image(systemName: "trophy.fill")
                            .font(.system(size: min(42, width * 0.1), weight: .black))
                            .foregroundStyle(.yellow.gradient)
                            .shadow(color: .yellow.opacity(0.7), radius: 12)
                            .offset(y: -4)
                    }
                    .accessibilityHidden(true)

                    Text("ANYWHERE")
                        .font(.system(
                            size: min(58, width * 0.14),
                            weight: .black,
                            design: .rounded
                        ))
                        .tracking(-2)
                        .foregroundStyle(.white)
                        .shadow(color: .blue.opacity(0.8), radius: 12)

                    Text("GP")
                        .font(.system(
                            size: min(112, width * 0.28),
                            weight: .black,
                            design: .rounded
                        ))
                        .italic()
                        .tracking(-8)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.yellow, .orange],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .shadow(color: .orange.opacity(0.55), radius: 18, y: 8)
                        .padding(.trailing, 8)
                        .offset(y: -10)

                    Text("AR TABLETOP RACING")
                        .font(.caption.weight(.black))
                        .tracking(4)
                        .foregroundStyle(.white.opacity(0.72))
                        .offset(y: -6)

                    Spacer()

                    Button(action: onStart) {
                        HStack(spacing: 12) {
                            Image(systemName: "play.fill")
                            Text("PRESS START")
                        }
                        .font(.system(size: 24, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: logoWidth)
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
                    .accessibilityLabel("ゲームを開始")

                    Text("どこでも、そこがサーキット。")
                        .font(.callout.bold())
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.top, 22)

                    Spacer(minLength: max(34, proxy.size.height * 0.07))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                isStartHighlighted = true
            }
        }
    }

    private var racingBackdrop: some View {
        Canvas { context, size in
            let horizon = size.height * 0.46
            for index in 0..<11 {
                let fraction = CGFloat(index) / 10
                var line = Path()
                line.move(to: CGPoint(x: size.width * 0.5, y: horizon))
                line.addLine(to: CGPoint(
                    x: (fraction * 1.5 - 0.25) * size.width,
                    y: size.height
                ))
                context.stroke(
                    line,
                    with: .color(.cyan.opacity(0.13)),
                    lineWidth: index.isMultiple(of: 2) ? 2 : 1
                )
            }

            let tile = max(18, size.width / 18)
            let bandY = size.height * 0.7
            let columnCount = Int(ceil(size.width / tile)) + 1
            for row in 0..<2 {
                for column in 0..<columnCount where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(column) * tile,
                        y: bandY + CGFloat(row) * tile,
                        width: tile,
                        height: tile
                    )
                    context.fill(Path(rect), with: .color(.white.opacity(0.09)))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview {
    TitleView(onStart: {})
}
