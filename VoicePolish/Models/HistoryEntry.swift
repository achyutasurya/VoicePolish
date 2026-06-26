import Foundation

struct HistoryEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var transcript: String            // var: a retry may re-transcribe and overwrite this
    var llmResponse: String?
    var audioFileName: String?        // "<id>.wav" under recordings/, or nil (not archived / pruned)
    var status: Status                // default .success — needs the custom decoder below
    var failureStage: FailureStage?   // .transcription vs .llm — drives the retry path
    var errorMessage: String?         // user-facing failure reason shown on the failed card

    enum Status: String, Codable { case success, failed }
    enum FailureStage: String, Codable { case transcription, llm }

    init(id: UUID = UUID(), transcript: String, llmResponse: String? = nil,
         audioFileName: String? = nil, status: Status = .success,
         failureStage: FailureStage? = nil, errorMessage: String? = nil) {
        self.id = id
        self.timestamp = Date()
        self.transcript = transcript
        self.llmResponse = llmResponse
        self.audioFileName = audioFileName
        self.status = status
        self.failureStage = failureStage
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, transcript, llmResponse, audioFileName, status, failureStage, errorMessage
    }

    // Custom decoder mirroring ErrorEntry.swift: the thousands of pre-0.3.30 entries on
    // disk lack the new keys, and a non-optional `status` with a default does NOT receive
    // that default from synthesized decoding — so decodeIfPresent + defaults is mandatory
    // to keep the existing history.json loading instead of failing the whole file.
    // (No custom encode(to:) is needed — Swift still synthesizes the encoder.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        transcript = try c.decode(String.self, forKey: .transcript)
        llmResponse = try c.decodeIfPresent(String.self, forKey: .llmResponse)
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .success
        failureStage = try c.decodeIfPresent(FailureStage.self, forKey: .failureStage)
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}
