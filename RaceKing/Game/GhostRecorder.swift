//
//  GhostRecorder.swift
//  RaceKing
//

import Foundation
import simd

/// One recorded lap: the car's pose sampled every frame.
struct GhostLap: Codable {
    struct Sample: Codable {
        var t: TimeInterval
        var x: Float
        var z: Float
        var heading: Float
    }

    var duration: TimeInterval
    var samples: [Sample]
    /// Length of the circuit the lap was driven on; a ghost from an older
    /// track layout is discarded (nil in files from before this field).
    var trackLength: Float?

    /// Interpolated pose at a lap-relative time, or nil once the ghost
    /// has finished its lap.
    func pose(at time: TimeInterval) -> (position: SIMD3<Float>, heading: Float)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.t { return ([first.x, 0, first.z], first.heading) }
        guard time < last.t else { return nil }

        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].t <= time { low = mid } else { high = mid }
        }
        let a = samples[low]
        let b = samples[high]
        let fraction = Float((time - a.t) / max(b.t - a.t, .ulpOfOne))
        let position = SIMD3<Float>(
            a.x + (b.x - a.x) * fraction, 0, a.z + (b.z - a.z) * fraction
        )
        return (position, a.heading + (b.heading - a.heading) * fraction)
    }
}

/// Records the player's laps and keeps the fastest one on disk.
struct GhostRecorder {
    private(set) var best: GhostLap?
    private var buffer: [GhostLap.Sample] = []
    private let trackLength: Float

    private static var fileURL: URL {
        let directory = URL.applicationSupportDirectory
            .appending(path: "RaceKing", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "ghost-lap.plist")
    }

    init(trackLength: Float) {
        self.trackLength = trackLength
        if let data = try? Data(contentsOf: Self.fileURL),
           let lap = try? PropertyListDecoder().decode(GhostLap.self, from: data),
           let savedLength = lap.trackLength, abs(savedLength - trackLength) < 0.01 {
            best = lap
        }
    }

    mutating func beginLap() {
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func record(time: TimeInterval, position: SIMD3<Float>, heading: Float) {
        buffer.append(.init(t: time, x: position.x, z: position.z, heading: heading))
    }

    /// Keeps the recorded lap if it beats the stored ghost.
    mutating func finishLap(duration: TimeInterval) {
        defer { buffer.removeAll(keepingCapacity: true) }
        guard duration > 0.5, buffer.count > 2 else { return }
        if let best, best.duration <= duration { return }
        let lap = GhostLap(duration: duration, samples: buffer, trackLength: trackLength)
        best = lap
        if let data = try? PropertyListEncoder().encode(lap) {
            try? data.write(to: Self.fileURL)
        }
    }
}
