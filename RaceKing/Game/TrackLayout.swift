//
//  TrackLayout.swift
//  RaceKing
//

import simd

/// Geometry of a rounded-rectangle circuit laid flat on the XZ plane,
/// centered at the origin. Distances are in meters (real-world AR scale).
struct TrackLayout {
    /// Half extent of the centerline along X, including the corner radius.
    var halfX: Float = 0.5
    /// Half extent of the centerline along Z, including the corner radius.
    var halfZ: Float = 0.35
    /// Corner radius of the centerline.
    var cornerRadius: Float = 0.2
    /// Width of the paved road.
    var roadWidth: Float = 0.16
    /// Number of ordered checkpoints the car must pass to complete a lap.
    var checkpointCount = 8

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

    /// Distance from a point to the centerline loop, using the signed-distance
    /// field of a rounded rectangle (the centerline is its zero level set).
    func distanceFromCenterline(_ point: SIMD3<Float>) -> Float {
        let q = SIMD2(abs(point.x), abs(point.z))
            - SIMD2(halfX, halfZ) + SIMD2(repeating: cornerRadius)
        let sdf = simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - cornerRadius
        return abs(sdf)
    }

    /// Ordered checkpoint positions; index 0 is the start/finish line.
    var checkpoints: [SIMD3<Float>] {
        (0..<checkpointCount).map { i in
            sample(at: startOffset + Float(i) / Float(checkpointCount) * totalLength).position
        }
    }

    /// Yaw angle (around +Y) that orients an entity's +Z axis along the tangent.
    static func heading(of tangent: SIMD3<Float>) -> Float {
        atan2(tangent.x, tangent.z)
    }
}
