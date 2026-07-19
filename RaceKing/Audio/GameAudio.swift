//
//  GameAudio.swift
//  RaceKing
//

import AVFoundation
import os
import UIKit

/// Procedural game audio: an engine tone that follows the car's speed plus
/// short beeps for countdown, laps, and results. No sound assets required.
final class GameAudio {
    private struct Beep {
        var frequency: Float
        /// Where the pitch slides to by the end (equal = steady tone).
        var endFrequency: Float
        var amplitude: Float
        /// Samples until the beep starts.
        var delay: Int
        var remaining: Int
        var total: Int
        var phase: Float = 0
    }

    private struct SynthState {
        var engineFrequency: Float = 0
        var engineAmplitude: Float = 0
        var enginePhase: Float = 0
        var squealAmplitude: Float = 0
        var squealPhase: Float = 0
        var noiseState: UInt32 = 0x1234_5678
        var beeps: [Beep] = []
    }

    private var engine = AVAudioEngine()
    private let state = OSAllocatedUnfairLock(initialState: SynthState())
    private var sampleRate: Float = 44100
    private var started = false
    private var sourceNode: AVAudioSourceNode?
    private var recoveryObserverTokens: [NSObjectProtocol] = []

    /// Looped background tracks (bundled .m4a). `race` resolves to one of
    /// seven tunes, rerolled whenever playback restarts from the top.
    enum MusicTrack: Hashable {
        case opening
        case setting
        case free
        case race

        fileprivate var resourceNames: [String] {
            switch self {
            case .opening: ["BGMOpening"]
            case .setting: ["BGMSetting"]
            case .free: ["BGMFree"]
            case .race: (1...7).map { "BGMRace\($0)" }
            }
        }
    }

    /// Players are created on first use and kept so a suspended race
    /// resumes its track from the same position.
    private var musicPlayers: [String: AVAudioPlayer] = [:]
    private var currentTrack: MusicTrack?
    /// The concrete file the current track resolved to (the race roll).
    private var currentResource: String?
    private var musicFadeTask: Task<Void, Never>?
    /// True when the track should restart from the top on the next play.
    private var musicRewindPending = true
    private static let musicVolume: Float = 0.35

    deinit {
        let center = NotificationCenter.default
        for token in recoveryObserverTokens {
            center.removeObserver(token)
        }
    }

    /// Starts the audio engine lazily; safe to call repeatedly.
    func start() {
        guard !engine.isRunning else {
            started = true
            return
        }
        // Ambient: respects the silent switch and mixes with the user's music.
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            started = false
            return
        }

        if sourceNode == nil {
            let outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
            sampleRate = Float(outputSampleRate)
            guard outputSampleRate > 0, let format = AVAudioFormat(
                standardFormatWithSampleRate: outputSampleRate, channels: 1
            ) else {
                started = false
                return
            }

            let rate = sampleRate
            let state = self.state
            let node = AVAudioSourceNode(format: format) { @Sendable _, _, frameCount, audioBufferList in
                let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                guard let out = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else {
                    return noErr
                }
                state.withLock { synth in
                    for frame in 0..<Int(frameCount) {
                        var sample: Float = 0
                        if synth.engineAmplitude > 0 {
                            synth.enginePhase += synth.engineFrequency / rate
                            if synth.enginePhase >= 1 { synth.enginePhase -= 1 }
                            // Two saw harmonics make a cheap engine buzz.
                            let saw = 2 * synth.enginePhase - 1
                            let saw2 = 2 * (synth.enginePhase * 2)
                                .truncatingRemainder(dividingBy: 1) - 1
                            sample += (saw * 0.7 + saw2 * 0.3) * synth.engineAmplitude
                        }
                        if synth.squealAmplitude > 0 {
                            // Tire squeal: a whiny tone with noisy pitch jitter.
                            synth.noiseState = synth.noiseState &* 1_664_525 &+ 1_013_904_223
                            let noise = Float(synth.noiseState >> 8) / Float(1 << 24) * 2 - 1
                            synth.squealPhase += (920 + 200 * noise) / rate
                            if synth.squealPhase >= 1 { synth.squealPhase -= 1 }
                            sample += sin(2 * .pi * synth.squealPhase)
                                * synth.squealAmplitude * (0.75 + 0.25 * noise)
                        }
                        for i in synth.beeps.indices {
                            if synth.beeps[i].delay > 0 {
                                synth.beeps[i].delay -= 1
                                continue
                            }
                            guard synth.beeps[i].remaining > 0 else { continue }
                            let beep = synth.beeps[i]
                            let progress = Float(beep.total - beep.remaining) / Float(beep.total)
                            let frequency = beep.frequency
                                + (beep.endFrequency - beep.frequency) * progress
                            synth.beeps[i].phase += frequency / rate
                            sample += sin(2 * .pi * synth.beeps[i].phase)
                                * sin(.pi * progress) * beep.amplitude
                            synth.beeps[i].remaining -= 1
                        }
                        out[frame] = max(-0.9, min(0.9, sample))
                    }
                    synth.beeps.removeAll { $0.delay <= 0 && $0.remaining <= 0 }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0.6
            sourceNode = node
        }
        do {
            try engine.start()
            started = true
            installRecoveryObservers()
        } catch {
            started = false
        }
    }

    /// Restarts the engine after phone calls, route changes (headphones),
    /// and returning from the background — it stops silently otherwise.
    private func installRecoveryObservers() {
        guard recoveryObserverTokens.isEmpty else { return }
        let center = NotificationCenter.default
        recoveryObserverTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngineIfNeeded() }
        })
        recoveryObserverTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard rawType.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            MainActor.assumeIsolated { self?.restartEngineIfNeeded() }
        })
        recoveryObserverTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngineIfNeeded() }
        })
        recoveryObserverTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.engine.stop()
                self?.started = false
            }
        })
        recoveryObserverTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildAudioEngine() }
        })
    }

    private func restartEngineIfNeeded() {
        guard !engine.isRunning else { return }
        start()
    }

    private func rebuildAudioEngine() {
        let center = NotificationCenter.default
        for token in recoveryObserverTokens { center.removeObserver(token) }
        recoveryObserverTokens.removeAll()
        engine.stop()
        engine = AVAudioEngine()
        sourceNode = nil
        started = false
        start()
    }

    /// Feeds the engine and tire sounds; call every frame.
    func setEngine(speedRatio: Float, running: Bool, drifting: Bool = false) {
        guard started else { return }
        let speed = min(1, max(0, abs(speedRatio)))
        state.withLock {
            $0.engineFrequency = 60 + 260 * speed
            $0.engineAmplitude = running ? 0.06 + 0.2 * speed : 0
            $0.squealAmplitude = running && drifting ? 0.12 : 0
        }
    }

    /// Drives the screen/mode BGM from the app state; call every frame.
    /// Pausing (race suspension) keeps the playback position; a nil track
    /// fades out and rewinds so the next play starts from the top.
    func setMusic(track: MusicTrack?, suspended: Bool) {
        if let track {
            suspended ? pauseMusic() : playMusic(track)
        } else {
            stopMusic()
        }
    }

    private func playMusic(_ track: MusicTrack) {
        // Menu music can be the very first sound after launch.
        if !started { start() }
        guard started else { return }
        if currentTrack != track {
            // The outgoing track fades under the incoming one.
            if let outgoing = currentPlayer {
                fadeOutAndPause(outgoing)
            }
            currentTrack = track
            musicRewindPending = true
        } else {
            // Resuming the same track cancels its pending fade-out.
            musicFadeTask?.cancel()
            musicFadeTask = nil
        }
        if musicRewindPending {
            // A fresh start also rerolls which race tune plays.
            currentResource = track.resourceNames.randomElement()
        }
        guard let resource = currentResource else { return }
        if musicPlayers[resource] == nil {
            guard let url = Bundle.main.url(
                forResource: resource, withExtension: "m4a"
            ), let player = try? AVAudioPlayer(contentsOf: url) else { return }
            player.numberOfLoops = -1
            musicPlayers[resource] = player
        }
        guard let player = musicPlayers[resource] else { return }
        if musicRewindPending {
            player.currentTime = 0
            musicRewindPending = false
        }
        player.setVolume(Self.musicVolume, fadeDuration: 0)
        // Re-issuing play() also recovers after a system interruption.
        if !player.isPlaying {
            player.play()
        }
    }

    private var currentPlayer: AVAudioPlayer? {
        currentResource.flatMap { musicPlayers[$0] }
    }

    func pauseMusic() {
        musicFadeTask?.cancel()
        musicFadeTask = nil
        // Pause every player so a mid-fade track cannot keep running.
        for player in musicPlayers.values {
            player.pause()
        }
    }

    func stopMusic() {
        guard let player = currentPlayer, !musicRewindPending else { return }
        musicRewindPending = true
        fadeOutAndPause(player)
    }

    /// Fades the given player out, then pauses it. Holds the player itself
    /// (not `currentPlayer`) so a track switch during the fade is safe.
    private func fadeOutAndPause(_ player: AVAudioPlayer) {
        musicFadeTask?.cancel()
        musicFadeTask = nil
        guard player.isPlaying else { return }
        player.setVolume(0, fadeDuration: 0.6)
        musicFadeTask = Task { [weak player] in
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled else { return }
            player?.pause()
        }
    }

    func handle(_ event: GameEvent) {
        start()
        switch event {
        case .countdownTick:
            beep(frequency: 660, duration: 0.12, amplitude: 0.5)
        case .go:
            beep(frequency: 990, duration: 0.4, amplitude: 0.55)
        case .lapCompleted(let isBest):
            beep(frequency: 880, duration: 0.1, amplitude: 0.5)
            beep(frequency: 1175, duration: 0.12, amplitude: 0.5, delay: 0.11)
            if isBest {
                beep(frequency: 1568, duration: 0.25, amplitude: 0.5, delay: 0.24)
            }
        case .timeAttackFinished(let isNewBest):
            let fanfare: [Float] = isNewBest
                ? [784, 988, 1175, 1568]
                : [660, 784, 988]
            for (i, frequency) in fanfare.enumerated() {
                beep(frequency: frequency, duration: 0.18, amplitude: 0.5,
                     delay: Double(i) * 0.17)
            }
        case .raceFinished(let position):
            let fanfare: [Float] = position == 1
                ? [784, 988, 1175, 1568]
                : [660, 784, 988]
            for (i, frequency) in fanfare.enumerated() {
                beep(frequency: frequency, duration: 0.18, amplitude: 0.5,
                     delay: Double(i) * 0.17)
            }
        case .offRoad:
            beep(frequency: 110, duration: 0.06, amplitude: 0.35)
        case .wallHit:
            beep(frequency: 85, duration: 0.09, amplitude: 0.6)
        case .driftStarted, .driftPulse:
            break  // the squeal loop carries the drift
        case .driftChargeLevelUp(let level):
            beep(frequency: level >= 2 ? 1760 : 1320, duration: 0.1, amplitude: 0.45)
        case .driftEnded(let boostLevel):
            if boostLevel > 0 {
                beep(frequency: 420, endFrequency: boostLevel >= 2 ? 1250 : 950,
                     duration: 0.3, amplitude: 0.55)
            }
        }
    }

    private func beep(
        frequency: Float, endFrequency: Float? = nil,
        duration: TimeInterval, amplitude: Float, delay: TimeInterval = 0
    ) {
        let total = max(1, Int(Float(duration) * sampleRate))
        let beep = Beep(
            frequency: frequency, endFrequency: endFrequency ?? frequency,
            amplitude: amplitude,
            delay: Int(Float(delay) * sampleRate), remaining: total, total: total
        )
        state.withLock { $0.beeps.append(beep) }
    }
}
