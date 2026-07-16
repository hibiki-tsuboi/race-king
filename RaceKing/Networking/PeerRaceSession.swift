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
    /// A hello only contains the guest ID, display name, version, and car choice.
    private static let maximumHelloPacketSize = 4 * 1024
    /// Limits sockets that have not yet supplied a valid hello packet.
    private static let maximumPendingHostConnections = 2
    private static let handshakeTimeout: Duration = .seconds(5)
    private static let maximumWorldMapSize = 40 * 1024 * 1024
    private static let maximumCarModelSize = 12 * 1024 * 1024
    private static let snapshotInterval: TimeInterval = 1.0 / 20.0
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
            $0 != .imported || localImportedCarAvailable
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
        state == .connected && role == .host
            && courseSyncState == .synchronized
            && participants.count >= 2
            && carModelsSynchronized
            && allParticipantsReady
    }

    var isCourseSynchronized: Bool { courseSyncState == .synchronized }

    var canSetReady: Bool {
        state == .connected && participants.count >= 2
            && isCourseSynchronized && carModelsSynchronized
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
    @ObservationIgnored private var raceInProgress = false
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
            && !importedCarAvailable ? .green : saved
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
        guard choice != localCarChoice, !raceInProgress else { return }
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
        guard isCurrentRemoteImportedCarModel(playerID: playerID, id: id) else { return }
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
    }

    /// Reports a USDZ that RealityKit could not load on this device.
    func failRemoteImportedCarModel(
        playerID: UUID, id: UUID, message: String
    ) {
        guard isCurrentRemoteImportedCarModel(playerID: playerID, id: id) else { return }
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
        guard canStartRace else { return }
        guard onStartRace?() == true else { return }
        raceInProgress = true
        resetFinishState()
        broadcast(.startRace)
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
              !finishOrder.contains(localPlayerID) else { return }
        if role == .host {
            recordFinish(playerID: localPlayerID, raceTime: raceTime)
        } else {
            _ = sendToHost(.finish(
                playerID: localPlayerID,
                raceTime: raceTime
            ))
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
            let maximumPacketSize = awaitingHello
                ? Self.maximumHelloPacketSize
                : Self.maximumPacketSize
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
                  let raceTime = packet.raceTime else { return }
            recordFinish(playerID: senderID, raceTime: raceTime)
        case .resetRace:
            // Whole-race resets are host-authoritative. Older guests may still
            // send this packet, so ignore it instead of interrupting everyone.
            break
        case .hello, .roster, .joinRejected, .courseSyncReset,
             .courseSyncStarted, .courseMap, .courseSyncCompleted,
             .startRace, .finishResult, .raceComplete:
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
        case .startRace:
            guard isCourseSynchronized, carModelsSynchronized,
                  participants.count >= 2 else { return }
            guard onStartRace?() == true else {
                failSession("コース位置を確認できないためレースを開始できませんでした")
                return
            }
            raceInProgress = true
            resetFinishState()
        case .carState:
            guard raceInProgress, isCourseSynchronized,
                  let playerID = packet.playerID,
                  playerID != localPlayerID,
                  participant(id: playerID) != nil,
                  let carState = packet.carState else { return }
            onCarState?(playerID, carState)
        case .finishResult:
            guard packet.playerID == localPlayerID,
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
        case .hello, .ready, .carSelection, .courseMapApplied, .finish:
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
        remoteCarModelErrorMessages = remoteCarModelErrorMessages.filter {
            newRemoteIDs.contains($0.key)
        }
        for participant in roster where participant.id != localPlayerID {
            let oldChoice = oldByID[participant.id]?.carChoice
            if participant.carChoice != .imported {
                remoteImportedCarReadyIDs.remove(participant.id)
                remoteCarModelTransferIDs.removeValue(forKey: participant.id)
                remoteCarModelErrorMessages.removeValue(forKey: participant.id)
            } else if oldChoice != .imported {
                remoteImportedCarReadyIDs.remove(participant.id)
                remoteCarModelTransferIDs.removeValue(forKey: participant.id)
            }
        }
        participants = roster.sorted { $0.slot < $1.slot }
        if local.carChoice != localCarChoice {
            localCarChoice = local.carChoice
            onLocalCarChoiceChanged?(local.carChoice)
        }
        notifyParticipantsChanged()
    }

    // MARK: - Imported models

    private func receiveCarModel(
        _ packet: PeerRacePacket, ownerID: UUID
    ) {
        guard participant(id: ownerID)?.carChoice == .imported,
              let id = packet.carModelID,
              let data = packet.carModelData,
              let flipped = packet.carModelFlipped else { return }
        guard isValidUSDZ(data), data.count <= Self.maximumCarModelSize else {
            rejectRemoteCarModel(
                ownerID: ownerID,
                id: id,
                message: data.count > Self.maximumCarModelSize
                    ? "カスタム車が12MBを超えています"
                    : "カスタム車を読み取れません"
            )
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
        guard let onRemoteImportedCarModel else {
            rejectRemoteCarModel(
                ownerID: ownerID,
                id: id,
                message: "カスタム車を読み込めません"
            )
            return
        }
        onRemoteImportedCarModel(ownerID, data, flipped, id)
    }

    private func rejectRemoteCarModel(
        ownerID: UUID, id: UUID, message: String
    ) {
        let safeMessage = String(message.prefix(160))
        remoteCarModelErrorMessages[ownerID] = safeMessage
        if role == .host {
            clearStoredModel(for: ownerID)
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

    private func recordFinish(playerID: UUID, raceTime: TimeInterval) {
        guard role == .host, raceInProgress,
              participant(id: playerID) != nil,
              !finishOrder.contains(playerID),
              raceTime.isFinite, raceTime >= 0 else { return }
        finishOrder.append(playerID)
        let position = finishOrder.count
        if playerID == localPlayerID {
            onFinishResult?(position, raceTime)
        } else if let context = context(for: playerID) {
            _ = send(
                .finishResult(
                    playerID: playerID,
                    position: position,
                    raceTime: raceTime
                ),
                to: context
            )
        }
        completeRaceIfNeeded()
    }

    private func completeRaceIfNeeded() {
        guard role == .host, raceInProgress, !raceComplete else { return }
        let currentIDs = Set(participants.map(\.id))
        guard currentIDs.isSubset(of: Set(finishOrder)) else { return }
        raceComplete = true
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
        raceComplete = false
        snapshotAccumulator = 0
    }

    private func resetRoundState() {
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
    }
}
