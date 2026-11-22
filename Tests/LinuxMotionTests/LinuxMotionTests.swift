import DynamicMotion
import DynamicRuntime
import Foundation
import LinuxHost
import Testing
@testable import LinuxMotion

/// IIO devices' attributes, laid out under a temporary root as sysfs has
/// them.
struct FakeIIO {

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("iio-\(UUID().uuidString)").path

    /// Writes in place, in one write of a fixed length, so a reading
    /// meanwhile sees the old value or the new one, as sysfs gives them.
    func write(_ device: Int, _ name: String, _ text: String) throws {
        let directory = root + "/iio:device\(device)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/" + name
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let padded = (text + "\n").padding(toLength: 48, withPad: " ", startingAt: 0)
        let file = try #require(FileHandle(forWritingAtPath: path))
        defer { try? file.close() }
        try file.write(contentsOf: Data(padded.utf8))
    }

    var sensors: IIOSensors { IIOSensors(root: root) }

    /// An accelerometer lying face up, read in counts of 1/1024 g; a
    /// gyroscope at rest; both on one chip, as an IMU has them.
    static func imu() throws -> FakeIIO {
        let iio = FakeIIO()
        try iio.write(0, "name", "bmi260")
        for (axis, value) in [("x", "0"), ("y", "0"), ("z", "1024")] {
            try iio.write(0, "in_accel_\(axis)_raw", value)
            try iio.write(0, "in_anglvel_\(axis)_raw", "0")
        }
        try iio.write(0, "in_accel_scale", "\(standardGravity / 1024)")
        try iio.write(0, "in_anglvel_scale", "0.001")
        try iio.write(0, "in_accel_sampling_frequency_available", "12.5 25 50 100 200")
        return iio
    }
}

/// Records what the manager tells its delegate.
final class RecordingMotionDelegate: MotionManagerDelegate {

    var accelerations: [[Double]] = []
    var rotations: [[Double]] = []
    var fields: [([Double], Int32)] = []
    var motions: [(attitude: [Double], gravity: [Double], user: [Double])] = []
    var timestamps: [Int64] = []
    var failures: [(sensor: Int32, error: Int32)] = []

    func didUpdateAcceleration(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        accelerations.append([x, y, z])
        timestamps.append(timestamp)
    }

    func didUpdateRotationRate(_ manager: any MotionManager, x: Double, y: Double, z: Double, timestamp: Int64) {
        rotations.append([x, y, z])
    }

    func didUpdateMagneticField(_ manager: any MotionManager, x: Double, y: Double, z: Double, accuracy: Int32, timestamp: Int64) {
        fields.append(([x, y, z], accuracy))
    }

    func didUpdateDeviceMotion(
        _ manager: any MotionManager,
        attitudeX: Double, attitudeY: Double, attitudeZ: Double, attitudeW: Double,
        gravityX: Double, gravityY: Double, gravityZ: Double,
        userAccelerationX: Double, userAccelerationY: Double, userAccelerationZ: Double,
        rotationRateX: Double, rotationRateY: Double, rotationRateZ: Double,
        timestamp: Int64
    ) {
        motions.append(([attitudeX, attitudeY, attitudeZ, attitudeW], [gravityX, gravityY, gravityZ],
                        [userAccelerationX, userAccelerationY, userAccelerationZ]))
    }

    func didFail(_ manager: any MotionManager, sensor: Int32, error: Int32) {
        failures.append((sensor, error))
    }
}

final class RecordingAltimeterDelegate: AltimeterDelegate {

    var statuses: [Int32] = []
    var samples: [(pressure: Double, altitude: Double)] = []
    var failures: [Int32] = []

    func didChangeAuthorization(_ altimeter: any Altimeter, status: Int32) { statuses.append(status) }
    func didUpdate(_ altimeter: any Altimeter, pressure: Double, relativeAltitude: Double, timestamp: Int64) {
        samples.append((pressure, relativeAltitude))
    }
    func didFail(_ altimeter: any Altimeter, error: Int32) { failures.append(error) }
}

final class RecordingPedometerDelegate: PedometerDelegate {

    var events: [String] = []

    func didChangeAuthorization(_ pedometer: any Pedometer, status: Int32) { events.append("status \(status)") }
    func didUpdate(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32,
                   start: Int64, end: Int64) { events.append("update") }
    func didQuery(_ pedometer: any Pedometer, steps: Int64, distance: Double, floorsAscended: Int32, floorsDescended: Int32,
                  start: Int64, end: Int64, error: Int32) { events.append("query \(steps) \(start) \(end) \(error)") }
    func didFail(_ pedometer: any Pedometer, error: Int32) { events.append("fail \(error)") }
}

final class RecordingActivityDelegate: ActivityRecognizerDelegate {

    var events: [String] = []

    func didChangeAuthorization(_ recognizer: any ActivityRecognizer, status: Int32) { events.append("status \(status)") }
    func didUpdateActivity(_ recognizer: any ActivityRecognizer, activity: Int32, confidence: Int32, timestamp: Int64) {
        events.append("activity")
    }
    func didFail(_ recognizer: any ActivityRecognizer, error: Int32) { events.append("fail \(error)") }
}

func isClose(_ a: [Double], _ b: [Double], within tolerance: Double = 1e-6) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

/// `LinuxMotionManager.sensors` is every test's, so one at a time.
@Suite(.serialized) struct LinuxMotionTests {

    func with(_ iio: FakeIIO, _ body: () throws -> Void) rethrows {
        let previous = LinuxMotionManager.sensors
        LinuxMotionManager.sensors = iio.sensors
        defer { LinuxMotionManager.sensors = previous }
        try body()
    }

    /// Runs the main loop until `done`, for up to five seconds: a timer
    /// wakes it then, since nothing else may.
    func run(until done: () -> Bool) {
        var expired = false
        let timer = MainLoop.shared.schedule(after: 5_000_000_000) { expired = true }
        defer { MainLoop.shared.cancel(timer) }
        MainLoop.shared.run { done() || expired }
    }

    // MARK: IIO

    @Test func channelsReadScaledValuesInTheDevicesAxes() throws {
        let iio = try FakeIIO.imu()
        // Mounted turned a quarter: the sensor's x is the device's y.
        try iio.write(0, "in_accel_mount_matrix", "0, -1, 0; 1, 0, 0; 0, 0, 1")
        try iio.write(0, "in_accel_x_raw", "512")
        let channel = try #require(iio.sensors.channel(.accelerometer))
        #expect(channel.name == "bmi260")
        let values = try channel.read().get()
        #expect(isClose(values, [0, standardGravity / 2, standardGravity]))
        #expect(channel.minimumInterval == 1.0 / 200)

        // Read again from the start of each file.
        try iio.write(0, "in_accel_x_raw", "-1024")
        #expect(isClose(try channel.read().get(), [0, -standardGravity, standardGravity]))
    }

    @Test func inputsOffsetsAndUnits() throws {
        let iio = FakeIIO()
        // A magnetometer giving processed gauss, per axis.
        try iio.write(1, "in_magn_x_input", "0.25")
        try iio.write(1, "in_magn_y_input", "-0.1")
        try iio.write(1, "in_magn_z_input", "0.4")
        try iio.write(1, "in_magn_x_scale", "1000")
        // A barometer with an offset, in kPa.
        try iio.write(2, "in_pressure_raw", "1000")
        try iio.write(2, "in_pressure_offset", "13.25")
        try iio.write(2, "in_pressure_scale", "0.1")
        // Neither has the other's channels, nor an accelerometer.
        #expect(iio.sensors.channel(.accelerometer) == nil)
        let magnetometer = try #require(iio.sensors.channel(.magnetometer))
        #expect(isClose(try magnetometer.read().get(), [25, -10, 40]), "µT; an input is already scaled")
        #expect(magnetometer.minimumInterval == nil)
        let barometer = try #require(iio.sensors.channel(.barometer))
        #expect(isClose(try barometer.read().get(), [101.325]))

        try iio.write(2, "in_pressure_raw", "not a number")
        #expect(barometer.read() == .failure(.failed(EINVAL)))
    }

    @Test func theFirstDeviceWithTheChannels() throws {
        let iio = FakeIIO()
        for device in [10, 2] {
            for axis in ["x", "y", "z"] {
                try iio.write(device, "in_accel_\(axis)_raw", "\(device)")
            }
        }
        // Device 10 sorts after 2 by number, not by name.
        #expect(try iio.sensors.channel(.accelerometer)?.read().get() == [2, 2, 2])
        #expect(IIOChannel.matrix("1, 0; 0, 1") == nil)
    }

    // MARK: Fusion

    @Test func fusionStartsLevelWithGravity() {
        for acceleration in [[0, 0, standardGravity], [3, -4, 8], [0, 0, -standardGravity], [standardGravity, 0, 0]] {
            var fusion = MotionFusion()
            let sample = fusion.update(acceleration: acceleration, rotationRate: [0, 0, 0], timestamp: 0)
            let length = (acceleration.map { $0 * $0 }.reduce(0, +)).squareRoot()
            #expect(isClose(sample.gravity, acceleration.map { $0 / length * standardGravity }), "gravity along \(acceleration)")
            let q = sample.attitude
            #expect(abs(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w - 1) < 1e-9)
        }
    }

    @Test func fusionIntegratesTheRotationRate() {
        var fusion = MotionFusion()
        let rest = [0, 0, standardGravity]
        _ = fusion.update(acceleration: rest, rotationRate: [0, 0, 0], timestamp: 0)
        // A quarter turn about the vertical in a second.
        var sample = fusion.update(acceleration: rest, rotationRate: [0, 0, 0], timestamp: 0)
        for step in 1...100 {
            sample = fusion.update(acceleration: rest, rotationRate: [0, 0, .pi / 2], timestamp: Int64(step) * 10_000_000)
        }
        let half = Double.pi / 4
        #expect(isClose([sample.attitude.x, sample.attitude.y, sample.attitude.z, sample.attitude.w], [0, 0, sin(half), cos(half)],
                      within: 1e-3))
        #expect(isClose(sample.gravity, rest, within: 1e-6), "still level")
        #expect(isClose(sample.userAcceleration, [0, 0, 0], within: 1e-6))
        #expect(sample.rotationRate == [0, 0, .pi / 2])
    }

    @Test func fusionFollowsGravityBack() {
        var fusion = MotionFusion()
        _ = fusion.update(acceleration: [0, 0, standardGravity], rotationRate: [0, 0, 0], timestamp: 0)
        // Tipped onto its side with no rotation seen: the accelerometer
        // pulls the attitude over.
        let side = [0, standardGravity, 0]
        var sample = fusion.update(acceleration: side, rotationRate: [0, 0, 0], timestamp: 0)
        for step in 1...2000 {
            sample = fusion.update(acceleration: side, rotationRate: [0, 0, 0], timestamp: Int64(step) * 10_000_000)
        }
        #expect(isClose(sample.gravity, side, within: 1e-3))
    }

    // MARK: MotionManager

    @Test func availability() throws {
        let imu = try FakeIIO.imu()
        try with(imu) {
            #expect(LinuxMotionManager.isAvailable(MotionSensor.accelerometer.rawValue))
            #expect(LinuxMotionManager.isAvailable(MotionSensor.gyroscope.rawValue))
            #expect(LinuxMotionManager.isAvailable(MotionSensor.deviceMotion.rawValue))
            #expect(!LinuxMotionManager.isAvailable(MotionSensor.magnetometer.rawValue))
            #expect(!LinuxMotionManager.isAvailable(99))
            let manager = LinuxMotionManager.make(RecordingMotionDelegate())
            #expect(manager.minimumInterval(MotionSensor.accelerometer.rawValue) == 0.01, "no faster than 100 Hz")
            try imu.write(0, "in_accel_sampling_frequency_available", "12.5 25")
            #expect(manager.minimumInterval(MotionSensor.accelerometer.rawValue) == 0.04)
            #expect(manager.minimumInterval(MotionSensor.deviceMotion.rawValue) == 0.04)
        }
        try with(FakeIIO()) {
            #expect(!LinuxMotionManager.isAvailable(MotionSensor.accelerometer.rawValue))
            #expect(!LinuxMotionManager.isAvailable(MotionSensor.deviceMotion.rawValue))
        }
    }

    @Test func samplesReachTheDelegate() throws {
        try with(try FakeIIO.imu()) {
            let delegate = RecordingMotionDelegate()
            let manager = LinuxMotionManager.make(delegate)
            manager.start(MotionSensor.accelerometer.rawValue, interval: 0)
            manager.start(MotionSensor.deviceMotion.rawValue, interval: 0.02)
            #expect(manager.isActive(MotionSensor.accelerometer.rawValue))
            run { delegate.accelerations.count >= 3 && delegate.motions.count >= 2 }
            #expect(delegate.accelerations.count >= 3)
            #expect(isClose(delegate.accelerations[0], [0, 0, standardGravity]))
            #expect(delegate.timestamps == delegate.timestamps.sorted() && delegate.timestamps[0] > 0)
            let motion = try #require(delegate.motions.first)
            #expect(isClose(motion.gravity, [0, 0, standardGravity]) && isClose(motion.user, [0, 0, 0]))
            #expect(isClose(motion.attitude, [0, 0, 0, 1]))

            manager.stop(MotionSensor.accelerometer.rawValue)
            manager.stop(MotionSensor.deviceMotion.rawValue)
            #expect(!manager.isActive(MotionSensor.accelerometer.rawValue))
            let count = delegate.accelerations.count
            var waited = false
            MainLoop.shared.schedule(after: 100_000_000) { waited = true }
            MainLoop.shared.run { waited }
            #expect(delegate.accelerations.count == count, "nothing after stop")
            #expect(delegate.failures.isEmpty)
        }
    }

    @Test func aMissingSensorFails() throws {
        try with(try FakeIIO.imu()) {
            let delegate = RecordingMotionDelegate()
            let manager = LinuxMotionManager.make(delegate)
            manager.start(MotionSensor.magnetometer.rawValue, interval: 0.1)
            #expect(!manager.isActive(MotionSensor.magnetometer.rawValue))
            run { !delegate.failures.isEmpty }
            #expect(delegate.failures.map(\.sensor) == [MotionSensor.magnetometer.rawValue])
            #expect(delegate.failures.map(\.error) == [MotionError.unavailable.rawValue])
        }
    }

    @Test func anUnreadableSensorStops() throws {
        let imu = try FakeIIO.imu()
        try with(imu) {
            let delegate = RecordingMotionDelegate()
            let manager = LinuxMotionManager.make(delegate)
            manager.start(MotionSensor.gyroscope.rawValue, interval: 0.01)
            run { !delegate.rotations.isEmpty }
            try imu.write(0, "in_anglvel_y_raw", "garbage")
            run { !delegate.failures.isEmpty }
            #expect(delegate.failures.map(\.error) == [MotionError.unknown.rawValue])
            #expect(!manager.isActive(MotionSensor.gyroscope.rawValue))
        }
    }

    @Test func magneticFieldIsUncalibrated() throws {
        let iio = FakeIIO()
        for axis in ["x", "y", "z"] {
            try iio.write(0, "in_magn_\(axis)_raw", "1")
        }
        try iio.write(0, "in_magn_scale", "0.5")
        try with(iio) {
            let delegate = RecordingMotionDelegate()
            let manager = LinuxMotionManager.make(delegate)
            manager.start(MotionSensor.magnetometer.rawValue, interval: 0.01)
            run { !delegate.fields.isEmpty }
            manager.stop(MotionSensor.magnetometer.rawValue)
            let field = try #require(delegate.fields.first)
            #expect(isClose(field.0, [50, 50, 50]))
            #expect(field.1 == MagneticFieldAccuracy.uncalibrated.rawValue)
        }
    }

    // MARK: Altimeter

    @Test func altitudeFromPressure() throws {
        let iio = FakeIIO()
        try iio.write(3, "in_pressure_input", "101.325")
        try with(iio) {
            #expect(LinuxAltimeter.isAvailable())
            #expect(LinuxAltimeter.authorizationStatus() == MotionAuthorization.authorized.rawValue)
            LinuxAltimeter.interval = 0.01
            defer { LinuxAltimeter.interval = 1 }
            let delegate = RecordingAltimeterDelegate()
            let altimeter = LinuxAltimeter.make(delegate)
            altimeter.requestAuthorization()
            altimeter.startUpdates()
            run { !delegate.samples.isEmpty }
            #expect(delegate.statuses == [MotionAuthorization.authorized.rawValue])
            #expect(delegate.samples.first.map { isClose([$0.pressure, $0.altitude], [101.325, 0]) } == true)

            // About 8.4 m higher per 0.1 kPa near sea level.
            try iio.write(3, "in_pressure_input", "101.225")
            run { delegate.samples.last?.pressure == 101.225 }
            altimeter.stopUpdates()
            let altitude = try #require(delegate.samples.last?.altitude)
            #expect(abs(altitude - 8.32) < 0.05, "\(altitude)")
            #expect(delegate.failures.isEmpty)
        }
        try with(FakeIIO()) {
            #expect(!LinuxAltimeter.isAvailable())
            let delegate = RecordingAltimeterDelegate()
            let altimeter = LinuxAltimeter.make(delegate)
            altimeter.startUpdates()
            run { !delegate.failures.isEmpty }
            #expect(delegate.failures == [MotionError.unavailable.rawValue])
        }
    }

    // MARK: Pedometer and activity

    @Test func pedometerAndActivityAreUnavailable() {
        #expect(!LinuxPedometer.isStepCountingAvailable() && !LinuxPedometer.isHistoryAvailable())
        #expect(!LinuxPedometer.isDistanceAvailable() && !LinuxPedometer.isFloorCountingAvailable())
        #expect(LinuxPedometer.authorizationStatus() == MotionAuthorization.authorized.rawValue)
        let pedometer = RecordingPedometerDelegate()
        let steps = LinuxPedometer.make(pedometer)
        steps.requestAuthorization()
        steps.startUpdates(from: 0)
        steps.query(from: 10, to: 20)
        MainLoop.shared.drain()
        let unavailable = MotionError.unavailable.rawValue
        #expect(pedometer.events == ["status \(MotionAuthorization.authorized.rawValue)", "fail \(unavailable)",
                                     "query -1 10 20 \(unavailable)"])

        #expect(!LinuxActivityRecognizer.isAvailable())
        let activity = RecordingActivityDelegate()
        let recognizer = LinuxActivityRecognizer.make(activity)
        recognizer.requestAuthorization()
        recognizer.startUpdates()
        MainLoop.shared.drain()
        #expect(activity.events == ["status \(MotionAuthorization.authorized.rawValue)", "fail \(unavailable)"])
    }

    // MARK: The module

    @Test func moduleRegistersTheContracts() {
        let names = LinuxMotion.contracts.map(\.name)
        #expect(names == [
            "org.pureswift.motion.MotionManager", "org.pureswift.motion.MotionManagerDelegate",
            "org.pureswift.motion.Altimeter", "org.pureswift.motion.AltimeterDelegate",
            "org.pureswift.motion.Pedometer", "org.pureswift.motion.PedometerDelegate",
            "org.pureswift.motion.ActivityRecognizer", "org.pureswift.motion.ActivityRecognizerDelegate",
        ])
        #expect(LinuxMotion.permissionProviders()[.motion]?.status() == .granted)
    }
}
