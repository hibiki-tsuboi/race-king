//
//  ARSessionMonitor.swift
//  RaceKing
//

import ARKit

/// Bridges ARKit lifecycle callbacks into ContentView's main-actor state.
@MainActor
final class ARSessionMonitor: NSObject, ARSessionDelegate {
    var onInterrupted: (() -> Void)?
    var onInterruptionEnded: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onTrackingNormal: (() -> Void)?
    var onTrackingLimited: ((String) -> Void)?
    private var limitedTrackingTask: Task<Void, Never>?

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.onInterrupted?()
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.onInterruptionEnded?()
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.onFailure?(message)
        }
    }

    nonisolated func session(
        _ session: ARSession,
        cameraDidChangeTrackingState camera: ARCamera
    ) {
        let limitation: String? = switch camera.trackingState {
        case .normal:
            nil
        case .notAvailable:
            "カメラ位置を追跡できません。端末をゆっくり動かしてください。"
        case .limited(.initializing):
            "ARを初期化しています。周囲をゆっくり映してください。"
        case .limited(.excessiveMotion):
            "端末の動きが速すぎます。ゆっくり動かしてください。"
        case .limited(.insufficientFeatures):
            "特徴のある床や周囲を映してください。"
        case .limited(.relocalizing):
            "コース位置を復元しています。元の場所を映してください。"
        @unknown default:
            "ARの追跡を待っています。周囲をゆっくり映してください。"
        }
        Task { @MainActor [weak self] in
            if let limitation {
                self?.handleTrackingLimitation(limitation)
            } else {
                self?.limitedTrackingTask?.cancel()
                self?.limitedTrackingTask = nil
                self?.onTrackingNormal?()
            }
        }
    }

    private func handleTrackingLimitation(_ message: String) {
        limitedTrackingTask?.cancel()
        limitedTrackingTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            self?.onTrackingLimited?(message)
        }
    }

    nonisolated func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        true
    }
}
