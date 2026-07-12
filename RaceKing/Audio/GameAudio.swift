//
//  GameAudio.swift
//  RaceKing
//

import AVFoundation
import os
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

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

    private let engine = AVAudioEngine()
    private let state = OSAllocatedUnfairLock(initialState: SynthState())
    private var sampleRate: Float = 44100
    private var started = false

    /// Starts the audio engine lazily; safe to call repeatedly.
    func start() {
        guard !started else { return }
        started = true
        #if os(iOS) || os(tvOS) || os(visionOS)
        // Ambient: respects the silent switch and mixes with the user's music.
        try? AVAudioSession.sharedInstance().setCategory(.ambient)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        let outputSampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = Float(outputSampleRate)
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: outputSampleRate, channels: 1
        ) else { return }

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
        try? engine.start()
        installRecoveryObservers()
    }

    /// Restarts the engine after phone calls, route changes (headphones),
    /// and returning from the background — it stops silently otherwise.
    private func installRecoveryObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngineIfNeeded() }
        }
        #if os(iOS) || os(tvOS) || os(visionOS)
        center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard rawType.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            MainActor.assumeIsolated { self?.restartEngineIfNeeded() }
        }
        #endif
        #if canImport(UIKit) && !os(watchOS)
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngineIfNeeded() }
        }
        #endif
    }

    private func restartEngineIfNeeded() {
        guard started, !engine.isRunning else { return }
        #if os(iOS) || os(tvOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        try? engine.start()
    }

    /// Feeds the engine and tire sounds; call every frame.
    func setEngine(speedRatio: Float, running: Bool, drifting: Bool = false) {
        guard started else { return }
        state.withLock {
            $0.engineFrequency = 60 + 260 * speedRatio
            $0.engineAmplitude = running ? 0.06 + 0.2 * speedRatio : 0
            $0.squealAmplitude = running && drifting ? 0.12 : 0
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
