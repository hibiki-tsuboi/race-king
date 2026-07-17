//
//  TrackLayout.swift
//  RaceKing
//

import simd

/// Geometry of a rounded-rectangle circuit laid flat on the XZ plane,
/// centered at the origin. Distances are in meters (real-world AR scale).
struct TrackLayout {
    /// Half extent of the centerline along X, including the corner radius.
    var halfX: Float = 0.75
    /// Half extent of the centerline along Z, including the corner radius.
    var halfZ: Float = 0.52
    /// Corner radius of the centerline.
    var cornerRadius: Float = 0.3
    /// Width of the paved road.
    var roadWidth: Float = 0.30
    /// Number of ordered checkpoints the car must pass to complete a lap.
    var checkpointCount = 8

    /// How close the car must come to a checkpoint to collect it.
    var checkpointRadius: Float { roadWidth / 2 + 0.05 }

    /// Length of the two straights that run along X.
    var straightX: Float { 2 * (halfX - cornerRadius) }
    /// Length of the two straights that run along Z.
    var straightZ: Float { 2 * (halfZ - cornerRadius) }
    /// Total length of the centerline loop.
    var totalLength: Float { 2 * straightX + 2 * straightZ + 2 * .pi * cornerRadius }
    /// Arc length where the start/finish line sits (middle of the z = +halfZ straight).
    var startOffset: Float { straightX / 2 }

    /// Returns the centerline position and unit tangent at an arc length
    /// measured from the beginning of the z = +halfZ straight.
    func sample(at distance: Float) -> (position: SIMD3<Float>, tangent: SIMD3<Float>) {
        var s = distance.truncatingRemainder(dividingBy: totalLength)
        if s < 0 { s += totalLength }
        let ix = halfX - cornerRadius
        let iz = halfZ - cornerRadius
        let arc = .pi / 2 * cornerRadius

        if s < straightX {
            return (SIMD3(-ix + s, 0, halfZ), SIMD3(1, 0, 0))
        }
        s -= straightX
        if s < arc {
            return arcSample(center: SIMD3(ix, 0, iz), startAngle: 0, s: s)
        }
        s -= arc
        if s < straightZ {
            return (SIMD3(halfX, 0, iz - s), SIMD3(0, 0, -1))
        }
        s -= straightZ
        if s < arc {
            return arcSample(center: SIMD3(ix, 0, -iz), startAngle: .pi / 2, s: s)
        }
        s -= arc
        if s < straightX {
            return (SIMD3(ix - s, 0, -halfZ), SIMD3(-1, 0, 0))
        }
        s -= straightX
        if s < arc {
            return arcSample(center: SIMD3(-ix, 0, -iz), startAngle: .pi, s: s)
        }
        s -= arc
        if s < straightZ {
            return (SIMD3(-halfX, 0, -iz + s), SIMD3(0, 0, 1))
        }
        s -= straightZ
        return arcSample(center: SIMD3(-ix, 0, iz), startAngle: 3 * .pi / 2, s: s)
    }

    private func arcSample(
        center: SIMD3<Float>, startAngle: Float, s: Float
    ) -> (position: SIMD3<Float>, tangent: SIMD3<Float>) {
        let theta = startAngle + s / cornerRadius
        let position = center + cornerRadius * SIMD3(sin(theta), 0, cos(theta))
        let tangent = SIMD3(cos(theta), 0, -sin(theta))
        return (position, tangent)
    }

    /// Lateral offset of the barrier walls from the centerline.
    var wallOffset: Float { roadWidth / 2 + 0.055 }
    /// How far the car's center may stray from the centerline before the
    /// walls stop it (leaves room for the car body against the wall face).
    var corridorLimit: Float { wallOffset - 0.035 }

    /// Signed offset from the centerline loop, using the signed-distance
    /// field of a rounded rectangle: negative toward the infield, zero on
    /// the centerline, positive toward the outside.
    func signedOffset(_ point: SIMD3<Float>) -> Float {
        let q = SIMD2(abs(point.x), abs(point.z))
            - SIMD2(halfX, halfZ) + SIMD2(repeating: cornerRadius)
        return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - cornerRadius
    }

    /// Distance from a point to the centerline loop.
    func distanceFromCenterline(_ point: SIMD3<Float>) -> Float {
        abs(signedOffset(point))
    }

    /// Unit direction of increasing signed offset (toward the outside),
    /// from a numerical gradient in the XZ plane.
    func lateralNormal(at point: SIMD3<Float>) -> SIMD3<Float> {
        let e: Float = 0.005
        let dx = signedOffset(point + [e, 0, 0]) - signedOffset(point - [e, 0, 0])
        let dz = signedOffset(point + [0, 0, e]) - signedOffset(point - [0, 0, e])
        let normal = SIMD3<Float>(dx, 0, dz)
        let length = simd_length(normal)
        guard length > 1e-6 else { return .zero }
        return normal / length
    }

    /// Arc length of the centerline point closest to `point`, searched in a
    /// window around a previous estimate. Returns a value in [0, totalLength).
    func nearestS(to point: SIMD3<Float>, near hint: Float, window: Float = 0.4) -> Float {
        let p = SIMD2(point.x, point.z)
        var bestS = hint
        var bestD = Float.greatestFiniteMagnitude
        var s = hint - window
        while s <= hint + window {
            let q = sample(at: s).position
            let d = simd_distance_squared(p, SIMD2(q.x, q.z))
            if d < bestD { bestD = d; bestS = s }
            s += 0.02
        }
        var normalized = bestS.truncatingRemainder(dividingBy: totalLength)
        if normalized < 0 { normalized += totalLength }
        return normalized
    }

    /// Signed shortest arc-length step between two points on the loop.
    func progressDelta(from: Float, to: Float) -> Float {
        var delta = (to - from).truncatingRemainder(dividingBy: totalLength)
        if delta > totalLength / 2 { delta -= totalLength }
        if delta < -totalLength / 2 { delta += totalLength }
        return delta
    }

    /// Ordered checkpoint positions; index 0 is the start/finish line.
    var checkpoints: [SIMD3<Float>] {
        (0..<checkpointCount).map { i in
            sample(at: startOffset + Float(i) / Float(checkpointCount) * totalLength).position
        }
    }

    /// Returns where a forward movement segment crosses the visible finish line.
    /// The fraction is measured from `previous` (0) to `current` (1).
    func finishLineCrossingFraction(
        from previous: SIMD3<Float>, to current: SIMD3<Float>
    ) -> Float? {
        let finish = sample(at: startOffset)
        let previousDistance = simd_dot(previous - finish.position, finish.tangent)
        let currentDistance = simd_dot(current - finish.position, finish.tangent)
        let forwardDistance = currentDistance - previousDistance

        // A lap only counts in the course direction. Requiring a true side
        // change also prevents a stationary car on the line from retriggering.
        guard previousDistance <= 0, currentDistance > 0,
              forwardDistance > 1e-6 else { return nil }

        let fraction = max(0, min(1, -previousDistance / forwardDistance))
        let intersection = previous + (current - previous) * fraction
        let lateral = SIMD3<Float>(-finish.tangent.z, 0, finish.tangent.x)
        let lateralDistance = abs(simd_dot(intersection - finish.position, lateral))
        guard lateralDistance <= roadWidth / 2 + 1e-4 else { return nil }
        return fraction
    }

    /// Yaw angle (around +Y) that orients an entity's +Z axis along the tangent.
    static func heading(of tangent: SIMD3<Float>) -> Float {
        atan2(tangent.x, tangent.z)
    }
}
