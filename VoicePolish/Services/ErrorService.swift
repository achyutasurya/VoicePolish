import Foundation

@MainActor
@Observable
final class ErrorService {
    static let shared = ErrorService()

    private let logger = LoggingService.shared
    private let fileURL: URL
    private(set) var entries: [ErrorEntry] = []
    private let maxEntries = 200

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoicePolish")
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        fileURL = appSupport.appendingPathComponent("errors.json")
        loadFromDisk()
    }

    // MARK: - Public API

    func addError(source: ErrorEntry.ErrorSource, severity: ErrorEntry.ErrorSeverity,
                  message: String, details: String? = nil) {
        let entry = ErrorEntry(source: source, severity: severity, message: message, details: details)
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        saveToDisk()
        logger.info("ErrorService: recorded \(severity.rawValue) from \(source.rawValue): \(message)")
    }

    func getEntries(filter: HistoryTimeFilter) -> [ErrorEntry] {
        let cutoff = filter.cutoffDate
        return entries.filter { $0.timestamp >= cutoff }
    }

    func clearAll() {
        entries.removeAll()
        saveToDisk()
        logger.info("ErrorService: cleared all entries")
    }

    var hasRecentErrors: Bool {
        guard let oneHourAgo = Calendar.current.date(byAdding: .hour, value: -1, to: Date()) else {
            return false
        }
        return entries.contains { $0.timestamp >= oneHourAgo }
    }

    // MARK: - Disk I/O

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([ErrorEntry].self, from: data)
            logger.info("ErrorService: loaded \(entries.count) entries from disk")
        } catch {
            logger.error("ErrorService: failed to load - \(error)")
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("ErrorService: failed to save - \(error)")
        }
    }
}
