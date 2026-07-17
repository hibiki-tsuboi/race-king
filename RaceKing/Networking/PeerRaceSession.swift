//
//  PeerRaceSession.swift
//  RaceKing
//

import Foundation
import Network
import Observation
import UIKit

private final class PeerConnectionContext {
    let id = UUID()
    let connection: NWConnection
    let rejectionMessage: String?
    var playerID: UUID?
    var receiveBuffer = Data()
    var handshakeTimeoutTask: Task<Void, Never>?
    var carModelViolationCount = 0

    init(connection: NWConnection, rejectionMessage: String? = nil) {
        self.connection = connection
        self.rejectionMessage = rejectionMessage
    }
}

private struct StoredPeerCarModel {
    let id: UUID
    let data: Data
    let flipped: Bool
}

private struct RemoteCarModelBudget {
    var bytes = 0
    var transferCount = 0
    var lastTransferTime: TimeInterval?
}

private struct PeerFinishRecord {
    let raceTime: TimeInterval
    let hostFinishTime: TimeInterval
}

private struct PendingRemoteCarModelLoad {
    let ownerID: UUID
    let id: UUID
    let data: Data
    let flipped: Bool
}

/// Hosts or joins a nearby room. The host relays traffic for up to four guests.
@MainActor
@Observable
final class PeerRaceSession {
    enum Role: Equatable {
        case host
        case guest
    }

    enum State: Equatable {
        case idle
        case hosting
        case browsing
        case connecting
        case connected
    }

    enum CourseSyncState: Equatable {
        case unavailable
        case hostPlacement
        case waitingForHost
        case preparingMap
        case waitingForMap
        case relocalizing
        case waitingForGuest
        case synchronized
        case failed(String)
    }

    struct Room: Identifiable, Hashable {
        let endpoint: NWEndpoint
        let name: String

        var id: NWEndpoint { endpoint }
    }

    private enum ImportedCarFileError: LocalizedError {
        case missing
        case tooLarge
        case invalid

        var errorDescription: String? {
            switch self {
            case .missing:
                "インポートした車が見つかりません"
            case .tooLarge:
                "Wi-Fi対戦で共有できる車は12MB以下です"
            case .invalid:
                "インポートした車のUSDZを読み取れません"
            }
        }
    }

    static let maximumPlayers = 5
    private static let serviceType = "_anywheregp._tcp"
    private static let maximumPacketSize = 64 * 1024 * 1024
    /// Guests never send world maps, so their largest valid frame is one
    /// base64-encoded 12 MB car model plus a small JSON envelope.
    private static let maximumGuestToHostPacketSize = 17 * 1024 * 1024
    /// A hello only contains the guest ID, display name, version, and car choice.
    private static let maximumHelloPacketSize = 4 * 1024
    /// Limits sockets that have not yet supplied a valid hello packet.
    private static let maximumPendingHostConnections = 2
    private static let handshakeTimeout: Duration = .seconds(5)
    private static let maximumWorldMapSize = 40 * 1024 * 1024
    private static let maximumCarModelSize = 12 * 1024 * 1024
    private static let maximumRemoteCarModelBytesPerParticipant = 24 * 1024 * 1024
    private static let maximumRemoteCarModelBytesPerSession = 72 * 1024 * 1024
    private static let maximumRemoteCarModelTransfersPerParticipant = 3
    private static let minimumRemoteCarModelTransferInterval: TimeInterval = 1
    private static let maximumCarModelViolations = 3
    private static let maximumConcurrentRemoteCarModelLoads = 1
    private static let snapshotInterval: TimeInterval = 1.0 / 20.0
    /// The countdown itself lasts three seconds; this lead time lets every
    /// peer receive the command and schedule that countdown against one clock.
    private static let raceStartLeadTime: TimeInterval = 1.5
    private static let minimumScheduledStartLeadTime: TimeInterval = 0.15
    private static let maximumScheduledStartLeadTime: TimeInterval = 10
    private static let maximumClockSyncRoundTripTime: TimeInterval = 0.5
    private static let clockSyncRefreshInterval: Duration = .seconds(5)
    /// Parsing arbitrary peer-provided RealityKit scenes cannot be placed in
    /// a crash-isolated process on iOS. Keep custom cars local until a format
    /// with enforceable mesh/texture budgets replaces raw USDZ sharing.
    private static let importedCarSharingEnabled = false
    private static let carChoiceDefaultsKey = "peerRaceCarChoice"

    let localPlayerID: UUID
    private let localPlayerName: String
    private(set) var state: State = .idle
    private(set) var role: Role?
    private(set) var rooms: [Room] = []
    private(set) var participants: [PeerRaceParticipant]
    private(set) var raceComplete = false
    private(set) var errorMessage: String?
    private(set) var courseSyncState: CourseSyncState = .unavailable
    private(set) var localImportedCarAvailable: Bool
    private(set) var localCarChoice: RaceCarChoice
    private(set) var localImportedCarAcknowledged = true
    private var localCarModelErrorMessage: String?
    private var remoteCarModelErrorMessages: [UUID: String] = [:]
    private var remoteImportedCarReadyIDs: Set<UUID> = []
    private var remoteCarModelTransferIDs: [UUID: UUID] = [:]
    private var modelAcknowledgements: [UUID: Set<UUID>] = [:]
    private var courseAppliedParticipantIDs: Set<UUID> = []
    private var currentCourseSyncID: UUID?

    var localReady: Bool {
        participants.first(where: { $0.id == localPlayerID })?.isReady ?? false
    }

    var remoteParticipants: [PeerRaceParticipant] {
        participants.filter { $0.id != localPlayerID }.sorted { $0.slot < $1.slot }
    }

    var remoteReady: Bool {
        !remoteParticipants.isEmpty && remoteParticipants.allSatisfy(\.isReady)
    }

    var allParticipantsReady: Bool {
        participants.count >= 2 && participants.allSatisfy(\.isReady)
    }

    var carModelErrorMessage: String? {
        localCarModelErrorMessage
            ?? remoteCarModelErrorMessages.sorted { $0.key.uuidString < $1.key.uuidString }
                .first?.value
    }

    var availableLocalCarChoices: [RaceCarChoice] {
        RaceCarChoice.allCases.filter {
            $0 != .imported
                || Self.importedCarSharingEnabled && localImportedCarAvailable
        }
    }

    var carModelsSynchronized: Bool {
        switch role {
        case .host:
            let requiredIDs = Set(participants.map(\.id))
            for participant in participants where participant.carChoice == .imported {
                guard storedCarModels[participant.id] != nil,
                      requiredIDs.isSubset(
                        of: modelAcknowledgements[participant.id] ?? []
                      ) else { return false }
            }
            return true
        case .guest:
            if localCarChoice == .imported, !localImportedCarAcknowledged {
                return false
            }
            return remoteParticipants.allSatisfy {
                $0.carChoice != .imported
                    || remoteImportedCarReadyIDs.contains($0.id)
            }
        case nil:
            return localCarChoice != .imported || localImportedCarAvailable
        }
    }

    var isSynchronizingCarModels: Bool {
        state == .connected
            && participants.contains { $0.carChoice == .imported }
            && !carModelsSynchronized
            && carModelErrorMessage == nil
    }

    var canStartRace: Bool {
        state == .connected && role == .host && !raceInProgress
            && courseSyncState == .synchronized
            && participants.count >= 2
            && carModelsSynchronized
            && allParticipantsReady
    }

    var isCourseSynchronized: Bool { courseSyncState == .synchronized }

    var canSetReady: Bool {
        state == .connected && participants.count >= 2
            && isCourseSynchronized && carModelsSynchronized
            && (role == .host || hostClockOffset != nil)
    }

    var canRequestCourseShare: Bool {
        guard state == .connected, role == .host,
              participants.count >= 2, carModelsSynchronized else { return false }
        switch courseSyncState {
        case .hostPlacement, .failed(_):
            return true
        default:
            return false
        }
    }

    /// Only the host may manipulate the local course before it is shared.
    var canEditHostCourse: Bool {
        guard role == .host,
              state == .hosting || state == .connected else { return false }
        switch courseSyncState {
        case .hostPlacement, .failed(_):
            return true
        default:
            return false
        }
    }

    var courseSynchronizedGuestCount: Int {
        courseAppliedParticipantIDs.intersection(Set(remoteParticipants.map(\.id))).count
    }

    var connectionStatusText: String {
        switch state {
        case .idle: "未接続"
        case .hosting: "参加を待っています"
        case .browsing: "ルームを探しています"
        case .connecting: "接続しています"
        case .connected: "接続済み（\(participants.count)/\(Self.maximumPlayers)人）"
        }
    }

    @ObservationIgnored var onStartRace: (() -> Bool)?
    @ObservationIgnored var onResetRace: (() -> Void)?
    @ObservationIgnored var onCarState: ((UUID, PeerRacePacket.CarState) -> Void)?
    @ObservationIgnored var onLocalCarChoiceChanged: ((RaceCarChoice) -> Void)?
    @ObservationIgnored var onParticipantsChanged: (([PeerRaceParticipant], UUID) -> Void)?
    @ObservationIgnored var onRemoteImportedCarModel: ((UUID, Data, Bool, UUID) -> Void)?
    @ObservationIgnored var onFinishResult: ((Int, TimeInterval) -> Void)?
    @ObservationIgnored var onConnectionChanged: ((Bool) -> Void)?
    @ObservationIgnored var onCourseMapRequested: (() -> Void)?
    @ObservationIgnored var onCourseMapReceived: ((Data, PeerRacePacket.CoursePlacement) -> Void)?
    @ObservationIgnored var onCourseSyncInvalidated: (() -> Void)?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connections: [UUID: PeerConnectionContext] = [:]
    @ObservationIgnored private var hostConnectionID: UUID?
    @ObservationIgnored private var storedCarModels: [UUID: StoredPeerCarModel] = [:]
    @ObservationIgnored private var localCarModelTransferID: UUID?
    @ObservationIgnored private var snapshotAccumulator: TimeInterval = 0
    @ObservationIgnored private var finishOrder: [UUID] = []
    @ObservationIgnored private var finishRecords: [UUID: PeerFinishRecord] = [:]
    private var raceInProgress = false
    @ObservationIgnored private var currentRoundID: UUID?
    @ObservationIgnored private var scheduledHostStartTime: TimeInterval?
    @ObservationIgnored private var scheduledRaceStartTask: Task<Void, Never>?
    @ObservationIgnored private var clockSyncTask: Task<Void, Never>?
    @ObservationIgnored private var pendingClockProbes: [UInt64: TimeInterval] = [:]
    @ObservationIgnored private var nextClockSequence: UInt64 = 0
    @ObservationIgnored private var bestClockRoundTripTime: TimeInterval?
    private var hostClockOffset: TimeInterval?
    @ObservationIgnored private var activeRemoteCarModelLoads: [UUID: UUID] = [:]
    @ObservationIgnored private var pendingRemoteCarModelLoads: [PendingRemoteCarModelLoad] = []
    @ObservationIgnored private var remoteCarModelBudgets: [UUID: RemoteCarModelBudget] = [:]
    @ObservationIgnored private var remoteCarModelSessionBytes = 0
    @ObservationIgnored private var remoteCarModelViolationCount = 0
    @ObservationIgnored private var lastConnectionNotification = false
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init() {
        localPlayerID = UUID()
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        localPlayerName = String((name.isEmpty ? "iPhone" : name).prefix(40))
        let importedCarAvailable = EntityFactory.hasImportedPlayerCar
        localImportedCarAvailable = importedCarAvailable
        let saved = RaceCarChoice(
            rawValue: UserDefaults.standard.string(
                forKey: Self.carChoiceDefaultsKey
            ) ?? ""
        ) ?? .green
        let initialCarChoice: RaceCarChoice = saved == .imported
            && (!Self.importedCarSharingEnabled || !importedCarAvailable)
            ? .green : saved
        if initialCarChoice != saved {
            UserDefaults.standard.set(
                initialCarChoice.rawValue,
                forKey: Self.carChoiceDefaultsKey
            )
        }
        localCarChoice = initialCarChoice
        participants = [PeerRaceParticipant(
            id: localPlayerID,
            name: localPlayerName,
            slot: 0,
            isReady: false,
            carChoice: initialCarChoice
        )]
        localImportedCarAcknowledged = initialCarChoice != .imported
    }

    // MARK: - Room lifecycle

    func startHosting() {
        disconnect()
        role = .host
        state = .hosting
        errorMessage = nil
        resetLocalParticipant(slot: 0)
        resetCourseSyncState()
        resetCarModelSyncState()
        prepareHostLocalModelIfNeeded()

        do {
            let listener = try NWListener(using: networkParameters())
            listener.service = .init(
                name: "\(localPlayerName)のレース",
                type: Self.serviceType
            )
            listener.stateUpdateHandler = { [weak self, weak listener] newState in
                MainActor.assumeIsolated {
                    guard let self, let listener, self.listener === listener else { return }
                    self.handleListenerState(newState)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated {
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            failSession("ルームを作成できませんでした: \(error.localizedDescription)")
        }
    }

    func startBrowsing() {
        disconnect()
        role = .guest
        state = .browsing
        errorMessage = nil
        resetLocalParticipant(slot: 0)
        resetCourseSyncState()

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: networkParameters()
        )
        browser.stateUpdateHandler = { [weak self, weak browser] newState in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.handleBrowserState(newState)
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, let browser, self.browser === browser else { return }
                self.updateRooms(from: results)
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func join(_ room: Room) {
        guard state == .browsing else { return }
        browser?.cancel()
        browser = nil
        rooms = []
        state = .connecting
        let context = PeerConnectionContext(
            connection: NWConnection(to: room.endpoint, using: networkParameters())
        )
        hostConnectionID = context.id
        attach(context)
    }

    func disconnect() {
        let wasConnected = lastConnectionNotification
        lastConnectionNotification = false
        scheduledRaceStartTask?.cancel()
        scheduledRaceStartTask = nil
        clockSyncTask?.cancel()
        clockSyncTask = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        for context in connections.values {
            context.handshakeTimeoutTask?.cancel()
            context.handshakeTimeoutTask = nil
            context.connection.stateUpdateHandler = nil
            context.connection.cancel()
        }
        listener = nil
        browser = nil
        connections.removeAll()
        hostConnectionID = nil
        rooms = []
        role = nil
        state = .idle
        raceInProgress = false
        resetLocalParticipant(slot: 0)
        resetRoundState()
        courseSyncState = .unavailable
        resetCarModelSyncState()
        if wasConnected {
            onCourseSyncInvalidated?()
            onConnectionChanged?(false)
        }
        notifyParticipantsChanged()
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Lobby

    func setReady(_ ready: Bool) {
        guard state == .connected, !raceInProgress else { return }
        guard !ready || canSetReady else { return }
        if role == .host {
            setParticipantReady(localPlayerID, ready: ready)
            broadcastRoster()
        } else {
            setParticipantReady(localPlayerID, ready: ready)
            notifyParticipantsChanged()
            _ = sendToHost(.ready(playerID: localPlayerID, isReady: ready))
        }
    }

    /// Persists and shares a car selection. Any change cancels every READY.
    func setLocalCarChoice(_ choice: RaceCarChoice) {
        guard choice != localCarChoice, !raceInProgress,
              choice != .imported || Self.importedCarSharingEnabled else { return }
        let importedData: Data?
        if choice == .imported {
            do {
                importedData = try loadLocalImportedCarData()
            } catch {
                localCarModelErrorMessage = error.localizedDescription
                return
            }
        } else {
            importedData = nil
        }

        localCarChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.carChoiceDefaultsKey)
        localCarModelErrorMessage = nil
        localCarModelTransferID = nil
        localImportedCarAcknowledged = choice != .imported || state != .connected
        updateParticipant(localPlayerID) {
            $0.carChoice = choice
            $0.isReady = false
        }
        onLocalCarChoiceChanged?(choice)

        switch role {
        case .host:
            invalidateAllReady()
            clearStoredModel(for: localPlayerID)
            if let importedData { installHostLocalModel(importedData) }
            broadcastRoster()
            if importedData != nil { sendStoredModelToAll(for: localPlayerID) }
        case .guest where state == .connected:
            notifyParticipantsChanged()
            _ = sendToHost(.carSelection(playerID: localPlayerID, choice: choice))
            _ = sendToHost(.ready(playerID: localPlayerID, isReady: false))
            if let importedData { sendGuestLocalModel(importedData) }
        default:
            notifyParticipantsChanged()
        }
    }

    /// Re-sends a replaced or flipped imported model while it is selected.
    func refreshLocalImportedCar() {
        localImportedCarAvailable = EntityFactory.hasImportedPlayerCar
        guard Self.importedCarSharingEnabled else {
            if localCarChoice == .imported { setLocalCarChoice(.green) }
            return
        }
        guard localImportedCarAvailable else {
            localCarModelErrorMessage = nil
            if localCarChoice == .imported { setLocalCarChoice(.green) }
            return
        }
        guard localCarChoice == .imported, !raceInProgress else { return }

        do {
            let data = try loadLocalImportedCarData()
            localCarModelErrorMessage = nil
            onLocalCarChoiceChanged?(.imported)
            switch role {
            case .host:
                invalidateAllReady()
                installHostLocalModel(data)
                broadcastRoster()
                sendStoredModelToAll(for: localPlayerID)
            case .guest where state == .connected:
                setParticipantReady(localPlayerID, ready: false)
                notifyParticipantsChanged()
                _ = sendToHost(.ready(playerID: localPlayerID, isReady: false))
                sendGuestLocalModel(data)
            default:
                localImportedCarAcknowledged = true
            }
        } catch {
            localImportedCarAcknowledged = false
            localCarModelErrorMessage = error.localizedDescription
        }
    }

    func isCurrentRemoteImportedCarModel(
        playerID: UUID, id: UUID
    ) -> Bool {
        guard state == .connected,
              participant(id: playerID)?.carChoice == .imported else { return false }
        if role == .host {
            return storedCarModels[playerID]?.id == id
        }
        return remoteCarModelTransferIDs[playerID] == id
    }

    /// Called after RealityKit loads a received participant model.
    func confirmRemoteImportedCarModel(playerID: UUID, id: UUID) {
        guard activeRemoteCarModelLoads[playerID] == id,
              isCurrentRemoteImportedCarModel(playerID: playerID, id: id) else { return }
        activeRemoteCarModelLoads.removeValue(forKey: playerID)
        remoteCarModelErrorMessages.removeValue(forKey: playerID)
        if role == .host {
            modelAcknowledgements[playerID, default: []].insert(localPlayerID)
            if let ownerContext = context(for: playerID) {
                _ = send(
                    .carModelReady(playerID: playerID, id: id),
                    to: ownerContext
                )
            }
            sendStoredModelToAll(for: playerID, excluding: [playerID])
        } else {
            remoteImportedCarReadyIDs.insert(playerID)
            _ = sendToHost(.carModelReady(playerID: playerID, id: id))
        }
        startNextRemoteCarModelLoadIfNeeded()
    }

    /// Reports a USDZ that RealityKit could not load on this device.
    func failRemoteImportedCarModel(
        playerID: UUID, id: UUID, message: String
    ) {
        guard activeRemoteCarModelLoads[playerID] == id,
              isCurrentRemoteImportedCarModel(playerID: playerID, id: id) else { return }
        activeRemoteCarModelLoads.removeValue(forKey: playerID)
        let safeMessage = String(message.prefix(160))
        remoteCarModelErrorMessages[playerID] = safeMessage
        if role == .host {
            storedCarModels.removeValue(forKey: playerID)
            modelAcknowledgements.removeValue(forKey: playerID)
            invalidateAllReady()
            broadcastRoster()
            if let ownerContext = context(for: playerID) {
                _ = send(
                    .carModelFailed(
                        playerID: playerID,
                        id: id,
                        message: safeMessage
                    ),
                    to: ownerContext
                )
            }
        } else {
            remoteImportedCarReadyIDs.remove(playerID)
            setParticipantReady(localPlayerID, ready: false)
            notifyParticipantsChanged()
            _ = sendToHost(.ready(playerID: localPlayerID, isReady: false))
            _ = sendToHost(.carModelFailed(
                playerID: playerID,
                id: id,
                message: safeMessage
            ))
        }
        startNextRemoteCarModelLoadIfNeeded()
    }

    // MARK: - Course sharing

    func requestCourseShare() {
        guard canRequestCourseShare else { return }
        invalidateAllReady()
        courseAppliedParticipantIDs.removeAll()
        let syncID = UUID()
        currentCourseSyncID = syncID
        courseSyncState = .preparingMap
        broadcastRoster()
        broadcast(.courseSyncStarted(id: syncID))
        onCourseMapRequested?()
    }

    func sendCourseMap(
        _ data: Data, placement: PeerRacePacket.CoursePlacement
    ) {
        guard state == .connected, role == .host,
              courseSyncState == .preparingMap,
              let syncID = currentCourseSyncID else { return }
        guard data.count <= Self.maximumWorldMapSize else {
            failCourseShare("ARマップが大きすぎます。映す範囲を狭めてやり直してください")
            return
        }
        guard broadcast(.courseMap(
            id: syncID,
            data: data,
            placement: placement
        )) else {
            failCourseShare("コース情報を送信できませんでした")
            return
        }
        courseSyncState = .waitingForGuest
    }

    func confirmCourseMapApplied() {
        guard state == .connected, role == .guest,
              courseSyncState == .relocalizing,
              let syncID = currentCourseSyncID else { return }
        courseSyncState = .waitingForGuest
        _ = sendToHost(.courseMapApplied(id: syncID))
    }

    func failCourseShare(_ message: String) {
        guard state == .connected, currentCourseSyncID != nil else { return }
        switch role {
        case .host:
            guard courseSyncState == .preparingMap
                    || courseSyncState == .waitingForGuest else { return }
        case .guest:
            guard courseSyncState == .waitingForMap
                    || courseSyncState == .relocalizing else { return }
        case nil:
            return
        }
        let safeMessage = String(message.prefix(160))
        setParticipantReady(localPlayerID, ready: false)
        courseSyncState = .failed(safeMessage)
        if role == .host {
            invalidateAllReady()
            broadcastRoster()
            broadcast(.courseMapFailed(
                id: currentCourseSyncID,
                message: safeMessage
            ))
        } else {
            notifyParticipantsChanged()
            _ = sendToHost(.ready(playerID: localPlayerID, isReady: false))
            _ = sendToHost(.courseMapFailed(
                id: currentCourseSyncID,
                message: safeMessage
            ))
        }
        onCourseSyncInvalidated?()
    }

    // MARK: - Race

    func requestStartRace() {
        guard canStartRace, scheduledRaceStartTask == nil else { return }
        let roundID = UUID()
        let hostStartTime = monotonicTime + Self.raceStartLeadTime
        guard broadcast(.startRace(
            roundID: roundID,
            hostStartTime: hostStartTime
        )) else {
            broadcast(.resetRace)
            errorMessage = "レース開始情報を送信できませんでした"
            return
        }
        raceInProgress = true
        resetFinishState()
        currentRoundID = roundID
        scheduledHostStartTime = hostStartTime
        scheduleRaceStart(roundID: roundID, localStartTime: hostStartTime)
    }

    func requestResetRace() {
        guard state == .connected, role == .host else { return }
        performHostReset()
    }

    func sendCarState(
        _ carState: PeerRacePacket.CarState, deltaTime: TimeInterval
    ) {
        guard state == .connected, isCourseSynchronized, raceInProgress else { return }
        snapshotAccumulator += deltaTime
        guard snapshotAccumulator >= Self.snapshotInterval else { return }
        snapshotAccumulator.formTruncatingRemainder(
            dividingBy: Self.snapshotInterval
        )
        let packet = PeerRacePacket.carState(
            playerID: localPlayerID,
            state: carState
        )
        if role == .host {
            broadcast(packet)
        } else {
            _ = sendToHost(packet)
        }
    }

    func reportLocalFinish(raceTime: TimeInterval) {
        guard state == .connected, raceInProgress,
              !finishOrder.contains(localPlayerID),
              finishRecords[localPlayerID] == nil,
              let roundID = currentRoundID else { return }
        let hostFinishTime = estimatedHostTime
        if role == .host {
            recordFinish(
                playerID: localPlayerID,
                roundID: roundID,
                raceTime: raceTime,
                hostFinishTime: hostFinishTime
            )
        } else {
            let record = PeerFinishRecord(
                raceTime: raceTime,
                hostFinishTime: hostFinishTime
            )
            if sendToHost(.finish(
                playerID: localPlayerID,
                roundID: roundID,
                raceTime: raceTime,
                hostFinishTime: hostFinishTime
            )) {
                finishRecords[localPlayerID] = record
            }
        }
    }

    private var monotonicTime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private var estimatedHostTime: TimeInterval {
        monotonicTime + (role == .guest ? hostClockOffset ?? 0 : 0)
    }

    private func beginClockSynchronization() {
        clockSyncTask?.cancel()
        pendingClockProbes.removeAll()
        bestClockRoundTripTime = nil
        hostClockOffset = nil
        nextClockSequence = 0
        clockSyncTask = Task { [weak self] in
            var initialProbeCount = 0
            while !Task.isCancelled {
                guard let self, self.role == .guest,
                      self.state == .connected else { return }
                self.sendClockSyncProbe()
                initialProbeCount += 1
                do {
                    if initialProbeCount < 4 {
                        try await Task.sleep(for: .milliseconds(150))
                    } else {
                        try await Task.sleep(for: Self.clockSyncRefreshInterval)
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func sendClockSyncProbe() {
        nextClockSequence &+= 1
        let sequence = nextClockSequence
        let sendTime = monotonicTime
        pendingClockProbes[sequence] = sendTime
        if pendingClockProbes.count > 8,
           let oldest = pendingClockProbes.keys.min() {
            pendingClockProbes.removeValue(forKey: oldest)
        }
        _ = sendToHost(.clockSyncRequest(
            sequence: sequence,
            clientSendTime: sendTime
        ))
    }

    private func receiveClockSyncResponse(_ packet: PeerRacePacket) {
        guard role == .guest,
              let sequence = packet.clockSequence,
              let echoedSendTime = packet.clientSendTime,
              let hostTime = packet.hostTime,
              let sendTime = pendingClockProbes.removeValue(forKey: sequence),
              echoedSendTime.isFinite, hostTime.isFinite,
              abs(echoedSendTime - sendTime) < 0.001 else { return }
        let receiveTime = monotonicTime
        let roundTripTime = receiveTime - sendTime
        guard roundTripTime >= 0,
              roundTripTime <= Self.maximumClockSyncRoundTripTime else { return }
        let offset = hostTime - ((sendTime + receiveTime) / 2)
        guard offset.isFinite else { return }
        if bestClockRoundTripTime.map({ roundTripTime < $0 }) ?? true {
            bestClockRoundTripTime = roundTripTime
            hostClockOffset = offset
        }
    }

    private func scheduleRaceStart(roundID: UUID, localStartTime: TimeInterval) {
        scheduledRaceStartTask?.cancel()
        let delay = max(0, localStartTime - monotonicTime)
        scheduledRaceStartTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .nanoseconds(Int64(delay * 1_000_000_000))
                )
            } catch {
                return
            }
            guard let self, self.raceInProgress,
                  self.currentRoundID == roundID else { return }
            self.scheduledRaceStartTask = nil
            guard self.onStartRace?() == true else {
                if self.role == .host {
                    self.errorMessage = "コース位置を確認できないためレースを開始できませんでした"
                    self.performHostReset()
                } else {
                    self.failSession("コース位置を確認できないためレースを開始できませんでした")
                }
                return
            }
        }
    }

    // MARK: - Connection lifecycle

    private func networkParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func handleListenerState(_ newState: NWListener.State) {
        switch newState {
        case .ready:
            if remoteParticipants.isEmpty { state = .hosting }
        case .failed(let error):
            failSession("ルームを公開できませんでした: \(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func handleBrowserState(_ newState: NWBrowser.State) {
        switch newState {
        case .ready:
            state = .browsing
        case .failed(let error):
            failSession("ルームを検索できませんでした: \(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func updateRooms(from results: Set<NWBrowser.Result>) {
        rooms = results.compactMap { result in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return Room(endpoint: result.endpoint, name: name)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func accept(_ connection: NWConnection) {
        guard role == .host else {
            connection.cancel()
            return
        }

        let pendingConnectionCount = connections.values.lazy.filter {
            $0.playerID == nil
        }.count
        let maximumConnectionCount = Self.maximumPlayers - 1
            + Self.maximumPendingHostConnections
        guard pendingConnectionCount < Self.maximumPendingHostConnections,
              connections.count < maximumConnectionCount else {
            connection.cancel()
            return
        }

        let message: String?
        if raceInProgress {
            message = "レース中のルームには参加できません"
        } else if participants.count >= Self.maximumPlayers {
            message = "このルームは満員です"
        } else {
            message = nil
        }
        attach(PeerConnectionContext(
            connection: connection,
            rejectionMessage: message
        ))
    }

    private func attach(_ context: PeerConnectionContext) {
        connections[context.id] = context
        if role == .host {
            scheduleHandshakeTimeout(for: context)
        }
        context.connection.stateUpdateHandler = { [weak self, weak context] newState in
            MainActor.assumeIsolated {
                guard let self, let context,
                      self.connections[context.id] != nil else { return }
                self.handleConnectionState(newState, context: context)
            }
        }
        context.connection.start(queue: .main)
    }

    private func scheduleHandshakeTimeout(for context: PeerConnectionContext) {
        context.handshakeTimeoutTask?.cancel()
        context.handshakeTimeoutTask = Task { [weak self, weak context] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard !Task.isCancelled, let self, let context,
                  self.connections[context.id] != nil,
                  context.playerID == nil else { return }
            self.close(context)
        }
    }

    private func handleConnectionState(
        _ newState: NWConnection.State, context: PeerConnectionContext
    ) {
        switch newState {
        case .ready:
            if let rejectionMessage = context.rejectionMessage {
                _ = send(.joinRejected(rejectionMessage), to: context)
                Task { [weak self, weak context] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard let self, let context else { return }
                    self.close(context)
                }
                return
            }
            receiveNextChunk(from: context)
            if role == .guest {
                state = .connected
                resetRoundState()
                resetCourseSyncState()
                resetCarModelSyncState()
                _ = sendToHost(.hello(
                    playerID: localPlayerID,
                    name: localPlayerName,
                    carChoice: localCarChoice
                ))
                beginClockSynchronization()
                if localCarChoice == .imported { sendGuestLocalModel() }
            }
        case .failed(let error):
            connectionLost(
                context,
                message: "対戦接続が切れました: \(error.localizedDescription)"
            )
        case .cancelled:
            connectionLost(context, message: "対戦接続が終了しました")
        default:
            break
        }
    }

    private func connectionLost(
        _ context: PeerConnectionContext, message: String
    ) {
        guard connections[context.id] != nil else { return }
        let departedID = context.playerID
        close(context)
        if role == .guest {
            failSession(message)
            return
        }
        guard role == .host, let departedID else { return }
        let departedName = participant(id: departedID)?.name ?? "参加者"
        participants.removeAll { $0.id == departedID }
        clearStoredModel(for: departedID)
        remoteImportedCarReadyIDs.remove(departedID)
        remoteCarModelTransferIDs.removeValue(forKey: departedID)
        remoteCarModelErrorMessages.removeValue(forKey: departedID)
        let departedErrorPrefix = "\(departedName):"
        remoteCarModelErrorMessages = remoteCarModelErrorMessages.filter {
            !$0.value.hasPrefix(departedErrorPrefix)
        }
        if localCarModelErrorMessage?.hasPrefix(departedErrorPrefix) == true {
            localCarModelErrorMessage = nil
        }
        acknowledgeModelsSynchronizedAfterDeparture()
        if remoteParticipants.isEmpty { state = .hosting }
        let shouldAbortRace = raceInProgress && remoteParticipants.isEmpty
        if shouldAbortRace {
            raceInProgress = false
            resetRoundState()
            courseAppliedParticipantIDs.removeAll()
            currentCourseSyncID = nil
            courseSyncState = .hostPlacement
        } else if !raceInProgress {
            invalidateCourseForRosterChange()
        }
        broadcastRoster()
        if shouldAbortRace {
            onCourseSyncInvalidated?()
            onResetRace?()
        } else if raceInProgress {
            completeRaceIfNeeded()
        }
        errorMessage = "\(departedName)が退出しました"
    }

    private func close(_ context: PeerConnectionContext) {
        guard connections.removeValue(forKey: context.id) != nil else { return }
        context.handshakeTimeoutTask?.cancel()
        context.handshakeTimeoutTask = nil
        context.connection.stateUpdateHandler = nil
        context.connection.cancel()
        if hostConnectionID == context.id { hostConnectionID = nil }
    }

    private func failSession(_ message: String) {
        disconnect()
        errorMessage = message
    }

    // MARK: - Framing

    @discardableResult
    private func send(
        _ packet: PeerRacePacket, to context: PeerConnectionContext
    ) -> Bool {
        guard let frame = encodedFrame(for: packet) else { return false }
        return sendFrame(frame, to: context)
    }

    private func encodedFrame(for packet: PeerRacePacket) -> Data? {
        do {
            let payload = try encoder.encode(packet)
            guard payload.count <= Self.maximumPacketSize else { return nil }
            var length = UInt32(payload.count).bigEndian
            var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
            frame.append(payload)
            return frame
        } catch {
            if role == .guest {
                failSession("対戦データを作成できませんでした: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private func sendFrame(
        _ frame: Data, to context: PeerConnectionContext
    ) -> Bool {
        guard connections[context.id] != nil else { return false }
        context.connection.send(
            content: frame,
            completion: .contentProcessed { [weak self, weak context] error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    guard let self, let context,
                          self.connections[context.id] != nil else { return }
                    self.connectionLost(
                        context,
                        message: "データを送信できませんでした: \(error.localizedDescription)"
                    )
                }
            }
        )
        return true
    }

    @discardableResult
    private func sendToHost(_ packet: PeerRacePacket) -> Bool {
        guard let hostConnectionID,
              let context = connections[hostConnectionID] else { return false }
        return send(packet, to: context)
    }

    @discardableResult
    private func broadcast(
        _ packet: PeerRacePacket, excluding excludedIDs: Set<UUID> = []
    ) -> Bool {
        let targets = connections.values.filter {
            guard let playerID = $0.playerID else { return false }
            return !excludedIDs.contains(playerID)
        }
        guard !targets.isEmpty else { return false }
        guard let frame = encodedFrame(for: packet) else { return false }
        return targets.reduce(true) { result, context in
            sendFrame(frame, to: context) && result
        }
    }

    private func receiveNextChunk(from context: PeerConnectionContext) {
        let maximumLength = isAwaitingGuestHello(context)
            ? Self.maximumHelloPacketSize + MemoryLayout<UInt32>.size
            : 64 * 1024
        context.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: maximumLength
        ) { [weak self, weak context] content, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let context,
                      self.connections[context.id] != nil else { return }
                if let content { context.receiveBuffer.append(content) }
                guard self.consumeFrames(from: context) else { return }
                if let error {
                    self.connectionLost(
                        context,
                        message: "対戦データを受信できませんでした: \(error.localizedDescription)"
                    )
                } else if isComplete {
                    self.connectionLost(context, message: "対戦接続が終了しました")
                } else {
                    self.receiveNextChunk(from: context)
                }
            }
        }
    }

    private func consumeFrames(from context: PeerConnectionContext) -> Bool {
        let headerSize = MemoryLayout<UInt32>.size
        while context.receiveBuffer.count >= headerSize {
            let awaitingHello = isAwaitingGuestHello(context)
            let maximumPacketSize: Int
            if awaitingHello {
                maximumPacketSize = Self.maximumHelloPacketSize
            } else if role == .host {
                maximumPacketSize = Self.maximumGuestToHostPacketSize
            } else {
                maximumPacketSize = Self.maximumPacketSize
            }
            let length = context.receiveBuffer.prefix(headerSize).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0, length <= maximumPacketSize else {
                connectionLost(context, message: "不正な対戦データを受信しました")
                return false
            }
            let frameSize = headerSize + Int(length)
            guard context.receiveBuffer.count >= frameSize else { return true }
            let payload = context.receiveBuffer.subdata(in: headerSize..<frameSize)
            context.receiveBuffer.removeSubrange(0..<frameSize)
            do {
                let packet = try decoder.decode(PeerRacePacket.self, from: payload)
                guard !awaitingHello || packet.kind == .hello else {
                    connectionLost(context, message: "不正な対戦データを受信しました")
                    return false
                }
                if role == .host {
                    handleHostPacket(packet, from: context)
                    // A rejected hello remains unauthenticated until the delayed
                    // rejection response has had time to reach the guest.
                    if awaitingHello, context.playerID == nil { return false }
                } else {
                    handleGuestPacket(packet)
                }
                guard connections[context.id] != nil else { return false }
            } catch {
                connectionLost(
                    context,
                    message: "対戦データを読み取れませんでした: \(error.localizedDescription)"
                )
                return false
            }
        }
        return true
    }

    private func isAwaitingGuestHello(_ context: PeerConnectionContext) -> Bool {
        role == .host && context.playerID == nil
    }

    // MARK: - Host packet handling

    private func handleHostPacket(
        _ packet: PeerRacePacket, from context: PeerConnectionContext
    ) {
        if packet.kind == .hello {
            receiveGuestHello(packet, from: context)
            return
        }
        guard let senderID = context.playerID,
              participant(id: senderID) != nil else { return }

        switch packet.kind {
        case .ready:
            guard !raceInProgress,
                  packet.playerID == senderID,
                  let ready = packet.isReady else { return }
            let accepted = !ready || (
                courseSyncState == .synchronized && carModelsSynchronized
            )
            if accepted { setParticipantReady(senderID, ready: ready) }
            broadcastRoster()
        case .carSelection:
            guard !raceInProgress, packet.playerID == senderID,
                  let choice = packet.carChoice else { return }
            receiveGuestCarChoice(choice, playerID: senderID)
        case .carModel:
            guard !raceInProgress, packet.playerID == senderID else { return }
            receiveCarModel(packet, ownerID: senderID)
        case .clockSyncRequest:
            guard let sequence = packet.clockSequence,
                  let clientSendTime = packet.clientSendTime,
                  clientSendTime.isFinite else { return }
            _ = send(
                .clockSyncResponse(
                    sequence: sequence,
                    clientSendTime: clientSendTime,
                    hostTime: monotonicTime
                ),
                to: context
            )
        case .carModelReady:
            guard let ownerID = packet.playerID,
                  let modelID = packet.carModelID,
                  ownerID != senderID,
                  storedCarModels[ownerID]?.id == modelID else { return }
            modelAcknowledgements[ownerID, default: []].insert(senderID)
        case .carModelFailed:
            guard let ownerID = packet.playerID,
                  let modelID = packet.carModelID,
                  ownerID != senderID,
                  storedCarModels[ownerID]?.id == modelID else { return }
            receiveViewerModelFailure(
                viewerID: senderID,
                ownerID: ownerID,
                modelID: modelID,
                message: packet.message
            )
        case .courseMapApplied:
            guard courseSyncState == .waitingForGuest,
                  packet.courseSyncID == currentCourseSyncID else { return }
            courseAppliedParticipantIDs.insert(senderID)
            let guestIDs = Set(remoteParticipants.map(\.id))
            if guestIDs.isSubset(of: courseAppliedParticipantIDs),
               let syncID = currentCourseSyncID {
                courseSyncState = .synchronized
                broadcast(.courseSyncCompleted(id: syncID))
            }
        case .courseMapFailed:
            guard courseSyncState == .waitingForGuest,
                  packet.courseSyncID == currentCourseSyncID else { return }
            let name = participant(id: senderID)?.name ?? "参加者"
            hostCourseFailure(
                "\(name): \(packet.message ?? "コースの位置合わせに失敗しました")"
            )
        case .carState:
            guard raceInProgress, isCourseSynchronized,
                  packet.playerID == senderID,
                  let carState = packet.carState else { return }
            onCarState?(senderID, carState)
            broadcast(
                .carState(playerID: senderID, state: carState),
                excluding: [senderID]
            )
        case .finish:
            guard packet.playerID == senderID,
                  let roundID = packet.roundID,
                  let raceTime = packet.raceTime,
                  let hostFinishTime = packet.hostFinishTime else { return }
            recordFinish(
                playerID: senderID,
                roundID: roundID,
                raceTime: raceTime,
                hostFinishTime: hostFinishTime
            )
        case .resetRace:
            // Whole-race resets are host-authoritative. Older guests may still
            // send this packet, so ignore it instead of interrupting everyone.
            break
        case .hello, .roster, .joinRejected, .courseSyncReset,
             .courseSyncStarted, .courseMap, .courseSyncCompleted,
             .clockSyncResponse, .startRace, .finishResult, .raceComplete:
            break
        }
    }

    private func receiveGuestHello(
        _ packet: PeerRacePacket, from context: PeerConnectionContext
    ) {
        guard context.playerID == nil else { return }
        guard packet.protocolVersion == PeerRacePacket.currentVersion else {
            reject(context, message: "アプリのバージョンが対戦相手と一致しません")
            return
        }
        guard !raceInProgress,
              participants.count < Self.maximumPlayers,
              let playerID = packet.playerID,
              playerID != localPlayerID,
              participant(id: playerID) == nil,
              let carChoice = packet.carChoice else {
            reject(context, message: "このルームには参加できません")
            return
        }
        guard Self.importedCarSharingEnabled || carChoice != .imported else {
            reject(context, message: "ネットワーク対戦ではカスタム車を共有できません")
            return
        }
        let usedSlots = Set(participants.map(\.slot))
        guard let slot = (1..<Self.maximumPlayers).first(
            where: { !usedSlots.contains($0) }
        ) else {
            reject(context, message: "このルームは満員です")
            return
        }

        context.playerID = playerID
        context.handshakeTimeoutTask?.cancel()
        context.handshakeTimeoutTask = nil
        errorMessage = nil
        let rawName = packet.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((rawName?.isEmpty == false ? rawName! : "参加者").prefix(40))
        participants.append(PeerRaceParticipant(
            id: playerID,
            name: name,
            slot: slot,
            isReady: false,
            carChoice: carChoice
        ))
        if carChoice == .imported {
            clearStoredModel(for: playerID)
        }
        state = .connected
        invalidateAllReady()
        let courseNeedsReset = courseSyncState != .hostPlacement
        if courseNeedsReset {
            courseAppliedParticipantIDs.removeAll()
            currentCourseSyncID = nil
            courseSyncState = .hostPlacement
        }
        broadcastRoster()
        if courseNeedsReset {
            broadcast(.courseSyncReset)
            onCourseSyncInvalidated?()
        }
        sendStoredModels(to: context)
    }

    private func reject(
        _ context: PeerConnectionContext, message: String
    ) {
        context.handshakeTimeoutTask?.cancel()
        context.handshakeTimeoutTask = nil
        _ = send(.joinRejected(message), to: context)
        Task { [weak self, weak context] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, let context else { return }
            self.close(context)
        }
    }

    private func receiveGuestCarChoice(
        _ choice: RaceCarChoice, playerID: UUID
    ) {
        updateParticipant(playerID) {
            $0.carChoice = choice
            $0.isReady = false
        }
        invalidateAllReady()
        clearStoredModel(for: playerID)
        remoteCarModelErrorMessages.removeValue(forKey: playerID)
        broadcastRoster()
    }

    // MARK: - Guest packet handling

    private func handleGuestPacket(_ packet: PeerRacePacket) {
        switch packet.kind {
        case .roster:
            guard let roster = packet.participants else { return }
            guard Self.importedCarSharingEnabled
                    || roster.allSatisfy({ $0.carChoice != .imported }) else {
                failSession("ネットワーク対戦で未対応のカスタム車を受信しました")
                return
            }
            receiveRoster(roster)
        case .joinRejected:
            failSession(packet.message ?? "ルームに参加できませんでした")
        case .courseSyncReset:
            setParticipantReady(localPlayerID, ready: false)
            currentCourseSyncID = nil
            courseSyncState = .waitingForHost
            notifyParticipantsChanged()
            onCourseSyncInvalidated?()
        case .courseSyncStarted:
            guard courseSyncState == .waitingForHost
                    || isCourseSynchronized
                    || isCourseFailure,
                  let syncID = packet.courseSyncID else { return }
            setParticipantReady(localPlayerID, ready: false)
            currentCourseSyncID = syncID
            courseSyncState = .waitingForMap
            notifyParticipantsChanged()
            _ = sendToHost(.ready(playerID: localPlayerID, isReady: false))
            onCourseSyncInvalidated?()
        case .courseMap:
            guard courseSyncState == .waitingForMap,
                  packet.courseSyncID == currentCourseSyncID else { return }
            guard let data = packet.worldMapData,
                  data.count <= Self.maximumWorldMapSize,
                  let placement = packet.coursePlacement else {
                failCourseShare("コース情報を読み取れませんでした")
                return
            }
            courseSyncState = .relocalizing
            guard let onCourseMapReceived else {
                failCourseShare("ARコースを読み込めませんでした")
                return
            }
            onCourseMapReceived(data, placement)
        case .courseMapFailed:
            guard packet.courseSyncID == currentCourseSyncID else { return }
            let message = String(
                (packet.message ?? "コースの位置合わせに失敗しました").prefix(160)
            )
            setParticipantReady(localPlayerID, ready: false)
            courseSyncState = .failed(message)
            notifyParticipantsChanged()
            onCourseSyncInvalidated?()
        case .courseSyncCompleted:
            guard courseSyncState == .waitingForGuest,
                  packet.courseSyncID == currentCourseSyncID else { return }
            courseSyncState = .synchronized
        case .carModel:
            guard let ownerID = packet.playerID,
                  ownerID != localPlayerID else { return }
            receiveCarModel(packet, ownerID: ownerID)
        case .carModelReady:
            guard packet.playerID == localPlayerID,
                  let id = packet.carModelID,
                  id == localCarModelTransferID else { return }
            localImportedCarAcknowledged = true
            localCarModelErrorMessage = nil
        case .carModelFailed:
            guard packet.playerID == localPlayerID,
                  let id = packet.carModelID,
                  id == localCarModelTransferID else { return }
            localImportedCarAcknowledged = false
            setParticipantReady(localPlayerID, ready: false)
            localCarModelErrorMessage = String(
                (packet.message ?? "別の端末でカスタム車を読み込めませんでした").prefix(160)
            )
            notifyParticipantsChanged()
        case .clockSyncResponse:
            receiveClockSyncResponse(packet)
        case .startRace:
            guard !raceInProgress,
                  isCourseSynchronized, carModelsSynchronized,
                  participants.count >= 2 else { return }
            guard let roundID = packet.roundID,
                  let hostStartTime = packet.hostStartTime,
                  let hostClockOffset else {
                failSession("レース開始時刻を同期できませんでした")
                return
            }
            let localStartTime = hostStartTime - hostClockOffset
            let leadTime = localStartTime - monotonicTime
            guard leadTime >= Self.minimumScheduledStartLeadTime,
                  leadTime <= Self.maximumScheduledStartLeadTime else {
                failSession("レース開始時刻を同期できませんでした")
                return
            }
            raceInProgress = true
            resetFinishState()
            currentRoundID = roundID
            scheduledHostStartTime = hostStartTime
            scheduleRaceStart(roundID: roundID, localStartTime: localStartTime)
        case .carState:
            guard raceInProgress, isCourseSynchronized,
                  let playerID = packet.playerID,
                  playerID != localPlayerID,
                  participant(id: playerID) != nil,
                  let carState = packet.carState else { return }
            onCarState?(playerID, carState)
        case .finishResult:
            guard packet.playerID == localPlayerID,
                  packet.roundID == currentRoundID,
                  let position = packet.position,
                  let raceTime = packet.raceTime else { return }
            if !finishOrder.contains(localPlayerID) { finishOrder.append(localPlayerID) }
            onFinishResult?(position, raceTime)
        case .raceComplete:
            raceComplete = true
        case .resetRace:
            raceInProgress = false
            resetRoundState()
            onResetRace?()
        case .hello, .ready, .carSelection, .courseMapApplied,
             .clockSyncRequest, .finish:
            break
        }
    }

    private var isCourseFailure: Bool {
        if case .failed = courseSyncState { return true }
        return false
    }

    private func receiveRoster(_ roster: [PeerRaceParticipant]) {
        guard roster.count >= 2, roster.count <= Self.maximumPlayers,
              Set(roster.map(\.id)).count == roster.count,
              Set(roster.map(\.slot)).count == roster.count,
              roster.allSatisfy({ (0..<Self.maximumPlayers).contains($0.slot) }),
              let local = roster.first(where: { $0.id == localPlayerID }) else {
            failSession("参加者情報を読み取れませんでした")
            return
        }

        let oldByID = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
        let newRemoteIDs = Set(roster.map(\.id)).subtracting([localPlayerID])
        remoteImportedCarReadyIDs.formIntersection(newRemoteIDs)
        remoteCarModelTransferIDs = remoteCarModelTransferIDs.filter {
            newRemoteIDs.contains($0.key)
        }
        activeRemoteCarModelLoads = activeRemoteCarModelLoads.filter {
            newRemoteIDs.contains($0.key)
        }
        pendingRemoteCarModelLoads.removeAll {
            !newRemoteIDs.contains($0.ownerID)
        }
        remoteCarModelErrorMessages = remoteCarModelErrorMessages.filter {
            newRemoteIDs.contains($0.key)
        }
        for participant in roster where participant.id != localPlayerID {
            let oldChoice = oldByID[participant.id]?.carChoice
            if participant.carChoice != .imported {
                remoteImportedCarReadyIDs.remove(participant.id)
                remoteCarModelTransferIDs.removeValue(forKey: participant.id)
                remoteCarModelErrorMessages.removeValue(forKey: participant.id)
                activeRemoteCarModelLoads.removeValue(forKey: participant.id)
                pendingRemoteCarModelLoads.removeAll {
                    $0.ownerID == participant.id
                }
            } else if oldChoice != .imported {
                remoteImportedCarReadyIDs.remove(participant.id)
                remoteCarModelTransferIDs.removeValue(forKey: participant.id)
                activeRemoteCarModelLoads.removeValue(forKey: participant.id)
                pendingRemoteCarModelLoads.removeAll {
                    $0.ownerID == participant.id
                }
            }
        }
        participants = roster.sorted { $0.slot < $1.slot }
        if local.carChoice != localCarChoice {
            localCarChoice = local.carChoice
            onLocalCarChoiceChanged?(local.carChoice)
        }
        notifyParticipantsChanged()
        startNextRemoteCarModelLoadIfNeeded()
    }

    // MARK: - Imported models

    private func receiveCarModel(
        _ packet: PeerRacePacket, ownerID: UUID
    ) {
        guard Self.importedCarSharingEnabled else {
            if role == .guest {
                failSession("ネットワーク対戦で未対応のカスタム車を受信しました")
            } else {
                registerCarModelViolation(ownerID: ownerID)
            }
            return
        }
        guard participant(id: ownerID)?.carChoice == .imported,
              let id = packet.carModelID,
              let data = packet.carModelData,
              let flipped = packet.carModelFlipped else { return }
        guard data.count <= Self.maximumCarModelSize else {
            rejectIncomingCarModel(
                ownerID: ownerID,
                id: id,
                message: "カスタム車が12MBを超えています"
            )
            return
        }
        if let admissionError = remoteCarModelAdmissionError(
            ownerID: ownerID,
            byteCount: data.count
        ) {
            rejectIncomingCarModel(
                ownerID: ownerID,
                id: id,
                message: admissionError
            )
            return
        }
        guard isValidUSDZ(data) else {
            rejectRemoteCarModel(
                ownerID: ownerID,
                id: id,
                message: "カスタム車を読み取れません",
                clearCurrentModel: false
            )
            registerCarModelViolation(ownerID: ownerID)
            return
        }

        remoteCarModelErrorMessages.removeValue(forKey: ownerID)
        if role == .host {
            storedCarModels[ownerID] = StoredPeerCarModel(
                id: id, data: data, flipped: flipped
            )
            modelAcknowledgements[ownerID] = [ownerID]
            invalidateAllReady()
            broadcastRoster()
        } else {
            remoteCarModelTransferIDs[ownerID] = id
            remoteImportedCarReadyIDs.remove(ownerID)
            setParticipantReady(localPlayerID, ready: false)
            notifyParticipantsChanged()
            _ = sendToHost(.ready(playerID: localPlayerID, isReady: false))
        }
        guard onRemoteImportedCarModel != nil else {
            rejectRemoteCarModel(
                ownerID: ownerID,
                id: id,
                message: "カスタム車を読み込めません",
                clearCurrentModel: true
            )
            return
        }
        pendingRemoteCarModelLoads.append(PendingRemoteCarModelLoad(
            ownerID: ownerID,
            id: id,
            data: data,
            flipped: flipped
        ))
        startNextRemoteCarModelLoadIfNeeded()
    }

    private func startNextRemoteCarModelLoadIfNeeded() {
        guard activeRemoteCarModelLoads.count
                < Self.maximumConcurrentRemoteCarModelLoads,
              !pendingRemoteCarModelLoads.isEmpty,
              let onRemoteImportedCarModel else { return }
        let next = pendingRemoteCarModelLoads.removeFirst()
        guard isCurrentRemoteImportedCarModel(
            playerID: next.ownerID,
            id: next.id
        ) else {
            startNextRemoteCarModelLoadIfNeeded()
            return
        }
        activeRemoteCarModelLoads[next.ownerID] = next.id
        onRemoteImportedCarModel(
            next.ownerID,
            next.data,
            next.flipped,
            next.id
        )
    }

    private func removeRemoteCarModelLoads(for ownerID: UUID) {
        pendingRemoteCarModelLoads.removeAll { $0.ownerID == ownerID }
        activeRemoteCarModelLoads.removeValue(forKey: ownerID)
        startNextRemoteCarModelLoadIfNeeded()
    }

    private func remoteCarModelAdmissionError(
        ownerID: UUID, byteCount: Int
    ) -> String? {
        if activeRemoteCarModelLoads[ownerID] != nil
            || pendingRemoteCarModelLoads.contains(where: { $0.ownerID == ownerID }) {
            return "前のカスタム車を読み込み中です"
        }
        var budget = remoteCarModelBudgets[ownerID] ?? RemoteCarModelBudget()
        let now = monotonicTime
        if let lastTransferTime = budget.lastTransferTime,
           now - lastTransferTime < Self.minimumRemoteCarModelTransferInterval {
            return "カスタム車の送信間隔が短すぎます"
        }
        guard budget.transferCount < Self.maximumRemoteCarModelTransfersPerParticipant,
              budget.bytes <= Self.maximumRemoteCarModelBytesPerParticipant - byteCount,
              remoteCarModelSessionBytes <= Self.maximumRemoteCarModelBytesPerSession - byteCount
        else {
            return "この対戦で共有できるカスタム車の上限を超えました"
        }
        budget.transferCount += 1
        budget.bytes += byteCount
        budget.lastTransferTime = now
        remoteCarModelBudgets[ownerID] = budget
        remoteCarModelSessionBytes += byteCount
        return nil
    }

    private func rejectIncomingCarModel(
        ownerID: UUID, id: UUID, message: String
    ) {
        rejectRemoteCarModel(
            ownerID: ownerID,
            id: id,
            message: message,
            clearCurrentModel: false
        )
        registerCarModelViolation(ownerID: ownerID)
    }

    private func registerCarModelViolation(ownerID: UUID) {
        if role == .host, let ownerContext = context(for: ownerID) {
            ownerContext.carModelViolationCount += 1
            if ownerContext.carModelViolationCount >= Self.maximumCarModelViolations {
                connectionLost(
                    ownerContext,
                    message: "カスタム車の送信上限を超えたため接続を終了しました"
                )
            }
        } else if role == .guest {
            remoteCarModelViolationCount += 1
            if remoteCarModelViolationCount >= Self.maximumCarModelViolations {
                failSession("カスタム車データが繰り返し拒否されたため接続を終了しました")
            }
        }
    }

    private func rejectRemoteCarModel(
        ownerID: UUID,
        id: UUID,
        message: String,
        clearCurrentModel: Bool
    ) {
        let safeMessage = String(message.prefix(160))
        remoteCarModelErrorMessages[ownerID] = safeMessage
        if activeRemoteCarModelLoads[ownerID] == id {
            activeRemoteCarModelLoads.removeValue(forKey: ownerID)
            startNextRemoteCarModelLoadIfNeeded()
        }
        if role == .host {
            if clearCurrentModel { clearStoredModel(for: ownerID) }
            invalidateAllReady()
            broadcastRoster()
            if let ownerContext = context(for: ownerID) {
                _ = send(
                    .carModelFailed(
                        playerID: ownerID,
                        id: id,
                        message: safeMessage
                    ),
                    to: ownerContext
                )
            }
        } else {
            remoteImportedCarReadyIDs.remove(ownerID)
            setParticipantReady(localPlayerID, ready: false)
            notifyParticipantsChanged()
            _ = sendToHost(.ready(playerID: localPlayerID, isReady: false))
            _ = sendToHost(.carModelFailed(
                playerID: ownerID,
                id: id,
                message: safeMessage
            ))
        }
    }

    private func receiveViewerModelFailure(
        viewerID: UUID,
        ownerID: UUID,
        modelID: UUID,
        message: String?
    ) {
        modelAcknowledgements[ownerID]?.remove(viewerID)
        setParticipantReady(viewerID, ready: false)
        let viewerName = participant(id: viewerID)?.name ?? "別の端末"
        let safeMessage = String(
            "\(viewerName): \(message ?? "カスタム車を読み込めませんでした")".prefix(160)
        )
        remoteCarModelErrorMessages[ownerID] = safeMessage
        if ownerID == localPlayerID {
            localCarModelErrorMessage = safeMessage
        } else if let ownerContext = context(for: ownerID) {
            _ = send(
                .carModelFailed(
                    playerID: ownerID,
                    id: modelID,
                    message: safeMessage
                ),
                to: ownerContext
            )
        }
        broadcastRoster()
    }

    private func installHostLocalModel(_ data: Data) {
        let id = UUID()
        let model = StoredPeerCarModel(
            id: id,
            data: data,
            flipped: EntityFactory.customCarFlipped
        )
        storedCarModels[localPlayerID] = model
        modelAcknowledgements[localPlayerID] = [localPlayerID]
        localCarModelTransferID = id
        localImportedCarAcknowledged = true
        localCarModelErrorMessage = nil
    }

    private func prepareHostLocalModelIfNeeded() {
        guard role == .host, localCarChoice == .imported else { return }
        do {
            installHostLocalModel(try loadLocalImportedCarData())
        } catch {
            localImportedCarAcknowledged = false
            localCarModelErrorMessage = error.localizedDescription
        }
    }

    private func sendGuestLocalModel(_ suppliedData: Data? = nil) {
        guard role == .guest, state == .connected,
              localCarChoice == .imported else { return }
        do {
            let data = try suppliedData ?? loadLocalImportedCarData()
            let id = UUID()
            localCarModelTransferID = id
            localImportedCarAcknowledged = false
            localCarModelErrorMessage = nil
            guard sendToHost(.carModel(
                playerID: localPlayerID,
                id: id,
                data: data,
                flipped: EntityFactory.customCarFlipped
            )) else {
                localCarModelTransferID = nil
                localCarModelErrorMessage = "カスタム車をホストへ送信できませんでした"
                return
            }
        } catch {
            localCarModelTransferID = nil
            localImportedCarAcknowledged = false
            localCarModelErrorMessage = error.localizedDescription
        }
    }

    private func sendStoredModelToAll(
        for ownerID: UUID, excluding excludedIDs: Set<UUID> = []
    ) {
        guard let model = storedCarModels[ownerID] else { return }
        broadcast(
            .carModel(
                playerID: ownerID,
                id: model.id,
                data: model.data,
                flipped: model.flipped
            ),
            excluding: excludedIDs.union([ownerID])
        )
    }

    private func sendStoredModels(to context: PeerConnectionContext) {
        guard let viewerID = context.playerID else { return }
        for (ownerID, model) in storedCarModels where ownerID != viewerID {
            _ = send(
                .carModel(
                    playerID: ownerID,
                    id: model.id,
                    data: model.data,
                    flipped: model.flipped
                ),
                to: context
            )
        }
    }

    private func clearStoredModel(for playerID: UUID) {
        storedCarModels.removeValue(forKey: playerID)
        modelAcknowledgements.removeValue(forKey: playerID)
        removeRemoteCarModelLoads(for: playerID)
        if playerID == localPlayerID {
            localCarModelTransferID = nil
        }
    }

    private func loadLocalImportedCarData() throws -> Data {
        guard EntityFactory.hasImportedPlayerCar else {
            throw ImportedCarFileError.missing
        }
        let url = EntityFactory.importedCarURL
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile != false else {
            throw ImportedCarFileError.invalid
        }
        if let fileSize = values.fileSize,
           fileSize <= 0 || fileSize > Self.maximumCarModelSize {
            throw fileSize > Self.maximumCarModelSize
                ? ImportedCarFileError.tooLarge : ImportedCarFileError.invalid
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= Self.maximumCarModelSize else {
            throw ImportedCarFileError.tooLarge
        }
        guard isValidUSDZ(data) else { throw ImportedCarFileError.invalid }
        return data
    }

    private func isValidUSDZ(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0x50, 0x4b, 0x03, 0x04])
    }

    // MARK: - Host state

    private func broadcastRoster() {
        guard role == .host else { return }
        participants.sort { $0.slot < $1.slot }
        notifyParticipantsChanged()
        broadcast(.roster(participants))
    }

    private func invalidateCourseForRosterChange() {
        guard role == .host, !raceInProgress else { return }
        invalidateAllReady()
        courseAppliedParticipantIDs.removeAll()
        currentCourseSyncID = nil
        let needsBroadcast = courseSyncState != .hostPlacement
        courseSyncState = .hostPlacement
        if needsBroadcast {
            broadcast(.courseSyncReset)
            onCourseSyncInvalidated?()
        }
    }

    private func hostCourseFailure(_ message: String) {
        let safeMessage = String(message.prefix(160))
        invalidateAllReady()
        courseSyncState = .failed(safeMessage)
        broadcastRoster()
        broadcast(.courseMapFailed(
            id: currentCourseSyncID,
            message: safeMessage
        ))
        onCourseSyncInvalidated?()
    }

    private func performHostReset() {
        guard role == .host else { return }
        raceInProgress = false
        resetRoundState()
        invalidateAllReady()
        broadcast(.resetRace)
        broadcastRoster()
        onResetRace?()
    }

    private func recordFinish(
        playerID: UUID,
        roundID: UUID,
        raceTime: TimeInterval,
        hostFinishTime: TimeInterval
    ) {
        guard role == .host, raceInProgress,
              roundID == currentRoundID,
              participant(id: playerID) != nil,
              finishRecords[playerID] == nil,
              raceTime.isFinite, raceTime >= 0,
              hostFinishTime.isFinite,
              let hostStartTime = scheduledHostStartTime,
              hostFinishTime >= hostStartTime else { return }
        finishRecords[playerID] = PeerFinishRecord(
            raceTime: raceTime,
            hostFinishTime: hostFinishTime
        )
        completeRaceIfNeeded()
    }

    private func completeRaceIfNeeded() {
        guard role == .host, raceInProgress, !raceComplete else { return }
        let currentIDs = Set(participants.map(\.id))
        guard currentIDs.isSubset(of: Set(finishRecords.keys)),
              let roundID = currentRoundID else { return }
        finishOrder = currentIDs.sorted { lhs, rhs in
            guard let lhsRecord = finishRecords[lhs],
                  let rhsRecord = finishRecords[rhs] else {
                return lhs.uuidString < rhs.uuidString
            }
            // RaceGame reports the finish-line crossing time interpolated
            // within its fixed simulation step. Using callback wall time here
            // would reintroduce render-frame and device-hitch bias.
            if lhsRecord.raceTime != rhsRecord.raceTime {
                return lhsRecord.raceTime < rhsRecord.raceTime
            }
            return lhs.uuidString < rhs.uuidString
        }
        raceComplete = true
        for (offset, playerID) in finishOrder.enumerated() {
            guard let record = finishRecords[playerID] else { continue }
            let position = offset + 1
            if playerID == localPlayerID {
                onFinishResult?(position, record.raceTime)
            } else if let context = context(for: playerID) {
                _ = send(
                    .finishResult(
                        playerID: playerID,
                        roundID: roundID,
                        position: position,
                        raceTime: record.raceTime
                    ),
                    to: context
                )
            }
        }
        broadcast(.raceComplete)
    }

    private func acknowledgeModelsSynchronizedAfterDeparture() {
        let requiredIDs = Set(participants.map(\.id))
        for participant in participants where participant.carChoice == .imported {
            guard let model = storedCarModels[participant.id],
                  requiredIDs.isSubset(
                    of: modelAcknowledgements[participant.id] ?? []
                  ) else { continue }
            remoteCarModelErrorMessages.removeValue(forKey: participant.id)
            guard participant.id != localPlayerID,
                  let ownerContext = context(for: participant.id) else { continue }
            _ = send(
                .carModelReady(playerID: participant.id, id: model.id),
                to: ownerContext
            )
        }
    }

    // MARK: - State helpers

    private func participant(id: UUID) -> PeerRaceParticipant? {
        participants.first { $0.id == id }
    }

    private func context(for playerID: UUID) -> PeerConnectionContext? {
        connections.values.first { $0.playerID == playerID }
    }

    private func updateParticipant(
        _ id: UUID, change: (inout PeerRaceParticipant) -> Void
    ) {
        guard let index = participants.firstIndex(where: { $0.id == id }) else { return }
        change(&participants[index])
    }

    private func setParticipantReady(_ id: UUID, ready: Bool) {
        updateParticipant(id) { $0.isReady = ready }
    }

    private func invalidateAllReady() {
        for index in participants.indices { participants[index].isReady = false }
    }

    private func resetLocalParticipant(slot: Int) {
        participants = [PeerRaceParticipant(
            id: localPlayerID,
            name: localPlayerName,
            slot: slot,
            isReady: false,
            carChoice: localCarChoice
        )]
        notifyParticipantsChanged()
    }

    private func notifyParticipantsChanged() {
        participants.sort { $0.slot < $1.slot }
        onParticipantsChanged?(participants, localPlayerID)
        let isConnected = state == .connected && !remoteParticipants.isEmpty
        if isConnected != lastConnectionNotification {
            lastConnectionNotification = isConnected
            onConnectionChanged?(isConnected)
        }
    }

    private func resetFinishState() {
        finishOrder.removeAll()
        finishRecords.removeAll()
        raceComplete = false
        snapshotAccumulator = 0
    }

    private func resetRoundState() {
        scheduledRaceStartTask?.cancel()
        scheduledRaceStartTask = nil
        currentRoundID = nil
        scheduledHostStartTime = nil
        for index in participants.indices { participants[index].isReady = false }
        resetFinishState()
    }

    private func resetCourseSyncState() {
        courseAppliedParticipantIDs.removeAll()
        currentCourseSyncID = nil
        switch role {
        case .host:
            courseSyncState = .hostPlacement
        case .guest:
            courseSyncState = .waitingForHost
        case nil:
            courseSyncState = .unavailable
        }
    }

    private func resetCarModelSyncState() {
        storedCarModels.removeAll()
        modelAcknowledgements.removeAll()
        remoteImportedCarReadyIDs.removeAll()
        remoteCarModelTransferIDs.removeAll()
        remoteCarModelErrorMessages.removeAll()
        localCarModelTransferID = nil
        localImportedCarAcknowledged = localCarChoice != .imported
        localCarModelErrorMessage = nil
        activeRemoteCarModelLoads.removeAll()
        pendingRemoteCarModelLoads.removeAll()
        remoteCarModelBudgets.removeAll()
        remoteCarModelSessionBytes = 0
        remoteCarModelViolationCount = 0
    }
}
