//
//  TiltSteering.swift
//  RaceKing
//

import CoreMotion
import UIKit

/// Steers with the phone's lateral tilt, like a steering wheel. Uses the
/// gravity vector so it works at any forward pitch — including holding the
/// phone half-flat to point the camera at the floor in AR.
final class TiltSteering {
    private let motion = CMMotionManager()

    @discardableResult
    func start(
        orientation: @escaping () -> UIInterfaceOrientation,
        onSteer: @escaping (Float) -> Void,
        onUnavailable: @escaping () -> Void
    ) -> Bool {
        guard motion.isDeviceMotionAvailable else {
            onUnavailable()
            return false
        }
        if motion.isDeviceMotionActive { return true }
        motion.deviceMotionUpdateInterval = 1 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, error in
            guard error == nil, let gravity = data?.gravity else {
                self?.stop()
                onSteer(0)
                onUnavailable()
                return
            }
            // Core Motion reports device coordinates. Rotate them into the
            // active interface so positive always means screen-right.
            let lateralGravity: Double = switch orientation() {
            case .portrait:
                gravity.x
            case .portraitUpsideDown:
                -gravity.x
            case .landscapeLeft:
                -gravity.y
            case .landscapeRight:
                gravity.y
            default:
                gravity.x
            }
            // Lateral bank angle of the device, in radians.
            let tilt = asin(max(-1, min(1, Float(lateralGravity))))
            let deadZone: Float = 0.05
            let fullLock: Float = 0.45  // ~26° tilts to full steering
            guard abs(tilt) > deadZone else {
                onSteer(0)
                return
            }
            let magnitude = min(1, (abs(tilt) - deadZone) / (fullLock - deadZone))
            onSteer(magnitude * (tilt > 0 ? 1 : -1))
        }
        return motion.isDeviceMotionActive
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}
