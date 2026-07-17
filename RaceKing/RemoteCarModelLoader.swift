//
//  RemoteCarModelLoader.swift
//  RaceKing
//

import Foundation
import RealityKit

/// Serializes untrusted nearby-player model parsing per participant.
/// Cancellation alone cannot stop every RealityKit parse, so a replacement
/// waits for the previous task to finish before starting another one.
@MainActor
final class RemoteCarModelLoader {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var currentModelIDs: [UUID: UUID] = [:]
    private var tailTask: Task<Void, Never>?
    private var tailModelID: UUID?

    func enqueue(
        playerID: UUID,
        modelID: UUID,
        data: Data,
        isCurrent: @escaping @MainActor () -> Bool,
        onLoaded: @escaping @MainActor (Entity) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        do {
            try EntityFactory.validateImportedCar(data: data)
        } catch {
            onFailure(error.localizedDescription)
            return
        }

        // RealityKit parsing is not reliably cancellable. Chain every model,
        // including different participants, so a removed/replaced owner can
        // never leave a parse running beside the next admitted model.
        let previous = tailTask
        currentModelIDs[playerID] = modelID
        let task = Task { [weak self] in
            let temporaryURL = FileManager.default.temporaryDirectory.appending(
                path: "RaceKing-PeerCar-\(playerID.uuidString)-\(modelID.uuidString).usdz"
            )
            defer {
                try? FileManager.default.removeItem(at: temporaryURL)
                if self?.currentModelIDs[playerID] == modelID {
                    self?.tasks[playerID] = nil
                    self?.currentModelIDs[playerID] = nil
                }
                if self?.tailModelID == modelID {
                    self?.tailTask = nil
                    self?.tailModelID = nil
                }
            }
            await previous?.value
            guard !Task.isCancelled, isCurrent() else { return }

            do {
                try await Task.detached(priority: .utility) {
                    try data.write(to: temporaryURL, options: .atomic)
                    try EntityFactory.validateImportedCar(at: temporaryURL)
                }.value
                guard !Task.isCancelled, isCurrent() else { return }
                let template = try await Entity(contentsOf: temporaryURL)
                guard !Task.isCancelled, isCurrent() else { return }
                onLoaded(template)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent() else { return }
                onFailure(error.localizedDescription)
            }
        }
        tasks[playerID] = task
        tailTask = task
        tailModelID = modelID
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        currentModelIDs.removeAll()
        // Keep the cancelled tail until it actually returns. A new session's
        // first model will await it instead of parsing concurrently.
    }
}
