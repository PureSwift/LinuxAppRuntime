import DynamicMotion
import Foundation

/// Device motion from an accelerometer and a gyroscope: a Mahony filter,
/// which integrates the rotation rate and pulls the attitude toward the
/// gravity the accelerometer measures.
///
/// The attitude rotates device coordinates into a frame with z vertical
/// and an x fixed where the device's x pointed when it started, as
/// Android's game rotation vector does; without a magnetometer, nothing
/// corrects drift around the vertical. Gravity is the vertical, back in the
/// device's axes, in the accelerometer's sign (z ≈ +9.81 face up), and user
/// acceleration what's left of the acceleration without it.
public struct MotionFusion {

    /// A unit quaternion.
    public struct Quaternion: Equatable, Sendable {
        public var x, y, z, w: Double

        public init(x: Double, y: Double, z: Double, w: Double) {
            (self.x, self.y, self.z, self.w) = (x, y, z, w)
        }

        public static let identity = Quaternion(x: 0, y: 0, z: 0, w: 1)

        var normalized: Quaternion {
            let length = (x * x + y * y + z * z + w * w).squareRoot()
            guard length > 0 else { return .identity }
            return Quaternion(x: x / length, y: y / length, z: z / length, w: w / length)
        }

        /// The reference frame's vertical, in device coordinates: the third
        /// row of the rotation.
        var vertical: [Double] {
            [2 * (x * z - w * y), 2 * (w * x + y * z), w * w - x * x - y * y + z * z]
        }
    }

    public struct Sample: Equatable, Sendable {
        public var attitude: Quaternion
        public var gravity: [Double]
        public var userAcceleration: [Double]
        public var rotationRate: [Double]
        public var timestamp: Int64
    }

    /// How hard the accelerometer pulls the attitude, per second.
    public var gain = 1.0

    public private(set) var attitude: Quaternion?

    private var last: Int64?

    public init() { }

    /// The device motion of one acceleration (m/s²) and rotation rate
    /// (rad/s) read together at `timestamp` (nanoseconds).
    public mutating func update(acceleration: [Double], rotationRate: [Double], timestamp: Int64) -> Sample {
        let length = (acceleration[0] * acceleration[0] + acceleration[1] * acceleration[1]
                      + acceleration[2] * acceleration[2]).squareRoot()
        var q = attitude ?? Self.level(acceleration, length: length)
        if attitude != nil, let last, timestamp > last {
            let dt = min(Double(timestamp - last) / 1e9, 0.5)
            var rate = rotationRate
            if length > 0 {
                // The error between the measured and the estimated
                // vertical, as a rotation that closes it.
                let a = acceleration.map { $0 / length }
                let v = q.vertical
                let error = [a[1] * v[2] - a[2] * v[1], a[2] * v[0] - a[0] * v[2], a[0] * v[1] - a[1] * v[0]]
                rate = zip(rate, error).map { $0 + gain * $1 }
            }
            let (gx, gy, gz) = (rate[0] * dt / 2, rate[1] * dt / 2, rate[2] * dt / 2)
            q = Quaternion(
                x: q.x + q.w * gx + q.y * gz - q.z * gy,
                y: q.y + q.w * gy - q.x * gz + q.z * gx,
                z: q.z + q.w * gz + q.x * gy - q.y * gx,
                w: q.w - q.x * gx - q.y * gy - q.z * gz
            ).normalized
        }
        attitude = q
        last = timestamp
        let gravity = q.vertical.map { $0 * standardGravity }
        return Sample(
            attitude: q,
            gravity: gravity,
            userAcceleration: zip(acceleration, gravity).map { $0 - $1 },
            rotationRate: rotationRate,
            timestamp: timestamp
        )
    }

    /// The attitude that turns `acceleration` to the vertical with the
    /// least rotation, so x stays as level as it can.
    static func level(_ acceleration: [Double], length: Double) -> Quaternion {
        guard length > 0 else { return .identity }
        let a = acceleration.map { $0 / length }
        // The rotation from a to z: about a × z, by the angle between them.
        if a[2] < -0.999999 {
            return Quaternion(x: 1, y: 0, z: 0, w: 0)
        }
        return Quaternion(x: a[1], y: -a[0], z: 0, w: 1 + a[2]).normalized
    }
}
