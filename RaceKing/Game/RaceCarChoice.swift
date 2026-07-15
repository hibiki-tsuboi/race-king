//
//  RaceCarChoice.swift
//  RaceKing
//

import Foundation

/// A car selection shared by nearby-race clients. Raw values are part of the
/// wire protocol; the imported option also transfers its USDZ for the session.
enum RaceCarChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case green
    case red
    case blue
    case white
    case yellow
    case imported

    var id: Self { self }

    var displayName: String {
        switch self {
        case .green: "緑"
        case .red: "赤"
        case .blue: "青"
        case .white: "白"
        case .yellow: "黄"
        case .imported: "取込"
        }
    }

    var resourceName: String? {
        switch self {
        case .green: "PlayerCar"
        case .red: "AICar1"
        case .blue: "AICar2"
        case .white: "AICar3"
        case .yellow: "AICar4"
        case .imported: nil
        }
    }
}
