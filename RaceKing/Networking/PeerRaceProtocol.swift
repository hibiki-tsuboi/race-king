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

    let kind: Kind
    var name: String?
    var protocolVersion: Int?
    var isReady: Bool?
    var carState: CarState?
    var raceTime: TimeInterval?
    var position: Int?

    static func hello(name: String) -> Self {
        Self(kind: .hello, name: name, protocolVersion: 1)
    }

    static func ready(_ isReady: Bool) -> Self {
        Self(kind: .ready, isReady: isReady)
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
