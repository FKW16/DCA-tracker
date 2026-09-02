import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct LedgerRecord: Codable, Equatable, Identifiable {
    let id: UUID; let type: String; let date: Date; let symbol: String; let account: String
    var accountID: UUID? = nil
    let quantity: Decimal?; let price: Decimal?; let amount: Decimal; let tags: [String]; let note: String
}
struct BackupEnvelope: Codable, Equatable { static let currentVersion = 1; let version: Int; let createdAt: Date; let records: [LedgerRecord] }
enum BackupError: Error, Equatable { case unsupportedVersion(Int), invalidData }

enum ExportService {
    static func csv(_ records: [LedgerRecord]) -> Data {
        var rows = ["type,date,symbol,account,quantity,price,amount,tags,note"]
        let formatter = ISO8601DateFormatter()
        rows += records.map { record in
            [record.type, formatter.string(from: record.date), record.symbol, record.account,
             record.quantity.map(String.init(describing:)) ?? "", record.price.map(String.init(describing:)) ?? "",
             String(describing: record.amount), record.tags.joined(separator: "|"), record.note].map(escapeCSV).joined(separator: ",")
        }
        return Data(rows.joined(separator: "\n").utf8)
    }
    static func backup(_ records: [LedgerRecord], date: Date = Date()) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(BackupEnvelope(version: BackupEnvelope.currentVersion, createdAt: date, records: records))
    }
    static func validateAndDecode(_ data: Data) throws -> BackupEnvelope {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(BackupEnvelope.self, from: data) else { throw BackupError.invalidData }
        guard value.version == BackupEnvelope.currentVersion else { throw BackupError.unsupportedVersion(value.version) }; return value
    }
    static func safetyCopy(of data: Data, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("DCA-Tracker-before-restore-\(UUID().uuidString).json")
        try data.write(to: url, options: [.atomic]); return url
    }
    private static func escapeCSV(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .plainText] }
    var data: Data
    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}
