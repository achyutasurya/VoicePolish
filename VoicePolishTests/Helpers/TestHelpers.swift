import Foundation

/// Common test utilities and helpers
class TestHelpers {
    /// Create a temporary test audio file URL
    static func createTestAudioFileURL() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        return tempDir.appendingPathComponent("test_audio_\(UUID().uuidString).wav")
    }

    /// Wait for a condition to be true, with timeout
    static func waitForCondition(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 5.0,
        message: String = "Condition not met"
    ) throws {
        let startTime = Date()
        while !condition() {
            if Date().timeIntervalSince(startTime) > timeout {
                XCTFail("\(message) (timeout after \(timeout)s)")
                throw NSError(domain: "TestHelpers", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
    }

    /// Clean up test audio files
    static func cleanupTestFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let fm = FileManager.default

        do {
            let files = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            for file in files where file.lastPathComponent.hasPrefix("test_audio_") {
                try fm.removeItem(at: file)
            }
        } catch {
            print("Failed to cleanup test files: \(error)")
        }
    }

    /// Create a mock audio file with given duration
    static func createMockAudioFile(duration: TimeInterval) -> URL? {
        let url = createTestAudioFileURL()

        // Simple WAV header for 1-second mono audio at 44.1kHz
        var wavData = Data()

        // RIFF header
        wavData.append("RIFF".data(using: .utf8)!)
        var fileSize: UInt32 = 36 + 44100 * 2 // Placeholder
        wavData.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        wavData.append("WAVE".data(using: .utf8)!)

        // fmt subchunk
        wavData.append("fmt ".data(using: .utf8)!)
        let subchunk1Size: UInt32 = 16
        wavData.append(withUnsafeBytes(of: subchunk1Size.littleEndian) { Data($0) })
        let audioFormat: UInt16 = 1 // PCM
        wavData.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        let numChannels: UInt16 = 1
        wavData.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        let sampleRate: UInt32 = 44100
        wavData.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        let byteRate: UInt32 = 44100 * 2
        wavData.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        let blockAlign: UInt16 = 2
        wavData.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        let bitsPerSample: UInt16 = 16
        wavData.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })

        // data subchunk
        wavData.append("data".data(using: .utf8)!)
        let numSamples = Int(44100 * duration)
        let subchunk2Size: UInt32 = UInt32(numSamples * 2)
        wavData.append(withUnsafeBytes(of: subchunk2Size.littleEndian) { Data($0) })

        // Add silent audio data
        for _ in 0..<numSamples {
            let sample: Int16 = 0
            wavData.append(withUnsafeBytes(of: sample.littleEndian) { Data($0) })
        }

        do {
            try wavData.write(to: url)
            return url
        } catch {
            print("Failed to create mock audio file: \(error)")
            return nil
        }
    }
}
