//
//  PeerRaceSession.swift
//  RaceKing
//

import Foundation
import Network
import Observation
import UIKit

/// Discovers one nearby opponent over Bonjour and exchanges framed race data.
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

    private static let serviceType = "_anywheregp._tcp"
    private static let maximumPacketSize = 64 * 1024 * 1024
    private static let maximumWorldMapSize = 40 * 1024 * 1024
    private static let snapshotInterval: TimeInterval = 1.0 / 20.0
    private static let carChoiceDefaultsKey = "peerRaceCarChoice"

    private(set) var state: State = .idle
    private(set) var role: Role?
    private(set) var rooms: [Room] = []
    private(set) var peerName: String?
    private(set) var localReady = false
    private(set) var remoteReady = false
    private(set) var raceComplete = false
    private(set) var errorMessage: String?
    private(set) var courseSyncState: CourseSyncState = .unavailable
    private(set) var localCarChoice = RaceCarChoice(
        rawValue: UserDefaults.standard.string(forKey: "peerRaceCarChoice") ?? ""
    ) ?? .green
    private(set) var remoteCarChoice: RaceCarChoice?

    var canStartRace: Bool {
        state == .connected && role == .host
            && courseSyncState == .synchronized
            && remoteCarChoice != nil
            && localReady && remoteReady
    }

    var isCourseSynchronized: Bool { courseSyncState == .synchronized }

    var canSetReady: Bool {
        state == .connected && isCourseSynchronized && remoteCarChoice != nil
    }

    var canRequestCourseShare: Bool {
        guard state == .connected, role == .host else { return false }
        switch courseSyncState {
        case .hostPlacement, .failed(_):
            return true
        default:
            return false
        }
    }

    var connectionStatusText: String {
        switch state {
        case .idle: "未接続"
        case .hosting: "参加を待っています"
        case .browsing: "ルームを探しています"
        case .connecting: "接続しています"
        case .connected: "接続済み"
        }
    }

    @ObservationIgnored var onStartRace: (() -> Void)?
    @ObservationIgnored var onResetRace: (() -> Void)?
    @ObservationIgnored var onCarState: ((PeerRacePacket.CarState) -> Void)?
    @ObservationIgnored var onLocalCarChoiceChanged: ((RaceCarChoice) -> Void)?
    @ObservationIgnored var onRemoteCarChoiceChanged: ((RaceCarChoice?) -> Void)?
    @ObservationIgnored var onFinishResult: ((Int, TimeInterval) -> Void)?
    @ObservationIgnored var onConnectionChanged: ((Bool) -> Void)?
    @ObservationIgnored var onCourseMapRequested: (() -> Void)?
    @ObservationIgnored var onCourseMapReceived: ((Data, PeerRacePacket.CoursePlacement) -> Void)?
    @ObservationIgnored var onCourseSyncInvalidated: (() -> Void)?

    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var connection: NWConnection?
    @ObservationIgnored private var receiveBuffer = Data()
    @ObservationIgnored private var snapshotAccumulator: TimeInterval = 0
    @ObservationIgnored private var localFinished = false
    @ObservationIgnored private var remoteFinished = false
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    func startHosting() {
        disconnect()
        role = .host
        state = .hosting
        errorMessage = nil

        do {
            let listener = try NWListener(using: networkParameters())
            let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let roomName = String((deviceName.isEmpty ? "iPhone" : deviceName).prefix(40))
            listener.service = .init(name: "\(roomName)のレース", type: Self.serviceType)
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
            fail("ルームを作成できませんでした: \(error.localizedDescription)")
        }
    }

    func startBrowsing() {
        disconnect()
        role = .guest
        state = .browsing
        errorMessage = nil

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
        attach(NWConnection(to: room.endpoint, using: networkParameters()))
    }

    func setReady(_ ready: Bool) {
        guard state == .connected else { return }
        guard !ready || canSetReady else { return }
        localReady = ready
        send(.ready(ready))
    }

    /// Persists the local choice and immediately shares it with a connected peer.
    /// A car change invalidates this player's previous ready confirmation.
    func setLocalCarChoice(_ choice: RaceCarChoice) {
        guard choice != localCarChoice else { return }
        localCarChoice = choice
        UserDefaults.standard.set(choice.rawValue, forKey: Self.carChoiceDefaultsKey)
        onLocalCarChoiceChanged?(choice)

        guard state == .connected else { return }
        localReady = false
        send(.carSelection(choice))
        send(.ready(false))
    }

    /// Starts host-side world-map capture. The view owning ARSession supplies the map.
    func requestCourseShare() {
        guard canRequestCourseShare else { return }
        localReady = false
        remoteReady = false
        courseSyncState = .preparingMap
        send(.courseSyncStarted)
        onCourseMapRequested?()
    }

    func sendCourseMap(
        _ data: Data, placement: PeerRacePacket.CoursePlacement
    ) {
        guard state == .connected, role == .host,
              courseSyncState == .preparingMap else { return }
        guard data.count <= Self.maximumWorldMapSize else {
            failCourseShare("ARマップが大きすぎます。映す範囲を狭めてやり直してください")
            return
        }
        guard send(.courseMap(data: data, placement: placement)) else {
            failCourseShare("コース情報を送信できませんでした")
            return
        }
        courseSyncState = .waitingForGuest
    }

    /// Called by the guest after ARKit has relocalized to the host world map.
    func confirmCourseMapApplied() {
        guard state == .connected, role == .guest,
              courseSyncState == .relocalizing else { return }
        courseSyncState = .synchronized
        send(.courseMapApplied)
    }

    func failCourseShare(_ message: String) {
        guard state == .connected else { return }
        let safeMessage = String(message.prefix(160))
        localReady = false
        remoteReady = false
        courseSyncState = .failed(safeMessage)
        send(.courseMapFailed(safeMessage))
        onCourseSyncInvalidated?()
    }

    func requestStartRace() {
        guard canStartRace else { return }
        resetFinishState()
        send(.startRace)
        onStartRace?()
    }

    func requestResetRace() {
        guard state == .connected else { return }
        resetRoundState()
        send(.resetRace)
        onResetRace?()
    }

    func sendCarState(_ carState: PeerRacePacket.CarState, deltaTime: TimeInterval) {
        guard state == .connected, isCourseSynchronized else { return }
        snapshotAccumulator += deltaTime
        guard snapshotAccumulator >= Self.snapshotInterval else { return }
        snapshotAccumulator.formTruncatingRemainder(dividingBy: Self.snapshotInterval)
        send(.carState(carState))
    }

    /// The host decides finishing order according to the order finish messages arrive.
    func reportLocalFinish(raceTime: TimeInterval) {
        guard state == .connected, !localFinished else { return }
        localFinished = true
        if role == .host {
            onFinishResult?(remoteFinished ? 2 : 1, raceTime)
            completeRaceIfNeeded()
        } else {
            send(.finish(raceTime: raceTime))
        }
    }

    func clearError() {
        errorMessage = nil
    }

    func disconnect() {
        let wasConnected = state == .connected || state == .connecting
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        listener = nil
        browser = nil
        connection = nil
        receiveBuffer.removeAll(keepingCapacity: true)
        rooms = []
        peerName = nil
        remoteCarChoice = nil
        onRemoteCarChoiceChanged?(nil)
        role = nil
        state = .idle
        courseSyncState = .unavailable
        resetRoundState()
        if wasConnected {
            onCourseSyncInvalidated?()
            onConnectionChanged?(false)
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
            state = .hosting
        case .failed(let error):
            fail("ルームを公開できませんでした: \(error.localizedDescription)")
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
            fail("ルームを検索できませんでした: \(error.localizedDescription)")
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

    private func accept(_ newConnection: NWConnection) {
        guard role == .host, connection == nil else {
            newConnection.cancel()
            return
        }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        state = .connecting
        attach(newConnection)
    }

    private func attach(_ newConnection: NWConnection) {
        connection = newConnection
        receiveBuffer.removeAll(keepingCapacity: true)
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] newState in
            MainActor.assumeIsolated {
                guard let self, let newConnection,
                      self.connection === newConnection else { return }
                self.handleConnectionState(newState, connection: newConnection)
            }
        }
        newConnection.start(queue: .main)
    }

    private func handleConnectionState(
        _ newState: NWConnection.State, connection: NWConnection
    ) {
        switch newState {
        case .ready:
            state = .connected
            errorMessage = nil
            resetRoundState()
            resetCourseSyncState()
            receiveNextChunk(from: connection)
            send(.hello(name: UIDevice.current.name, carChoice: localCarChoice))
            onConnectionChanged?(true)
        case .failed(let error):
            fail("対戦相手との接続が切れました: \(error.localizedDescription)")
        case .cancelled:
            if self.connection === connection {
                fail("対戦相手との接続が切れました")
            }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        disconnect()
        errorMessage = message
    }

    // MARK: - Framing and protocol

    @discardableResult
    private func send(_ packet: PeerRacePacket) -> Bool {
        guard state == .connected, let connection else { return false }
        do {
            let payload = try encoder.encode(packet)
            guard payload.count <= Self.maximumPacketSize else { return false }
            var length = UInt32(payload.count).bigEndian
            var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
            frame.append(payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    guard let self, let connection,
                          self.connection === connection else { return }
                    self.fail("データを送信できませんでした: \(error.localizedDescription)")
                }
            })
            return true
        } catch {
            fail("対戦データを作成できませんでした: \(error.localizedDescription)")
            return false
        }
    }

    private func receiveNextChunk(from connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self, weak connection] content, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let connection,
                      self.connection === connection else { return }
                if let content { self.receiveBuffer.append(content) }
                guard self.consumeFrames() else { return }
                if let error {
                    self.fail("対戦データを受信できませんでした: \(error.localizedDescription)")
                } else if isComplete {
                    self.fail("対戦相手との接続が終了しました")
                } else {
                    self.receiveNextChunk(from: connection)
                }
            }
        }
    }

    @discardableResult
    private func consumeFrames() -> Bool {
        let headerSize = MemoryLayout<UInt32>.size
        while receiveBuffer.count >= headerSize {
            let length = receiveBuffer.prefix(headerSize).reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            guard length > 0, length <= Self.maximumPacketSize else {
                fail("不正な対戦データを受信しました")
                return false
            }
            let frameSize = headerSize + Int(length)
            guard receiveBuffer.count >= frameSize else { return true }
            let payload = receiveBuffer.subdata(in: headerSize..<frameSize)
            receiveBuffer.removeSubrange(0..<frameSize)
            do {
                handle(try decoder.decode(PeerRacePacket.self, from: payload))
            } catch {
                fail("対戦データを読み取れませんでした: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private func handle(_ packet: PeerRacePacket) {
        switch packet.kind {
        case .hello:
            guard packet.protocolVersion == PeerRacePacket.currentVersion else {
                fail("アプリのバージョンが対戦相手と一致しません")
                return
            }
            guard let carChoice = packet.carChoice else {
                fail("対戦相手の車情報を読み取れませんでした")
                return
            }
            peerName = packet.name?.isEmpty == false ? packet.name : "対戦相手"
            remoteCarChoice = carChoice
            onRemoteCarChoiceChanged?(carChoice)
        case .ready:
            if let isReady = packet.isReady,
               !isReady || (isCourseSynchronized && remoteCarChoice != nil) {
                remoteReady = isReady
            }
        case .courseSyncStarted:
            guard role == .guest else { return }
            switch courseSyncState {
            case .waitingForHost, .failed(_):
                break
            default:
                return
            }
            localReady = false
            remoteReady = false
            courseSyncState = .waitingForMap
            send(.ready(false))
            onCourseSyncInvalidated?()
        case .courseMap:
            guard role == .guest,
                  courseSyncState == .waitingForMap else { return }
            guard let data = packet.worldMapData,
                  data.count <= Self.maximumWorldMapSize,
                  let placement = packet.coursePlacement else {
                failCourseShare("コース情報を読み取れませんでした")
                return
            }
            localReady = false
            remoteReady = false
            courseSyncState = .relocalizing
            guard let onCourseMapReceived else {
                failCourseShare("ARコースを読み込めませんでした")
                return
            }
            onCourseMapReceived(data, placement)
        case .courseMapApplied:
            guard role == .host,
                  courseSyncState == .waitingForGuest else { return }
            courseSyncState = .synchronized
        case .courseMapFailed:
            guard !isCourseSynchronized else { return }
            let message = String(
                (packet.message ?? "コースの位置合わせに失敗しました").prefix(160)
            )
            localReady = false
            remoteReady = false
            courseSyncState = .failed(message)
            onCourseSyncInvalidated?()
        case .carSelection:
            guard let carChoice = packet.carChoice else { return }
            remoteCarChoice = carChoice
            remoteReady = false
            onRemoteCarChoiceChanged?(carChoice)
        case .startRace:
            guard role == .guest, isCourseSynchronized,
                  remoteCarChoice != nil else { return }
            resetFinishState()
            onStartRace?()
        case .carState:
            if isCourseSynchronized, let carState = packet.carState {
                onCarState?(carState)
            }
        case .finish:
            guard role == .host, !remoteFinished,
                  let raceTime = packet.raceTime else { return }
            remoteFinished = true
            let remotePosition = localFinished ? 2 : 1
            send(.finishResult(position: remotePosition, raceTime: raceTime))
            completeRaceIfNeeded()
        case .finishResult:
            guard role == .guest, let position = packet.position,
                  let raceTime = packet.raceTime else { return }
            onFinishResult?(position, raceTime)
        case .raceComplete:
            guard role == .guest else { return }
            raceComplete = true
        case .resetRace:
            resetRoundState()
            onResetRace?()
        }
    }

    private func resetFinishState() {
        localFinished = false
        remoteFinished = false
        raceComplete = false
        snapshotAccumulator = 0
    }

    private func completeRaceIfNeeded() {
        guard role == .host, localFinished, remoteFinished,
              !raceComplete else { return }
        raceComplete = true
        send(.raceComplete)
    }

    private func resetRoundState() {
        localReady = false
        remoteReady = false
        resetFinishState()
    }

    private func resetCourseSyncState() {
        switch role {
        case .host:
            courseSyncState = .hostPlacement
        case .guest:
            courseSyncState = .waitingForHost
        case nil:
            courseSyncState = .unavailable
        }
    }
}
