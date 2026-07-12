//
//  TiltSteering.swift
//  RaceKing
//

#if os(iOS)
import CoreMotion

/// Steers with the phone's lateral tilt, like a steering wheel. Uses the
/// gravity vector so it works at any forward pitch — including holding the
/// phone half-flat to point the camera at the floor in AR.
final class TiltSteering {
    private let motion = CMMotionManager()

    func start(onSteer: @escaping (Float) -> Void) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1 / 60
        motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let gravity = data?.gravity else { return }
            // Lateral bank angle of the device, in radians.
            let tilt = asin(max(-1, min(1, Float(gravity.x))))
            let deadZone: Float = 0.05
            let fullLock: Float = 0.45  // ~26° tilts to full steering
            guard abs(tilt) > deadZone else {
                onSteer(0)
                return
            }
            let magnitude = min(1, (abs(tilt) - deadZone) / (fullLock - deadZone))
            onSteer(magnitude * (tilt > 0 ? 1 : -1))
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}
#endif
