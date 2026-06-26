import Foundation

/// Retention policy for archived WAV recordings. History *text* is kept forever; only the
/// (multi-MB) audio files are pruned.
enum AudioRetentionPolicy: Equatable {
    case keepAll
    case lastN(Int)
    case maxAgeDays(Int)
}

/// Persists recorded WAV audio as separate files under
/// `~/Library/Application Support/VoicePolish/recordings/<entryId>.wav`, keyed by the
/// owning `HistoryEntry.id`. Kept out of `history.json` (already ~1.8 MB) so the JSON stays
/// small and cheap to rewrite.
///
/// An `actor` so multi-MB reads/writes run off the MainActor. The pure path helpers
/// (`url`, `exists`) are `nonisolated` so SwiftUI bodies and `@MainActor` callers can use
/// them synchronously; everything that *mutates* the directory is actor-isolated and
/// therefore serialized (no races between `save`/`prune`/`delete`).
actor AudioStorageService {
    static let shared = AudioStorageService()
    private let logger = LoggingService.shared
    nonisolated private let directory: URL

    init() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoicePolish")
        directory = appSupport.appendingPathComponent("recordings")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// File URL for an entry's WAV (pure; no IO).
    nonisolated func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    /// Whether an entry's WAV exists (cheap stat; safe to call synchronously from SwiftUI).
    nonisolated func exists(for id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Persist WAV bytes for an entry. Returns the stored filename, or `nil` on any IO
    /// failure (disk full, permissions). `nil` is never fatal — the caller simply proceeds
    /// without an archived recording (entry gets `audioFileName == nil`, so no Retry).
    func save(_ data: Data, for id: UUID) async -> String? {
        let fileURL = url(for: id)
        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.lastPathComponent
        } catch {
            logger.error("AudioStorage: save \(id) failed - \(error)")
            await MainActor.run {
                ErrorService.shared.addError(
                    source: .general, severity: .warning,
                    message: "Could not archive recording audio",
                    details: error.localizedDescription,
                    actionable: false, transient: true, code: "audio.archive_save_failed"
                )
            }
            return nil
        }
    }

    func load(for id: UUID) -> Data? {
        try? Data(contentsOf: url(for: id))
    }

    func delete(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Prune archived audio: (1) delete orphan WAVs whose id has no live entry (covers a
    /// crash between save and entry-create); (2) apply the retention policy to the rest by
    /// file mtime (≈ record time). Only `<uuid>.wav` files are considered — any other
    /// filename is skipped, never deleted.
    func prune(policy: AudioRetentionPolicy, liveEntryIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        ) else { return }

        var survivors: [(url: URL, mtime: Date)] = []
        for f in files where f.pathExtension == "wav" {
            guard let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent) else {
                continue  // not a <uuid>.wav we manage — leave it alone
            }
            if !liveEntryIDs.contains(id) {
                try? fm.removeItem(at: f)  // orphan: no live history entry
                continue
            }
            let mtime = (try? f.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date.distantPast
            survivors.append((f, mtime))
        }

        switch policy {
        case .keepAll:
            break
        case .lastN(let n):
            for s in survivors.sorted(by: { $0.mtime > $1.mtime }).dropFirst(max(0, n)) {
                try? fm.removeItem(at: s.url)
            }
        case .maxAgeDays(let days):
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date.distantPast
            for s in survivors where s.mtime < cutoff {
                try? fm.removeItem(at: s.url)
            }
        }
    }
}
