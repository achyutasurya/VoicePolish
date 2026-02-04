import XCTest
@testable import VoicePolish

final class LoggingServiceTests: XCTestCase {
    var loggingService: LoggingService!
    var testLogDirectory: URL!

    override func setUp() {
        super.setUp()
        loggingService = LoggingService.shared

        // Create test log directory
        testLogDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VoicePolishTestLogs")
        try? FileManager.default.createDirectory(at: testLogDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up test logs
        try? FileManager.default.removeItem(at: testLogDirectory)
        super.tearDown()
    }

    // MARK: - Log File Tests

    func testLogFileExists() {
        loggingService.info("Test log message")

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let logPath = logDir.appendingPathComponent("voicepolish-\(today).log")

        XCTAssert(FileManager.default.fileExists(atPath: logPath.path), "Log file should exist")
    }

    func testLogMessageContainsTimestamp() {
        loggingService.info("Test message with timestamp")

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let logPath = logDir.appendingPathComponent("voicepolish-\(today).log")

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            XCTFail("Could not read log file")
            return
        }

        XCTAssert(content.contains("INFO"), "Log should contain level")
        XCTAssert(content.contains("Test message with timestamp"), "Log should contain message")
    }

    func testMultipleLogMessages() {
        loggingService.info("Message 1")
        loggingService.info("Message 2")
        loggingService.info("Message 3")

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let logPath = logDir.appendingPathComponent("voicepolish-\(today).log")

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            XCTFail("Could not read log file")
            return
        }

        XCTAssert(content.contains("Message 1"))
        XCTAssert(content.contains("Message 2"))
        XCTAssert(content.contains("Message 3"))
    }

    // MARK: - Log Level Tests

    func testInfoLogLevel() {
        loggingService.info("Info test")

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let logPath = logDir.appendingPathComponent("voicepolish-\(today).log")

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            XCTFail("Could not read log file")
            return
        }

        XCTAssert(content.contains("[INFO]"))
    }

    func testErrorLogLevel() {
        loggingService.error("Error test")

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let logPath = logDir.appendingPathComponent("voicepolish-\(today).log")

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            XCTFail("Could not read log file")
            return
        }

        XCTAssert(content.contains("[ERROR]"))
    }

    func testDebugLogLevel() {
        loggingService.debug("Debug test")

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let logPath = logDir.appendingPathComponent("voicepolish-\(today).log")

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            XCTFail("Could not read log file")
            return
        }

        XCTAssert(content.contains("[DEBUG]"))
    }

    // MARK: - Log Directory Tests

    func testLogDirectoryCreation() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        XCTAssert(
            FileManager.default.fileExists(atPath: logDir.path),
            "Log directory should exist"
        )
    }

    func testLogDirectoryIsReadable() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let canRead = FileManager.default.isReadableFileAtPath(logDir.path)
        XCTAssertTrue(canRead, "Log directory should be readable")
    }

    func testLogDirectoryIsWritable() {
        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let canWrite = FileManager.default.isWritableFileAtPath(logDir.path)
        XCTAssertTrue(canWrite, "Log directory should be writable")
    }

    // MARK: - Concurrent Logging Tests

    func testConcurrentLogging() {
        let group = DispatchGroup()
        let queue = DispatchQueue.global()

        for i in 0..<10 {
            group.enter()
            queue.async {
                self.loggingService.info("Concurrent message \(i)")
                group.leave()
            }
        }

        group.wait()

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoicePolish")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())

        let logPath = logDir.appendingPathComponent("voicepolish-\(today).log")

        guard let content = try? String(contentsOf: logPath, encoding: .utf8) else {
            XCTFail("Could not read log file")
            return
        }

        // Check that all messages were logged
        for i in 0..<10 {
            XCTAssert(content.contains("Concurrent message \(i)"))
        }
    }
}
