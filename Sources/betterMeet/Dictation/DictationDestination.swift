import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Preserve the original app/window and every field attribute the editor exposes.
/// Custom editors can accept Paste without implementing AXValue/AXSelectedTextRange.
@MainActor
struct DictationDestination {
    enum InsertionResult { case inserted, copyRequired, unconfirmed }
    let pid: pid_t
    let window: AXUIElement
    let element: AXUIElement?
    let textState: DictationTextState
    let bundleID: String

    static func capture() -> DictationDestination? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else { return nil }
        let application = applicationElement(pid: app.processIdentifier)
        // Chromium/Electron can expose only a stub until an AX client asks for
        // the full tree. This enables their accessibility tree, not an OS grant.
        for name in ["AXManualAccessibility", "AXEnhancedUserInterface"] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(application, name as CFString, &settable) == .success,
               settable.boolValue,
               AXUIElementSetAttributeValue(application, name as CFString, kCFBooleanTrue) == .success {
                break
            }
        }
        guard let window = elementAttribute(application, kAXFocusedWindowAttribute) else {
            diagnostic("capture=no_window", app: app.bundleIdentifier)
            return nil
        }
        let element = elementAttribute(application, kAXFocusedUIElementAttribute)
        guard !isSecure(element) else { return nil }
        let state = readTextState(element)
        diagnostic("capture=ready value=\(state.value != nil) selection=\(state.selection != nil) field=\(element != nil)",
                   app: app.bundleIdentifier)
        return Self(pid: app.processIdentifier, window: window, element: element, textState: state,
                    bundleID: app.bundleIdentifier ?? "")
    }

    func isUnchanged() -> Bool {
        rejectionReason() == nil
    }

    func rejectionReason() -> String? {
        guard AXIsProcessTrusted() else { return "permission_denied" }
        guard !IsSecureEventInputEnabled() else { return "secure_input" }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return "app_changed" }
        let application = Self.applicationElement(pid: pid)
        guard let currentWindow = Self.elementAttribute(application, kAXFocusedWindowAttribute),
              CFEqual(window, currentWindow) else { return "window_changed" }
        let focused = Self.elementAttribute(application, kAXFocusedUIElementAttribute)
        guard !Self.isSecure(focused) else { return "secure_field" }
        if let element {
            guard let focused, CFEqual(element, focused) else { return "field_changed" }
        }
        return textState.matches(Self.readTextState(focused)) ? nil : "text_or_selection_changed"
    }

    /// Prefer targeted AX replacement. Editors that reject it can accept a
    /// guarded, process-targeted paste; no Enter key is ever synthesized.
    func insert(_ text: String) async -> InsertionResult {
        guard !text.isEmpty, isUnchanged() else {
            Self.diagnostic("insert=destination_changed", app: bundleID)
            return .copyRequired
        }
        // Never inject commands/newlines into terminals or secure applications.
        guard !["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty"]
            .contains(bundleID) else { return .copyRequired }
        var settable = DarwinBoolean(false)
        let expected = textState.expectedValue(inserting: text)
        if let element, expected != nil,
           AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
           settable.boolValue,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success {
            return .inserted
        }
        guard isUnchanged(),
              let saved = DictationClipboard.capture(),
              let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false),
              isUnchanged() else { return .copyRequired }
        let board = NSPasteboard.general
        guard board.changeCount == saved.changeCount else { return .copyRequired }
        board.clearContents()
        guard board.setString(text, forType: .string) else {
            saved.restore(ifUnchangedSince: board.changeCount)
            return .copyRequired
        }
        let ownedChange = board.changeCount
        guard isUnchanged() else {
            saved.restore(ifUnchangedSince: ownedChange)
            return .copyRequired
        }
        down.flags = .maskCommand
        up.flags = []
        down.postToPid(pid)
        up.postToPid(pid)
        // Restore only after observing the paste in the destination, never on
        // a blind timer that could replace the clipboard before the editor reads it.
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(50))
            let currentElement = Self.elementAttribute(Self.applicationElement(pid: pid), kAXFocusedUIElementAttribute)
            let currentValue = currentElement.flatMap { Self.string($0, kAXValueAttribute) }
            if textState.confirmsInsertion(text, currentValue: currentValue) {
                saved.restore(ifUnchangedSince: ownedChange)
                return .inserted
            }
        }
        // Keep the dictated text available if the app did not acknowledge paste.
        return .unconfirmed
    }

    nonisolated static func replacement(in original: String, range: CFRange, text: String) -> String? {
        let value = original as NSString
        guard range.location >= 0, range.length >= 0,
              range.location <= value.length, range.length <= value.length - range.location else { return nil }
        return value.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }

    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func applicationElement(pid: pid_t) -> AXUIElement {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        return application
    }

    private static func elementAttribute(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.2)
        return element
    }

    private static func isSecure(_ element: AXUIElement?) -> Bool {
        guard let element else { return false }
        return string(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
    }

    private static func readTextState(_ element: AXUIElement?) -> DictationTextState {
        guard let element else { return DictationTextState() }
        let range = selectedRange(element)
        return DictationTextState(value: string(element, kAXValueAttribute),
                                  selection: range.map { .init(location: $0.location, length: $0.length) })
    }

    private static func diagnostic(_ message: String, app: String?) {
        // Attribute availability and app identity only, never text or clipboard contents.
        FileHandle.standardError.write(Data("dictation destination: \(message) app=\(app ?? "unknown")\n".utf8))
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }
}

struct DictationTextState: Equatable, Sendable {
    struct Selection: Equatable, Sendable {
        let location: Int
        let length: Int
    }
    var value: String?
    var selection: Selection?

    /// Missing optional AX attributes are not evidence that the cursor moved.
    /// Attributes known at capture time must still match at insertion time.
    func matches(_ current: DictationTextState) -> Bool {
        if let value, current.value != value { return false }
        if let selection, current.selection != selection { return false }
        return true
    }

    func expectedValue(inserting text: String) -> String? {
        guard let value, let selection else { return nil }
        return DictationDestination.replacement(in: value,
                                               range: CFRange(location: selection.location, length: selection.length),
                                               text: text)
    }

    func confirmsInsertion(_ text: String, currentValue: String?) -> Bool {
        guard let currentValue else { return false }
        if let expected = expectedValue(inserting: text) { return currentValue == expected }
        guard let value else { return false }
        return currentValue != value && currentValue.contains(text)
    }
}

@MainActor
struct DictationClipboard {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from board: NSPasteboard = .general) -> DictationClipboard? {
        let count = board.changeCount
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        var bytes = 0
        for item in board.pasteboardItems ?? [] {
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                bytes += data.count
                guard bytes <= 4 * 1024 * 1024 else { return nil }
                copy[type] = data
            }
            items.append(copy)
        }
        guard board.changeCount == count else { return nil }
        return Self(changeCount: count, items: items)
    }

    func restore(on board: NSPasteboard = .general, ifUnchangedSince count: Int) {
        guard board.changeCount == count else { return }
        let restored = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        board.clearContents()
        if !restored.isEmpty { board.writeObjects(restored) }
    }
}
