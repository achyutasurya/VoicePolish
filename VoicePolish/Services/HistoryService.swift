import Foundation

@MainActor
@Observable
final class HistoryService {
    static let shared = HistoryService()

    private let logger = LoggingService.shared
    private let fileURL: URL
    private(set) var entries: [HistoryEntry] = []

    private init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoicePolish")
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )
        fileURL = appSupport.appendingPathComponent("history.json")
        loadFromDisk()
    }

    // MARK: - Public API

    @discardableResult
    func addEntry(transcript: String, llmResponse: String? = nil) -> UUID {
        let entry = HistoryEntry(transcript: transcript, llmResponse: llmResponse)
        entries.insert(entry, at: 0)
        saveToDisk()
        logger.info("History: saved entry (\(transcript.count) transcript chars, \(llmResponse?.count ?? 0) response chars)")
        return entry.id
    }

    func updateEntry(id: UUID, llmResponse: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            logger.error("History: cannot update entry \(id) — not found")
            return
        }
        entries[index].llmResponse = llmResponse
        saveToDisk()
        logger.info("History: updated entry \(id) with LLM response (\(llmResponse.count) chars)")
    }

    func getEntries(filter: HistoryTimeFilter) -> [HistoryEntry] {
        let cutoff = filter.cutoffDate
        return entries.filter { $0.timestamp >= cutoff }
    }

    func clearAll() {
        entries.removeAll()
        saveToDisk()
        logger.info("History: cleared all entries")
    }

    // MARK: - Disk I/O

    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([HistoryEntry].self, from: data)
            logger.info("History: loaded \(entries.count) entries from disk")
        } catch {
            logger.error("History: failed to load - \(error)")
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
            logger.error("History: failed to save - \(error)")
        }
    }
}
