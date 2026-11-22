import DBus
import DynamicNFC
import Foundation
import LinuxDBus
import LinuxHost

/// neard's records and NDEF records, each way (`Plan.md` §14).
///
/// neard parses a tag's message itself and publishes each record it knows
/// as an object of its own (`org.neard.Record`) with the record's fields as
/// properties, not as bytes; it writes only records it can make from such
/// fields. So a message holds what neard can say: text, URIs, MIME types,
/// Smart Posters and Android application records read, and text, URIs and
/// MIME types written.
enum NeardRecords {

    /// The records under `tag`, in neard's order (`record0`, `record1`, …).
    static func records(of tag: String, in objects: [String: NeardInterfaces]) -> [LinuxNDEFRecord] {
        let prefix = tag + "/record"
        let found = objects.compactMap { path, interfaces -> (Int, [String: DBusMessageArgument])? in
            guard path.hasPrefix(prefix), let index = Int(path.dropFirst(prefix.count)),
                  let properties = interfaces[Neard.record] else {
                return nil
            }
            return (index, properties)
        }
        return found.sorted { $0.0 < $1.0 }.compactMap { record($0.1) }
    }

    /// One of neard's records, or nil for a kind neard publishes but the
    /// contract has no way to say (a Bluetooth or Wi-Fi handover).
    static func record(_ properties: [String: DBusMessageArgument]) -> LinuxNDEFRecord? {
        let kind = properties["Type"]?.text
        switch kind {
        case "Text":
            return .makeText(properties["Representation"]?.text ?? "", locale: properties["Language"]?.text ?? "")
        case "URI":
            return properties["URI"]?.text.flatMap(LinuxNDEFRecord.makeURI)
        case "MIME":
            guard let type = properties["MIME"]?.text else { return nil }
            return LinuxNDEFRecord(format: .media, type: Array(type.utf8), identifier: [], payload: properties["MIMEPayload"]?.bytes ?? [])
        case "SmartPoster":
            // The poster's URI, and its title, in a message of their own.
            var inside: [LinuxNDEFRecord] = []
            if let uri = properties["URI"]?.text.flatMap(LinuxNDEFRecord.makeURI) {
                inside.append(uri)
            }
            if let title = properties["Representation"]?.text {
                inside.append(.makeText(title, locale: properties["Language"]?.text ?? ""))
            }
            return LinuxNDEFRecord(format: .wellKnown, type: smartPosterType, identifier: [], payload: LinuxNDEFMessage(inside).encoded())
        case "AAR":
            guard let package = (properties["AAR"] ?? properties["AndroidPackage"])?.text else { return nil }
            return LinuxNDEFRecord(format: .external, type: Array("android.com:pkg".utf8), identifier: [], payload: Array(package.utf8))
        default:
            HostLog.debug("nfc: neard's \(kind ?? "untyped") record left out")
            return nil
        }
    }

    /// `Tag.Write`'s argument for `message`: one record's fields, or every
    /// record's under `Records`. Nil for an empty message, or a record
    /// neard can't make.
    static func attributes(_ message: LinuxNDEFMessage) -> [String: DBusMessageArgument]? {
        let records = message.recordList.map(attributes)
        guard !records.isEmpty, records.allSatisfy({ $0 != nil }) else {
            return nil
        }
        let each = records.compactMap { $0 }
        if each.count == 1 {
            return each[0]
        }
        let dictionary = DBusSignature.ValueType.dictionary(DBusSignature.DictionaryType(key: .string, value: .variant)!)
        return ["Records": .list(of: dictionary, each.map(DBusMessageArgument.vardict))]
    }

    /// One record's fields, as neard takes them.
    static func attributes(_ record: LinuxNDEFRecord) -> [String: DBusMessageArgument]? {
        if let uri = record.uri() {
            return ["Type": .string("URI"), "URI": .string(uri)]
        }
        if let text = record.text(), let language = record.textLanguage {
            return [
                "Type": .string("Text"), "Encoding": .string("UTF-8"),
                "Language": .string(language), "Representation": .string(text),
            ]
        }
        // neard makes a Wi-Fi configuration of its own for the WSC type, out
        // of other fields.
        if record.format == .media, record.recordIdentifier.isEmpty,
           let type = String(bytes: record.recordType, encoding: .utf8), !type.isEmpty,
           type.lowercased() != "application/vnd.wfa.wsc" {
            return ["Type": .string("MIME"), "MIME": .string(type), "Payload": .byteArray(record.recordPayload)]
        }
        return nil
    }

    /// "Sp"
    static let smartPosterType: [UInt8] = [0x53, 0x70]
}
