import AppKit

/// Remembers the last app other than VoicePolish that was frontmost.
///
/// Clicking the menubar window activates VoicePolish itself, so a recording
/// started from the menubar control bar would otherwise capture *us* as the
/// paste target (`NSWorkspace.frontmostApplication` at popup-open time) and
/// deliver the result nowhere. The popup falls back to `lastExternalApp` when
/// the frontmost app is our own process.
@MainActor
final class FrontmostAppTracker {
    static let shared = FrontmostAppTracker()

    private(set) var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        if let front = NSWorkspace.shared.frontmostApplication, !Self.isSelf(front) {
            lastExternalApp = front
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !Self.isSelf(app) else { return }
            MainActor.assumeIsolated {
                self?.lastExternalApp = app
            }
        }
    }

    nonisolated static func isSelf(_ app: NSRunningApplication) -> Bool {
        app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}
