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
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
