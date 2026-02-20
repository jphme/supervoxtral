import Foundation
import ApplicationServices

enum TextInjectorError: Error {
    case accessibilityPermissionMissing
    case unableToCreateEvent
}

final class TextInjector {
    func insert(_ text: String) throws {
        guard !text.isEmpty else { return }
        guard PermissionManager.isAccessibilityTrusted(prompt: false) else {
            throw TextInjectorError.accessibilityPermissionMissing
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw TextInjectorError.unableToCreateEvent
        }

        var utf16 = Array(text.utf16)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            throw TextInjectorError.unableToCreateEvent
        }

        utf16.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            keyUp.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
