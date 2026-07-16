//
//  PeerCourseCoordinator.swift
//  RaceKing
//

import ARKit
import Foundation
import Observation

/// Shares the host's AR world and waits for the guest to relocalize to it.
@MainActor
@Observable
final class PeerCourseCoordinator {
    @ObservationIgnored private weak var arSession: ARSession?
    @ObservationIgnored private weak var game: RaceGame?
    @ObservationIgnored private weak var multiplayer: PeerRaceSession?
    @ObservationIgnored private var pendingPlacement: PeerRacePacket.CoursePlacement?
    @ObservationIgnored private var relocalizationElapsed: TimeInterval = 0
    @ObservationIgnored private var observedRelocalizing = false
    @ObservationIgnored private var placementApplied = false
    @ObservationIgnored private var usingSharedWorldMap = false

    static func worldTrackingConfiguration(
        initialWorldMap: ARWorldMap? = nil
    ) -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.initialWorldMap = initialWorldMap
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        return configuration
    }

    func configure(
        arSession: ARSession,
        game: RaceGame,
        multiplayer: PeerRaceSession
    ) {
        self.arSession = arSession
        self.game = game
        self.multiplayer = multiplayer

        multiplayer.onCourseMapRequested = { [weak self] in
            self?.captureAndSendCourse()
        }
        multiplayer.onCourseMapReceived = { [weak self] data, placement in
            self?.receiveCourse(data: data, placement: placement)
        }
        multiplayer.onCourseSyncInvalidated = { [weak self] in
            self?.courseSyncInvalidated()
        }
    }

    func connectionChanged(_ connected: Bool) {
        guard let game, let multiplayer else { return }
        clearPendingRelocalization()
        if connected, multiplayer.role == .guest {
            game.prepareForSharedCourse()
        } else {
            resetSharedGuestSessionIfNeeded()
            if multiplayer.role == .host {
                game.cancelSharedCoursePreparation()
            } else {
                game.prepareForSharedCourse()
            }
        }
    }

    func updateRelocalization(deltaTime: TimeInterval) {
        guard let placement = pendingPlacement,
              let arSession, let game, let multiplayer,
              multiplayer.courseSyncState == .relocalizing else {
            if multiplayer?.courseSyncState != .relocalizing {
                clearPendingRelocalization()
            }
            return
        }

        relocalizationElapsed += deltaTime
        if relocalizationElapsed >= 30 {
            multiplayer.failCourseShare(
                "位置合わせに時間がかかっています。全端末で同じ机と周囲を映して再試行してください"
            )
            return
        }

        if placementApplied {
            guard game.isCourseAnchored else { return }
            clearPendingRelocalization()
            multiplayer.confirmCourseMapApplied()
            return
        }

        guard let frame = arSession.currentFrame else { return }
        switch frame.camera.trackingState {
        case .limited(.relocalizing):
            observedRelocalizing = true
        case .normal where observedRelocalizing || relocalizationElapsed >= 1:
            guard game.applySharedCoursePlacement(
                placement, spatiallyAnchored: true
            ) else {
                multiplayer.failCourseShare("共有コースの位置情報が不正です")
                return
            }
            placementApplied = true
        default:
            break
        }
    }

    // MARK: - Host

    private func captureAndSendCourse() {
        guard let arSession, let game, let multiplayer,
              let placement = game.sharedCoursePlacement() else {
            multiplayer?.failCourseShare("コースを床かテーブルに配置してください")
            return
        }

        #if targetEnvironment(simulator)
        multiplayer.sendCourseMap(Data(), placement: placement)
        #else
        guard !game.virtualModeActive else {
            multiplayer.failCourseShare("実空間を共有するWi-Fi対戦ではARモードが必要です")
            return
        }
        guard let frame = arSession.currentFrame else {
            multiplayer.failCourseShare("ARカメラを準備できませんでした")
            return
        }
        switch frame.worldMappingStatus {
        case .extending, .mapped:
            break
        case .notAvailable, .limited:
            multiplayer.failCourseShare(
                "周囲をゆっくり映してから、もう一度コースを共有してください"
            )
            return
        @unknown default:
            multiplayer.failCourseShare("AR空間の状態を確認できませんでした")
            return
        }

        arSession.getCurrentWorldMap { [weak self] worldMap, error in
            guard let worldMap else {
                let message = error?.localizedDescription
                    ?? "ARマップを作成できませんでした"
                Task { @MainActor [weak self] in
                    self?.multiplayer?.failCourseShare(message)
                }
                return
            }
            do {
                let data = try NSKeyedArchiver.archivedData(
                    withRootObject: worldMap,
                    requiringSecureCoding: true
                )
                Task { @MainActor [weak self] in
                    self?.multiplayer?.sendCourseMap(data, placement: placement)
                }
            } catch {
                Task { @MainActor [weak self] in
                    self?.multiplayer?.failCourseShare(
                        "ARマップを保存できませんでした: \(error.localizedDescription)"
                    )
                }
            }
        }
        #endif
    }

    // MARK: - Guest

    private func receiveCourse(
        data: Data,
        placement: PeerRacePacket.CoursePlacement
    ) {
        guard let arSession, let game, let multiplayer else { return }
        game.prepareForSharedCourse()

        #if targetEnvironment(simulator)
        if game.applySharedCoursePlacement(placement, spatiallyAnchored: false) {
            multiplayer.confirmCourseMapApplied()
        } else {
            multiplayer.failCourseShare("共有コースの位置情報が不正です")
        }
        #else
        guard !game.virtualModeActive else {
            multiplayer.failCourseShare("実空間を共有するWi-Fi対戦ではARモードが必要です")
            return
        }
        guard !data.isEmpty else {
            multiplayer.failCourseShare("ホストからARマップを受信できませんでした")
            return
        }
        do {
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARWorldMap.self,
                from: data
            ) else {
                multiplayer.failCourseShare("ホストのARマップを読み取れませんでした")
                return
            }
            pendingPlacement = placement
            relocalizationElapsed = 0
            observedRelocalizing = false
            placementApplied = false
            usingSharedWorldMap = true
            let configuration = Self.worldTrackingConfiguration(
                initialWorldMap: worldMap
            )
            arSession.run(
                configuration,
                options: [.resetTracking, .removeExistingAnchors]
            )
        } catch {
            multiplayer.failCourseShare(
                "ホストのARマップを読み取れませんでした: \(error.localizedDescription)"
            )
        }
        #endif
    }

    private func courseSyncInvalidated() {
        guard let game, let multiplayer else { return }
        clearPendingRelocalization()
        resetSharedGuestSessionIfNeeded()
        if multiplayer.state == .connected, multiplayer.role == .guest {
            game.prepareForSharedCourse()
        } else {
            game.cancelSharedCoursePreparation()
        }
    }

    private func clearPendingRelocalization() {
        pendingPlacement = nil
        relocalizationElapsed = 0
        observedRelocalizing = false
        placementApplied = false
    }

    private func resetSharedGuestSessionIfNeeded() {
        guard usingSharedWorldMap, let arSession, let game else { return }
        usingSharedWorldMap = false
        if !game.virtualModeActive {
            arSession.run(
                Self.worldTrackingConfiguration(),
                options: [.resetTracking, .removeExistingAnchors]
            )
            game.restoreLocalCoursePlacement()
        }
    }
}
