//
//  RoomScanView.swift
//  RaceKing
//

import ARKit
import RoomPlan
import SwiftUI

/// Full-screen RoomPlan capture with controls that keep the shared ARSession
/// alive when transitioning back to RealityKit.
struct RoomScanView: View {
    let arSession: ARSession
    let onComplete: (CapturedRoom) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    @State private var finishRequested = false

    var body: some View {
        ZStack(alignment: .top) {
            RoomCaptureRepresentable(
                arSession: arSession,
                finishRequested: finishRequested,
                onComplete: onComplete,
                onError: onError
            )
            .ignoresSafeArea()

            HStack {
                Button("キャンセル") { onCancel() }
                    .disabled(finishRequested)

                Spacer()

                if finishRequested {
                    ProgressView()
                        .tint(.white)
                } else {
                    Button("スキャン完了") { finishRequested = true }
                        .fontWeight(.bold)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.black.opacity(0.55))
        }
        .persistentSystemOverlays(.hidden)
    }
}

private struct RoomCaptureRepresentable: UIViewRepresentable {
    let arSession: ARSession
    let finishRequested: Bool
    let onComplete: (CapturedRoom) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onError: onError)
    }

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        view.delegate = context.coordinator
        view.isModelEnabled = true
        context.coordinator.captureView = view
        view.captureSession.run(configuration: RoomCaptureSession.Configuration())
        return view
    }

    func updateUIView(_ view: RoomCaptureView, context: Context) {
        if finishRequested { context.coordinator.finishCapture() }
    }

    static func dismantleUIView(_ view: RoomCaptureView, coordinator: Coordinator) {
        coordinator.cancelCaptureIfNeeded()
    }

    @MainActor
    @objc(RKRoomCaptureCoordinator)
    final class Coordinator: NSObject, RoomCaptureViewDelegate {
        weak var captureView: RoomCaptureView?

        private let onComplete: (CapturedRoom) -> Void
        private let onError: (String) -> Void
        private var isStopping = false
        private var deliveredResult = false

        init(
            onComplete: @escaping (CapturedRoom) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onComplete = onComplete
            self.onError = onError
            super.init()
        }

        required init?(coder: NSCoder) {
            nil
        }

        func encode(with coder: NSCoder) {}

        func finishCapture() {
            guard !isStopping else { return }
            isStopping = true
            captureView?.captureSession.stop(pauseARSession: false)
        }

        func cancelCaptureIfNeeded() {
            guard !isStopping else { return }
            isStopping = true
            deliveredResult = true
            captureView?.captureSession.stop(pauseARSession: false)
        }

        func captureView(
            shouldPresent roomDataForProcessing: CapturedRoomData,
            error: Error?
        ) -> Bool {
            if let error {
                deliver(error: error)
                return false
            }
            return true
        }

        func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
            if let error {
                deliver(error: error)
            } else if !deliveredResult {
                deliveredResult = true
                onComplete(processedResult)
            }
        }

        private func deliver(error: Error) {
            guard !deliveredResult else { return }
            deliveredResult = true
            onError(error.localizedDescription)
        }
    }
}
