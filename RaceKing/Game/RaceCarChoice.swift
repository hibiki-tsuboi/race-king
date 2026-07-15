//
//  RaceCarChoice.swift
//  RaceKing
//

import Foundation

/// A bundled car that both nearby-race clients can identify without
/// transferring model files. Raw values are part of the wire protocol.
enum RaceCarChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case green
    case red
    case blue
    case white

    var id: Self { self }

    var displayName: String {
        switch self {
        case .green: "緑"
        case .red: "赤"
        case .blue: "青"
        case .white: "白"
        }
    }

    var resourceName: String {
        switch self {
        case .green: "PlayerCar"
        case .red: "AICar1"
        case .blue: "AICar2"
        case .white: "AICar3"
        }
    }
}
