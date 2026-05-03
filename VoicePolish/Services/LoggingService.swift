import Foundation
import OSLog

final class LoggingService: @unchecked Sendable {
    static let shared = LoggingService()

    private let osLogger = Logger(subsystem: "com.voicepolish.app", category: "general")
    private let logDirectoryURL: URL
    private let queue = DispatchQueue(label: "com.voicepolish.logging", qos: .utility)

    init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        logDirectoryURL = homeDir.appendingPathComponent("Library/Logs/VoicePolish")

        try? FileManager.default.createDirectory(
            at: logDirectoryURL,
            withIntermediateDirectories: true
        )

        // P2 cross-cutting C (v0.3.24): rotate logs older than 90 days at app
        // start. Pre-v0.3.24 the only retention was macOS's own (none); older
        // files appeared to be cleared eventually by the OS, leaving us with
        // only ~11 days of historical comparison data. 90 days lets us compare
        // current error rate against the previous month's baseline.
        cleanupOldLogs(olderThanDays: 90)
    }

    /// Deletes `voicepolish-*.log` files in `logDirectoryURL` whose
    /// modification date is older than `olderThanDays`. Runs at init on the
    /// MainActor (cheap directory scan, normally <50 files).
    private func cleanupOldLogs(olderThanDays: Int) {
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: logDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        var deletedCount = 0
        for url in files where url.pathExtension == "log" {
            guard
                let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let mtime = attrs.contentModificationDate,
                mtime < cutoff
            else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                deletedCount += 1
            }
        }

        if deletedCount > 0 {
            info("Log retention: deleted \(deletedCount) log file(s) older than \(olderThanDays) days")
        }
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        writeToFile("INFO", message)
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        writeToFile("ERROR", message)
    }

    func debug(_ message: String) {
        osLogger.debug("\(message, privacy: .public)")
        writeToFile("DEBUG", message)
    }

    /// Structured log for API calls with HTTP details, timing, and rate-limit headers
    func apiCall(
        service: String,
        endpoint: String,
        method: String,
        requestSize: Int,
        statusCode: Int?,
        responseSize: Int?,
        duration: TimeInterval,
        headers: [AnyHashable: Any]? = nil,
        error: String? = nil
    ) {
        var parts: [String] = []
        parts.append("[\(service)] \(method) \(endpoint)")
        parts.append("request: \(formatBytes(requestSize))")
        if let code = statusCode {
            parts.append("status: \(code)")
        }
        if let size = responseSize {
            parts.append("response: \(formatBytes(size))")
        }
        parts.append("duration: \(String(format: "%.1fms", duration * 1000))")

        if let headers {
            let rateLimitKeys = ["x-ratelimit-remaining", "x-ratelimit-limit", "x-ratelimit-reset", "retry-after"]
            for key in rateLimitKeys {
                if let value = headers[key] ?? headers[key.capitalized] {
                    parts.append("\(key): \(value)")
                }
            }
        }

        let message = parts.joined(separator: " | ")
        if let error {
            self.error("\(message) | error: \(error)")
        } else {
            info(message)
        }
    }

    /// Log pipeline step timing
    func pipelineStep(_ step: String, duration: TimeInterval) {
        info("Pipeline: \(step) completed in \(String(format: "%.1fms", duration * 1000))")
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024.0) }
        return String(format: "%.1fMB", Double(bytes) / (1024.0 * 1024.0))
    }

    private func writeToFile(_ level: String, _ message: String) {
        queue.async { [logDirectoryURL] in
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateString = dateFormatter.string(from: Date())
            let fileURL = logDirectoryURL.appendingPathComponent("voicepolish-\(dateString).log")

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "HH:mm:ss.SSS"
            let timestamp = timeFormatter.string(from: Date())

            let line = "[\(timestamp)] [\(level)] \(message)\n"

            guard let data = line.data(using: .utf8) else { return }

            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    defer { handle.closeFile() }
                    handle.seekToEndOfFile()
                    handle.write(data)
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
