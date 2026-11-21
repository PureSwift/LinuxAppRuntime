import DBus
import DynamicLocation
import Foundation
import LinuxDBus

/// The `Location` contract over one of GeoClue's `Location` objects' properties.
///
/// GeoClue gives the coordinate, its accuracy, the altitude, speed and
/// heading, and when; the rest is unknown, as the contract marks it:
/// negative accuracies, `nan` altitude, and `-1` for whether it's
/// simulated.
public final class LinuxLocationFix: Location {

    public let latitudeValue: Double

    public let longitudeValue: Double

    /// Meters; `nan` when GeoClue doesn't know.
    public let altitudeValue: Double

    /// Meters.
    public let accuracy: Double

    /// Meters per second, or `-1`.
    public let speedValue: Double

    /// Degrees from true north, or `-1`.
    public let heading: Double

    /// Milliseconds since 1970.
    public let milliseconds: Int64

    public init(latitude: Double, longitude: Double, altitude: Double = .nan, accuracy: Double,
                speed: Double = -1, heading: Double = -1, milliseconds: Int64) {
        self.latitudeValue = latitude
        self.longitudeValue = longitude
        self.altitudeValue = altitude
        self.accuracy = accuracy
        self.speedValue = speed
        self.heading = heading
        self.milliseconds = milliseconds
    }

    /// From `org.freedesktop.GeoClue2.Location`'s properties; `nil` without
    /// a coordinate. A missing `Timestamp` is now.
    public convenience init?(_ properties: [String: DBusMessageArgument], now: Date = Date()) {
        guard let latitude = properties["Latitude"]?.doubleValue,
              let longitude = properties["Longitude"]?.doubleValue else {
            return nil
        }
        let altitude = properties["Altitude"]?.doubleValue ?? GeoClue.unknownAltitude
        var milliseconds = Int64((now.timeIntervalSince1970 * 1000).rounded())
        // (tt): seconds and microseconds.
        if let time = properties["Timestamp"]?.fields, time.count == 2,
           let seconds = time[0].int64Value, let microseconds = time[1].int64Value {
            milliseconds = seconds * 1000 + microseconds / 1000
        }
        self.init(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude <= GeoClue.unknownAltitude || !altitude.isFinite ? .nan : altitude,
            accuracy: properties["Accuracy"]?.doubleValue ?? -1,
            speed: Self.orUnknown(properties["Speed"]?.doubleValue),
            heading: Self.orUnknown(properties["Heading"]?.doubleValue),
            milliseconds: milliseconds
        )
    }

    /// GeoClue's `-1` for unknown, and anything else negative, is the
    /// contract's.
    private static func orUnknown(_ value: Double?) -> Double {
        guard let value, value >= 0, value.isFinite else { return -1 }
        return value
    }

    /// Meters to `other` along the ground (haversine).
    public func distance(from other: LinuxLocationFix) -> Double {
        let radius = 6_371_000.0
        let φ1 = latitudeValue * .pi / 180, φ2 = other.latitudeValue * .pi / 180
        let Δφ = φ2 - φ1
        let Δλ = (other.longitudeValue - longitudeValue) * .pi / 180
        let a = sin(Δφ / 2) * sin(Δφ / 2) + cos(φ1) * cos(φ2) * sin(Δλ / 2) * sin(Δλ / 2)
        return 2 * radius * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: Location

    public func latitude() -> Double { latitudeValue }

    public func longitude() -> Double { longitudeValue }

    public func altitude() -> Double { altitudeValue }

    public func horizontalAccuracy() -> Double { accuracy }

    public func verticalAccuracy() -> Double { -1 }

    public func speed() -> Double { speedValue }

    public func speedAccuracy() -> Double { -1 }

    public func course() -> Double { heading }

    public func courseAccuracy() -> Double { -1 }

    public func timestamp() -> Int64 { milliseconds }

    public func isSimulated() -> Int32 { -1 }
}

/// The `Heading` contract. Linux has no compass service, so the manager
/// never makes one (`isHeadingAvailable()` is `false`); it's registered so
/// the contract resolves.
public final class LinuxHeading: Heading {

    public init() { }

    public func magneticHeading() -> Double { -1 }

    public func trueHeading() -> Double { -1 }

    public func headingAccuracy() -> Double { -1 }

    public func timestamp() -> Int64 { 0 }
}
