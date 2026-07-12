//
//  Haptics.swift
//  RaceKing
//

#if os(iOS)
import UIKit

/// Maps game events to haptic feedback.
final class Haptics {
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()

    func handle(_ event: GameEvent) {
        switch event {
        case .countdownTick:
            medium.impactOccurred()
        case .go:
            heavy.impactOccurred()
        case .lapCompleted(let isBest):
            if isBest {
                notification.notificationOccurred(.success)
            } else {
                medium.impactOccurred()
            }
        case .raceFinished:
            notification.notificationOccurred(.success)
        case .offRoad:
            light.impactOccurred(intensity: 0.7)
        case .wallHit:
            rigid.impactOccurred()
        }
    }
}
#endif
