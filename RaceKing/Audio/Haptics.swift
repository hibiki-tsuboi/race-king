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
        case .driftStarted:
            medium.impactOccurred(intensity: 0.8)
        case .driftPulse:
            light.impactOccurred(intensity: 0.45)
        case .driftChargeLevelUp(let level):
            (level >= 2 ? heavy : rigid).impactOccurred()
        case .driftEnded(let boostLevel):
            if boostLevel > 0 { heavy.impactOccurred() }
        }
    }
}
#endif
