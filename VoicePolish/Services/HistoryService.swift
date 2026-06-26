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
    func addEntry(id: UUID = UUID(), transcript: String, llmResponse: String? = nil,
                  audioFileName: String? = nil, status: HistoryEntry.Status = .success,
                  failureStage: HistoryEntry.FailureStage? = nil, errorMessage: String? = nil) -> UUID {
        let entry = HistoryEntry(id: id, transcript: transcript, llmResponse: llmResponse,
                                 audioFileName: audioFileName, status: status,
                                 failureStage: failureStage, errorMessage: errorMessage)
        entries.insert(entry, at: 0)
        saveToDisk()
        logger.info("History: saved \(status.rawValue) entry \(id) (\(transcript.count) transcript chars, \(llmResponse?.count ?? 0) response chars)")
        return id
    }

    /// In-place mutation helper: find by id, apply the change, persist.
    private func mutate(id: UUID, _ body: (inout HistoryEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            logger.error("History: cannot update entry \(id) — not found")
            return
        }
        body(&entries[index])
        saveToDisk()
    }

    /// LLM succeeded after a transcript-only entry: attach the response, ensure success.
    func updateEntry(id: UUID, llmResponse: String) {
        mutate(id: id) {
            $0.llmResponse = llmResponse
            $0.status = .success
            $0.failureStage = nil
            $0.errorMessage = nil
        }
        logger.info("History: updated entry \(id) with LLM response (\(llmResponse.count) chars)")
    }

    /// A retry re-ran successfully: overwrite transcript/response and clear the failure.
    func applyRetrySuccess(id: UUID, transcript: String, llmResponse: String?) {
        mutate(id: id) {
            $0.transcript = transcript
            $0.llmResponse = llmResponse
            $0.status = .success
            $0.failureStage = nil
            $0.errorMessage = nil
        }
        logger.info("History: retry succeeded for entry \(id)")
    }

    /// Mark an entry failed at a given stage (transcription or LLM), with a reason.
    func markFailed(id: UUID, stage: HistoryEntry.FailureStage, errorMessage: String) {
        mutate(id: id) {
            $0.status = .failed
            $0.failureStage = stage
            $0.errorMessage = errorMessage
        }
        logger.info("History: marked entry \(id) failed (\(stage.rawValue))")
    }

    /// Drop an entry's archived audio (e.g. a success under the failures-only save scope).
    func clearAudio(id: UUID) {
        mutate(id: id) { $0.audioFileName = nil }
        Task { await AudioStorageService.shared.delete(for: id) }
    }

    func getEntries(filter: HistoryTimeFilter) -> [HistoryEntry] {
        let cutoff = filter.cutoffDate
        return entries.filter { $0.timestamp >= cutoff }
    }

    /// Delete a single entry and its archived audio.
    func deleteEntry(id: UUID) {
        entries.removeAll { $0.id == id }
        saveToDisk()
        Task { await AudioStorageService.shared.delete(for: id) }
        logger.info("History: deleted entry \(id) + audio")
    }

    func clearAll() {
        entries.removeAll()
        saveToDisk()
        Task { await AudioStorageService.shared.deleteAll() }
        logger.info("History: cleared all entries + audio")
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
            ErrorService.shared.addError(
                source: .general, severity: .error,
                message: "Failed to load history from disk",
                details: error.localizedDescription,
                code: "history.load_failed"
            )
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
            ErrorService.shared.addError(
                source: .general, severity: .error,
                message: "Failed to save history to disk",
                details: error.localizedDescription,
                code: "history.save_failed"
            )
        }
    }
}
