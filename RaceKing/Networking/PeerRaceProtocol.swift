//
//  PeerRaceProtocol.swift
//  RaceKing
//

import Foundation

/// One length-prefixed JSON message exchanged by two nearby RaceKing clients.
struct PeerRacePacket: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello
        case ready
        case courseSyncStarted
        case courseMap
        case courseMapApplied
        case courseMapFailed
        case carSelection
        case startRace
        case carState
        case finish
        case finishResult
        case raceComplete
        case resetRace
    }

    struct CarState: Codable, Sendable {
        let x: Float
        let y: Float
        let z: Float
        let heading: Float
        let progress: Float
        let lapCount: Int
        let finished: Bool
        let drifting: Bool
        let boosting: Bool
        let driftChargeLevel: Int
    }

    /// The course root's rigid pose in the host AR world's coordinates.
    struct CoursePlacement: Codable, Sendable {
        let x: Float
        let y: Float
        let z: Float
        let quaternionX: Float
        let quaternionY: Float
        let quaternionZ: Float
        let quaternionW: Float
        let scale: Float
    }

    let kind: Kind
    var name: String?
    var protocolVersion: Int?
    var isReady: Bool?
    var carChoice: RaceCarChoice?
    var coursePlacement: CoursePlacement?
    var worldMapData: Data?
    var message: String?
    var carState: CarState?
    var raceTime: TimeInterval?
    var position: Int?

    static let currentVersion = 3

    static func hello(name: String, carChoice: RaceCarChoice) -> Self {
        Self(
            kind: .hello,
            name: name,
            protocolVersion: currentVersion,
            carChoice: carChoice
        )
    }

    static func ready(_ isReady: Bool) -> Self {
        Self(kind: .ready, isReady: isReady)
    }

    static var courseSyncStarted: Self { Self(kind: .courseSyncStarted) }

    static func courseMap(
        data: Data, placement: CoursePlacement
    ) -> Self {
        Self(
            kind: .courseMap,
            coursePlacement: placement,
            worldMapData: data
        )
    }

    static var courseMapApplied: Self { Self(kind: .courseMapApplied) }

    static func courseMapFailed(_ message: String) -> Self {
        Self(kind: .courseMapFailed, message: message)
    }

    static func carSelection(_ choice: RaceCarChoice) -> Self {
        Self(kind: .carSelection, carChoice: choice)
    }

    static var startRace: Self { Self(kind: .startRace) }

    static func carState(_ state: CarState) -> Self {
        Self(kind: .carState, carState: state)
    }

    static func finish(raceTime: TimeInterval) -> Self {
        Self(kind: .finish, raceTime: raceTime)
    }

    static func finishResult(position: Int, raceTime: TimeInterval) -> Self {
        Self(kind: .finishResult, raceTime: raceTime, position: position)
    }

    static var raceComplete: Self { Self(kind: .raceComplete) }

    static var resetRace: Self { Self(kind: .resetRace) }
}
