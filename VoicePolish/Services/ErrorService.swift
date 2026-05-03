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

    /// Record an error/warning. Defaults preserve pre-v0.3.14 behaviour
    /// (`actionable: true`, `transient: false`) so existing call sites need no edits.
    func addError(source: ErrorEntry.ErrorSource, severity: ErrorEntry.ErrorSeverity,
                  message: String, details: String? = nil,
                  actionable: Bool = true, transient: Bool = false,
                  requestId: String? = nil, code: String? = nil) {
        let entry = ErrorEntry(source: source, severity: severity, message: message,
                               details: details, actionable: actionable, transient: transient,
                               requestId: requestId, code: code)
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

    /// Returns entries within the time window split into actionable rows and
    /// transient summary groups. Drives the Errors tab UI grouping (P0 #4).
    func getDisplayEntries(filter: HistoryTimeFilter) -> (actionable: [ErrorEntry], transientGroups: [TransientGroup]) {
        let entries = getEntries(filter: filter)
        let actionable = entries.filter { $0.actionable && !$0.transient }
        let transient = entries.filter { $0.transient || !$0.actionable }
        let groups = Dictionary(grouping: transient) { entry -> String in
            entry.code ?? "\(entry.source.rawValue)|\(entry.message)"
        }
        let transientGroups = groups.map { (key, items) -> TransientGroup in
            let sorted = items.sorted { $0.timestamp > $1.timestamp }
            return TransientGroup(
                key: key,
                source: sorted.first!.source,
                severity: sorted.first!.severity,
                title: sorted.first!.message,
                count: sorted.count,
                latest: sorted.first!.timestamp,
                entries: sorted
            )
        }
        .sorted { $0.latest > $1.latest }
        return (actionable, transientGroups)
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
        return entries.contains { $0.timestamp >= oneHourAgo && $0.actionable && !$0.transient }
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
            // Console-only on purpose: re-routing this through addError() would
            // recurse if the storage layer itself is the failure mode.
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
            // Console-only on purpose — see loadFromDisk() comment.
            logger.error("ErrorService: failed to save - \(error)")
        }
    }
}

/// Grouping struct surfaced by ``ErrorService/getDisplayEntries(filter:)``.
struct TransientGroup: Identifiable {
    let key: String
    let source: ErrorEntry.ErrorSource
    let severity: ErrorEntry.ErrorSeverity
    let title: String
    let count: Int
    let latest: Date
    let entries: [ErrorEntry]
    var id: String { key }
}
