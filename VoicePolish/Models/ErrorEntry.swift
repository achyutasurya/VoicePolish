import Foundation

struct ErrorEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let source: ErrorSource
    let severity: ErrorSeverity
    let message: String
    let details: String?
    /// Whether the user should see and act on this entry. `false` means log-only —
    /// the entry is persisted for operator triage but hidden from the default UI.
    let actionable: Bool
    /// Whether this represents a transient condition that auto-recovered (e.g.,
    /// audio engine recovered via the backoff ladder, single Deepgram retry).
    /// Transient entries are folded into summary rows in the UI.
    let transient: Bool
    /// Upstream provider request ID (Deepgram `dg-request-id`, OpenRouter
    /// `X-Generation-Id`) so users can paste it into support tickets.
    let requestId: String?
    /// Stable grouping key, e.g. `audio.engine.recovered`. Drives summary
    /// grouping in the UI when many transient entries share the same code.
    let code: String?

    init(source: ErrorSource, severity: ErrorSeverity, message: String,
         details: String? = nil, actionable: Bool = true, transient: Bool = false,
         requestId: String? = nil, code: String? = nil) {
        self.id = UUID()
        self.timestamp = Date()
        self.source = source
        self.severity = severity
        self.message = message
        self.details = details
        self.actionable = actionable
        self.transient = transient
        self.requestId = requestId
        self.code = code
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, source, severity, message, details
        case actionable, transient, requestId, code
    }

    // Custom decoder so older entries written before v0.3.14 (no actionable/transient/etc.
    // fields) still load with sensible defaults instead of failing the whole file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.source = try c.decode(ErrorSource.self, forKey: .source)
        self.severity = try c.decode(ErrorSeverity.self, forKey: .severity)
        self.message = try c.decode(String.self, forKey: .message)
        self.details = try c.decodeIfPresent(String.self, forKey: .details)
        self.actionable = try c.decodeIfPresent(Bool.self, forKey: .actionable) ?? true
        self.transient = try c.decodeIfPresent(Bool.self, forKey: .transient) ?? false
        self.requestId = try c.decodeIfPresent(String.self, forKey: .requestId)
        self.code = try c.decodeIfPresent(String.self, forKey: .code)
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
