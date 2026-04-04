import Foundation

struct ErrorEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let source: ErrorSource
    let severity: ErrorSeverity
    let message: String
    let details: String?

    init(source: ErrorSource, severity: ErrorSeverity, message: String, details: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.source = source
        self.severity = severity
        self.message = message
        self.details = details
    }

    enum ErrorSource: String, Codable, CaseIterable {
        case deepgram = "Deepgram"
        case openRouter = "OpenRouter"
        case audioRecorder = "Audio"
        case textInsertion = "Paste"
        case general = "General"
    }

    enum ErrorSeverity: String, Codable, CaseIterable {
        case warning = "Warning"
        case error = "Error"
        case critical = "Critical"
    }
}
