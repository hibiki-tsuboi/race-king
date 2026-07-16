//
//  PeerRaceProtocol.swift
//  RaceKing
//

import Foundation

/// One racer in a nearby room. The host owns slot and readiness assignment.
struct PeerRaceParticipant: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var slot: Int
    var isReady: Bool
    var carChoice: RaceCarChoice
}

/// One length-prefixed JSON message exchanged through a nearby-race host.
struct PeerRacePacket: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case hello
        case roster
        case joinRejected
        case ready
        case courseSyncReset
        case courseSyncStarted
        case courseMap
        case courseMapApplied
        case courseSyncCompleted
        case courseMapFailed
        case carSelection
        case carModel
        case carModelReady
        case carModelFailed
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
    var playerID: UUID?
    var name: String?
    var protocolVersion: Int?
    var participants: [PeerRaceParticipant]?
    var isReady: Bool?
    var carChoice: RaceCarChoice?
    var carModelID: UUID?
    var carModelData: Data?
    var carModelFlipped: Bool?
    var courseSyncID: UUID?
    var coursePlacement: CoursePlacement?
    var worldMapData: Data?
    var message: String?
    var carState: CarState?
    var raceTime: TimeInterval?
    var position: Int?

    static let currentVersion = 7

    static func hello(
        playerID: UUID, name: String, carChoice: RaceCarChoice
    ) -> Self {
        Self(
            kind: .hello,
            playerID: playerID,
            name: name,
            protocolVersion: currentVersion,
            carChoice: carChoice
        )
    }

    static func roster(_ participants: [PeerRaceParticipant]) -> Self {
        Self(kind: .roster, participants: participants)
    }

    static func joinRejected(_ message: String) -> Self {
        Self(kind: .joinRejected, message: message)
    }

    static func ready(playerID: UUID, isReady: Bool) -> Self {
        Self(kind: .ready, playerID: playerID, isReady: isReady)
    }

    static var courseSyncReset: Self { Self(kind: .courseSyncReset) }

    static func courseSyncStarted(id: UUID) -> Self {
        Self(kind: .courseSyncStarted, courseSyncID: id)
    }

    static func courseMap(
        id: UUID, data: Data, placement: CoursePlacement
    ) -> Self {
        Self(
            kind: .courseMap,
            courseSyncID: id,
            coursePlacement: placement,
            worldMapData: data
        )
    }

    static func courseMapApplied(id: UUID) -> Self {
        Self(kind: .courseMapApplied, courseSyncID: id)
    }

    static func courseSyncCompleted(id: UUID) -> Self {
        Self(kind: .courseSyncCompleted, courseSyncID: id)
    }

    static func courseMapFailed(id: UUID?, message: String) -> Self {
        Self(kind: .courseMapFailed, courseSyncID: id, message: message)
    }

    static func carSelection(playerID: UUID, choice: RaceCarChoice) -> Self {
        Self(kind: .carSelection, playerID: playerID, carChoice: choice)
    }

    static func carModel(
        playerID: UUID, id: UUID, data: Data, flipped: Bool
    ) -> Self {
        Self(
            kind: .carModel,
            playerID: playerID,
            carModelID: id,
            carModelData: data,
            carModelFlipped: flipped
        )
    }

    static func carModelReady(playerID: UUID, id: UUID) -> Self {
        Self(kind: .carModelReady, playerID: playerID, carModelID: id)
    }

    static func carModelFailed(
        playerID: UUID, id: UUID, message: String
    ) -> Self {
        Self(
            kind: .carModelFailed,
            playerID: playerID,
            carModelID: id,
            message: message
        )
    }

    static var startRace: Self { Self(kind: .startRace) }

    static func carState(playerID: UUID, state: CarState) -> Self {
        Self(kind: .carState, playerID: playerID, carState: state)
    }

    static func finish(playerID: UUID, raceTime: TimeInterval) -> Self {
        Self(kind: .finish, playerID: playerID, raceTime: raceTime)
    }

    static func finishResult(
        playerID: UUID, position: Int, raceTime: TimeInterval
    ) -> Self {
        Self(
            kind: .finishResult,
            playerID: playerID,
            raceTime: raceTime,
            position: position
        )
    }

    static var raceComplete: Self { Self(kind: .raceComplete) }

    static var resetRace: Self { Self(kind: .resetRace) }
}
