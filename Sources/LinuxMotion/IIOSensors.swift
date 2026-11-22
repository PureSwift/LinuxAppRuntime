import Foundation
import Glibc

/// The kernel's Industrial I/O sensors, read through sysfs
/// (`/sys/bus/iio/devices/iio:deviceN`), as iio-sensor-proxy reads the
/// ones it polls. Reading an attribute needs no permission.
///
/// | Sensor | Channel | Unit after scale |
/// |---|---|---|
/// | Accelerometer | `in_accel_{x,y,z}` | m/s² |
/// | Gyroscope | `in_anglvel_{x,y,z}` | rad/s |
/// | Magnetometer | `in_magn_{x,y,z}` | gauss (×100 for µT) |
/// | Barometer | `in_pressure` | kPa |
///
/// A channel's value is its `_input`, or `(_raw + offset) × scale`, the
/// scale and offset its own or the channel type's. Its mount matrix (the
/// channel type's `_mount_matrix`, or the device's `mount_matrix`) turns
/// the sensor's axes into the device's: x to the right, y toward the top, z
/// out of the screen, which is the contract's convention.
public struct IIOSensors {

    /// The directory of IIO devices.
    public let root: String

    public init(root: String = "/sys/bus/iio/devices") {
        self.root = root
    }

    public enum Kind: String, Sendable, CaseIterable {
        case accelerometer = "accel"
        case gyroscope = "anglvel"
        case magnetometer = "magn"
        case barometer = "pressure"

        var axes: [String] {
            self == .barometer ? [""] : ["_x", "_y", "_z"]
        }
    }

    /// The first device with `kind`'s channels, by device number.
    public func channel(_ kind: Kind) -> IIOChannel? {
        for device in devices() {
            if let channel = IIOChannel(kind: kind, device: device) {
                return channel
            }
        }
        return nil
    }

    /// The IIO devices' directories, `iio:device0` first.
    func devices() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        return names
            .filter { $0.hasPrefix("iio:device") }
            .sorted { (Int($0.dropFirst(10)) ?? .max, $0) < (Int($1.dropFirst(10)) ?? .max, $1) }
            .map { root + "/" + $0 }
    }
}

/// One sensor's channel: three axes, or one value for a barometer. Its
/// files stay open while it's being read.
public final class IIOChannel: @unchecked Sendable {

    public let kind: IIOSensors.Kind

    /// The device's directory.
    public let device: String

    /// The device's `name`.
    public let name: String

    /// Each axis's value file, and whether it's `_raw`.
    private let files: [(path: String, raw: Bool)]

    private let scales: [Double]

    private let offsets: [Double]

    /// Rows of the sensor-to-device rotation.
    let mountMatrix: [[Double]]

    /// The shortest interval the sensor samples at, from its sampling
    /// frequencies; `nil` when it doesn't say.
    public let minimumInterval: Double?

    private var descriptors: [Int32] = []

    init?(kind: IIOSensors.Kind, device: String) {
        let type = "in_" + kind.rawValue
        var files: [(path: String, raw: Bool)] = []
        var scales: [Double] = []
        var offsets: [Double] = []
        for axis in kind.axes {
            let channel = type + axis
            if Self.exists(device + "/" + channel + "_input") {
                files.append((device + "/" + channel + "_input", false))
            } else if Self.exists(device + "/" + channel + "_raw") {
                files.append((device + "/" + channel + "_raw", true))
            } else {
                return nil
            }
            scales.append(Self.number(device, [channel + "_scale", type + "_scale"]) ?? 1)
            offsets.append(Self.number(device, [channel + "_offset", type + "_offset"]) ?? 0)
        }
        self.kind = kind
        self.device = device
        self.name = Self.text(device + "/name") ?? ""
        self.files = files
        self.scales = scales
        self.offsets = offsets
        self.mountMatrix = Self.matrix(Self.text(device + "/" + type + "_mount_matrix") ?? Self.text(device + "/mount_matrix"))
            ?? Self.identity
        let available = [type + "_sampling_frequency_available", "sampling_frequency_available"]
            .lazy.compactMap { Self.text(device + "/" + $0) }.first
            .map { $0.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }.max() }
        let frequency = available ?? Self.number(device, [type + "_sampling_frequency", "sampling_frequency"])
        self.minimumInterval = frequency.flatMap { $0 > 0 ? 1 / $0 : nil }
    }

    deinit {
        close()
    }

    /// Why a reading failed.
    public enum ReadError: Error, Equatable {
        /// The driver is streaming to a buffer (iio-sensor-proxy has it
        /// claimed), and won't answer one reading: try again later.
        case busy
        /// The file can't be read, or doesn't hold a number.
        case failed(Int32)
    }

    /// The channel's values, in the device's axes and the kind's units (µT
    /// for a magnetometer). Opens its files the first time.
    public func read() -> Result<[Double], ReadError> {
        if descriptors.isEmpty {
            for file in files {
                let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
                guard descriptor >= 0 else {
                    let error = errno
                    close()
                    return .failure(.failed(error))
                }
                descriptors.append(descriptor)
            }
        }
        var values: [Double] = []
        for (index, descriptor) in descriptors.enumerated() {
            switch Self.value(descriptor) {
            case .success(let value):
                values.append(files[index].raw ? (value + offsets[index]) * scales[index] : value)
            case .failure(let error):
                if error != .busy {
                    close()
                }
                return .failure(error)
            }
        }
        if kind == .magnetometer {
            values = values.map { $0 * 100 }
        }
        guard values.count == 3 else { return .success(values) }
        return .success(mountMatrix.map { row in row[0] * values[0] + row[1] * values[1] + row[2] * values[2] })
    }

    /// Closes the files; the next `read` opens them again.
    public func close() {
        for descriptor in descriptors {
            Glibc.close(descriptor)
        }
        descriptors = []
    }

    // MARK: Files

    static let identity: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

    /// `x1, y1, z1; x2, y2, z2; x3, y3, z3`, as rows.
    static func matrix(_ text: String?) -> [[Double]]? {
        guard let text else { return nil }
        let rows = text.split(separator: ";").map { row in
            row.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
        guard rows.count == 3, rows.allSatisfy({ $0.count == 3 }) else { return nil }
        return rows
    }

    /// An attribute's number, read again from the start of the file.
    static func value(_ descriptor: Int32) -> Result<Double, ReadError> {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = buffer.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress, $0.count, 0) }
        guard count >= 0 else {
            let error = errno
            return .failure(error == EBUSY || error == EAGAIN ? .busy : .failed(error))
        }
        let text = String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(text) else { return .failure(.failed(EINVAL)) }
        return .success(value)
    }

    static func exists(_ path: String) -> Bool {
        access(path, R_OK) == 0
    }

    static func text(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The first of `names` in `device` that holds a number.
    static func number(_ device: String, _ names: [String]) -> Double? {
        names.lazy.compactMap { text(device + "/" + $0).flatMap(Double.init) }.first
    }
}
