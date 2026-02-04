import XCTest
@testable import VoicePolish

final class PermissionManagerTests: XCTestCase {
    var permissionManager: PermissionManager!

    override func setUp() {
        super.setUp()
        permissionManager = PermissionManager()
    }

    override func tearDown() {
        permissionManager = nil
        super.tearDown()
    }

    // MARK: - Permission Check Tests

    func testPermissionManagerInitialization() {
        XCTAssertNotNil(permissionManager, "Permission manager should initialize")
    }

    func testCheckMicrophonePermission() {
        // Should not crash when checking permission
        XCTAssertNoThrow(permissionManager.checkMicrophonePermission())
    }

    func testCheckAndRequestPermissions() {
        // Should not crash when checking and requesting permissions
        XCTAssertNoThrow(permissionManager.checkAndRequestPermissions())
    }

    // MARK: - Mock Permission Manager Tests

    func testMockPermissionManagerMicrophoneGranted() {
        let mockManager = MockPermissionManager()
        mockManager.microphonePermissionGranted = true

        XCTAssertTrue(mockManager.microphonePermissionGranted)
    }

    func testMockPermissionManagerAccessibilityGranted() {
        let mockManager = MockPermissionManager()
        mockManager.accessibilityPermissionGranted = true

        XCTAssertTrue(mockManager.accessibilityPermissionGranted)
    }

    func testMockPermissionManagerCheckCalled() {
        let mockManager = MockPermissionManager()
        XCTAssertFalse(mockManager.checkMicrophoneCalled)

        mockManager.checkMicrophonePermission()
        XCTAssertTrue(mockManager.checkMicrophoneCalled)
    }

    func testMockPermissionManagerRequestCalled() {
        let mockManager = MockPermissionManager()
        XCTAssertFalse(mockManager.requestMicrophoneCalled)

        mockManager.checkAndRequestPermissions()
        XCTAssertTrue(mockManager.requestMicrophoneCalled)
    }

    func testMockPermissionManagerBothPermissions() {
        let mockManager = MockPermissionManager()
        mockManager.microphonePermissionGranted = true
        mockManager.accessibilityPermissionGranted = true

        XCTAssertTrue(mockManager.microphonePermissionGranted && mockManager.accessibilityPermissionGranted)
    }
}
