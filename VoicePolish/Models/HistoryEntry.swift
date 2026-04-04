import Foundation

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let transcript: String
    let llmResponse: String

    init(transcript: String, llmResponse: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.transcript = transcript
        self.llmResponse = llmResponse
    }
}
