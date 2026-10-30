import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.rightBracket, modifiers: .command))
    static let cancelRecording = Self("cancelRecording", default: .init(.leftBracket, modifiers: .command))
    static let stopAndType = Self("stopAndType", default: .init(.period, modifiers: .option))

    // Optional second binding per action, unset by default. Remote-desktop clients
    // (Windows App / RDP, Citrix) often swallow a combo before macOS sees it, so a
    // spare key (e.g. F13) keeps the action reachable while that window has focus.
    static let toggleRecordingAlt = Self("toggleRecordingAlt")
    static let cancelRecordingAlt = Self("cancelRecordingAlt")
    static let stopAndTypeAlt = Self("stopAndTypeAlt")
}

/// The user-facing recording actions, each with a primary and an alternate hotkey.
/// Settings rows and the duplicate-binding check both iterate this, so the names
/// are never listed by hand twice.
enum HotkeyAction: CaseIterable {
    case record
    case discard
    case stopAndType

    var title: String {
        switch self {
        case .record: return "Record / Stop & Paste"
        case .discard: return "Discard"
        case .stopAndType: return "Stop & Type"
        }
    }

    var primary: KeyboardShortcuts.Name {
        switch self {
        case .record: return .toggleRecording
        case .discard: return .cancelRecording
        case .stopAndType: return .stopAndType
        }
    }

    var alternate: KeyboardShortcuts.Name {
        switch self {
        case .record: return .toggleRecordingAlt
        case .discard: return .cancelRecordingAlt
        case .stopAndType: return .stopAndTypeAlt
        }
    }

    var names: [KeyboardShortcuts.Name] { [primary, alternate] }

    static var allRecordingHotkeys: [KeyboardShortcuts.Name] { allCases.flatMap(\.names) }

    /// The action owning `name`, if any.
    static func action(for name: KeyboardShortcuts.Name) -> HotkeyAction? {
        allCases.first { $0.names.contains(name) }
    }

    /// Hotkeys to suspend during a keystroke typing run. Posted key events pass
    /// through Carbon hot-key matching, so a binding the run can produce would fire
    /// mid-run and swallow the typed character. Record and Stop & Type are always
    /// suspended. Discard stays live as the abort path — unless its binding is
    /// itself typable, in which case typing would abort the run.
    static var namesToSuspendWhileTyping: [KeyboardShortcuts.Name] {
        HotkeyAction.record.names + HotkeyAction.stopAndType.names + HotkeyAction.discard.names.filter {
            KeyboardShortcuts.getShortcut(for: $0).map(isReachableByTyping) ?? false
        }
    }

    private static let functionKeys: Set<KeyboardShortcuts.Key> = [
        .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10,
        .f11, .f12, .f13, .f14, .f15, .f16, .f17, .f18, .f19, .f20,
    ]

    /// The typing engine only ever posts character keys with Shift and Option, so a
    /// binding using Command or Control, or a function key, can never be produced by it.
    private static func isReachableByTyping(_ shortcut: KeyboardShortcuts.Shortcut) -> Bool {
        if !shortcut.modifiers.isDisjoint(with: [.command, .control]) { return false }
        if let key = shortcut.key, functionKeys.contains(key) { return false }
        return true
    }

    /// "⌘]" / "⌘] or F13" / nil when neither binding is set. Read on demand —
    /// shortcut storage is UserDefaults-backed and not observable.
    var shortcutsDescription: String? {
        let set = names.compactMap { KeyboardShortcuts.getShortcut(for: $0)?.description }
        return set.isEmpty ? nil : set.joined(separator: " or ")
    }
}
