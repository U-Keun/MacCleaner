import Foundation

public enum OutputFormatter {
    public static func sizeString(for bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = .useAll
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true

        return formatter.string(fromByteCount: bytes)
    }

    public static func makeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
