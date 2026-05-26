import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.rightBracket, modifiers: .command))
    static let cancelRecording = Self("cancelRecording", default: .init(.leftBracket, modifiers: .command))
    static let stopAndType = Self("stopAndType", default: .init(.period, modifiers: .option))
}
