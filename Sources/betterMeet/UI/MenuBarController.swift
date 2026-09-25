import AppKit
import Carbon.HIToolbox

/// Right Option starts dictation and a second press stops it. Holding it long
/// enough behaves as push-to-talk: releasing it stops dictation.
enum DictationShortcut {
    static let holdThreshold: TimeInterval = 1.0

    static func shouldStopOnRelease(elapsed: TimeInterval, state: DictationState) -> Bool {
        elapsed >= holdThreshold && (state == .listening || state == .preparing)
    }
}

/// Menu-item row that draws the item title on the left and a fixed shortcut
/// string right-aligned, mirroring how AppKit renders key equivalents
/// (including the accent-color highlight). Used for both global-shortcut
/// rows so their shortcut styling matches exactly — NSMenuItem's own
/// keyEquivalent can only render a single glyph, and macOS has no glyph
/// for the right-Option key, while dark-mode vibrancy makes matching the
/// native grey with a custom color unreliable.
/// The row reads the current title and enabled state from its item so the
/// controller can keep driving it through NSMenuItem.title as before.
private final class ShortcutRowView: NSView {
    private unowned let item: NSMenuItem
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel: NSTextField
    private var highlighted = false {
        didSet { syncLabels() }
    }

    init(item: NSMenuItem, shortcut: String) {
        self.item = item
        self.shortcutLabel = NSTextField(labelWithString: shortcut)
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        for label in [titleLabel, shortcutLabel] {
            label.font = NSFont.menuFont(ofSize: 0)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingAnchor.constraint(equalTo: shortcutLabel.trailingAnchor, constant: 15),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        syncLabels()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    func syncLabels() {
        titleLabel.stringValue = item.title
        let active = item.isEnabled && highlighted
        titleLabel.textColor = active ? .white
            : (item.isEnabled ? .labelColor : .disabledControlTextColor)
        // Native key equivalents render the text color at ~50% alpha
        // (measured RGB 130 on the dark menu background, vs 176 for titles).
        shortcutLabel.textColor = active ? .white
            : NSColor.labelColor.withAlphaComponent(item.isEnabled ? 0.5 : 0.25)
        let needed = titleLabel.intrinsicContentSize.width
            + shortcutLabel.intrinsicContentSize.width + 30
        if frame.width < needed { frame.size.width = needed }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted, item.isEnabled {
            NSColor.controlAccentColor.setFill()
            dirtyRect.fill()
        }
    }

    override func mouseEntered(with event: NSEvent) { highlighted = true }
    override func mouseExited(with event: NSEvent) { highlighted = false }

    override func mouseUp(with event: NSEvent) {
        guard highlighted, item.isEnabled, let action = item.action else { return }
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }
}

/// Status bar item in the top-right of the menu bar. The icon shows closed
/// eyes while idle and open eyes while recording so the capture state is
/// visible at a glance. The menu provides the daemon's only persistent control
/// surface (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let dictationItem: NSMenuItem
    private let cancelDictationItem: NSMenuItem
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var dictationEventTap: CFMachPort?
    private var dictationTapRunSource: CFRunLoopSource?
    private var recording = false
    private var elapsed: String?
    private var dictation = DictationState.idle
    private var heldHotKeys: Set<UInt32> = []
    private var dictationKeyPressDate: Date?
    private var dictationShortcutAvailable = true
    /// Retries the event tap while permission is missing, so granting it in
    /// System Settings takes effect without restarting the daemon.
    private var dictationTapRetry: Timer?
    private weak var recordingRow: ShortcutRowView?
    private weak var dictationRow: ShortcutRowView?

    var onToggle: (() -> Void)? {
        didSet { refresh() }
    }
    var onDictation: (() -> Void)? { didSet { refresh() } }
    var onCancelDictation: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: ""
        )
        toggleItem.isEnabled = false
        // The global Control+Option+R registration handles the shortcut; the
        // custom row only displays it so it matches the dictation row exactly.
        let recordingRow = ShortcutRowView(item: toggleItem, shortcut: "⌃⌥R")
        toggleItem.view = recordingRow
        self.recordingRow = recordingRow
        menu.addItem(toggleItem)

        dictationItem = NSMenuItem(
            title: "Start dictation", action: #selector(dictationClicked),
            keyEquivalent: ""
        )
        dictationItem.isEnabled = false
        let dictationRow = ShortcutRowView(item: dictationItem, shortcut: "Right ⌥")
        dictationItem.view = dictationRow
        self.dictationRow = dictationRow
        menu.addItem(dictationItem)
        cancelDictationItem = NSMenuItem(title: "Cancel dictation", action: #selector(cancelDictationClicked),
                                        keyEquivalent: "")
        cancelDictationItem.isHidden = true
        menu.addItem(cancelDictationItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: ""
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit betterMeet",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, dictationItem, cancelDictationItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.eyesClosedImage()
            button.imagePosition = .imageLeft
        }

        installGlobalShortcut()
        installDictationEventTap()
    }

    /// Register the shortcut with macOS rather than relying on the menu item's
    /// key equivalent, which is only evaluated while the menu is active.
    private func installGlobalShortcut() {
        var eventSpecs = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            2,
            &eventSpecs,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            Log.write("warning: couldn't install recording shortcut handler (\(handlerStatus))\n")
            return
        }

        let hotKeyID = EventHotKeyID(signature: 0x716C6C72, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(controlKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if hotKeyStatus != noErr {
            Log.write("warning: couldn't register Control + Option + R (\(hotKeyStatus))\n")
        }
    }

    /// Carbon hot keys cannot target a bare modifier key or tell the two
    /// Option keys apart, so dictation uses a global event tap filtered on the
    /// right-Option key code. The tap consumes those events, dedicating right
    /// Option to dictation while left Option keeps its normal behavior.
    ///
    /// A consuming tap needs Accessibility and Input Monitoring permission.
    /// Each rebuild of this ad-hoc signed binary invalidates earlier grants, so
    /// on failure ask macOS to prompt for both (it links to the right Settings
    /// pane) and keep retrying until the user grants them.
    private func installDictationEventTap() {
        guard !createDictationEventTap() else { return }
        dictationShortcutAvailable = false
        refresh()
        Log.write("warning: couldn't create right-option dictation event tap "
            + "(accessibility=\(AXIsProcessTrusted()) input_monitoring=\(CGPreflightListenEventAccess())); "
            + "requesting permission and retrying")
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !AXIsProcessTrusted() { DictationDestination.requestPermission() }
        let retry = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.createDictationEventTap() else { return }
                self.dictationTapRetry?.invalidate()
                self.dictationTapRetry = nil
                self.dictationShortcutAvailable = true
                self.refresh()
                Log.write("right-option dictation shortcut ready")
            }
        }
        RunLoop.main.add(retry, forMode: .common)
        dictationTapRetry = retry
    }

    private func createDictationEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: Self.dictationTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        dictationEventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        dictationTapRunSource = source
        return true
    }

    func shutdown() {
        dictationTapRetry?.invalidate()
        dictationTapRetry = nil
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let dictationTapRunSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), dictationTapRunSource, .commonModes)
            self.dictationTapRunSource = nil
        }
        if let dictationEventTap {
            CFMachPortInvalidate(dictationEventTap)
            self.dictationEventTap = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// Reflect recording state in the menu item titles and in the status-bar
    /// icon (open eyes while recording, closed eyes when idle). Call once a
    /// second while recording.
    func update(recording: Bool, elapsed: String?) {
        self.recording = recording
        self.elapsed = elapsed
        refresh()
    }

    func updateDictation(_ state: DictationState) {
        dictation = state
        refresh()
    }

    private func refresh() {
        stateLabel.title = dictation.isBusy ? dictation.label :
            (recording ? "● recording · \(elapsed ?? "0:00")" : "idle")
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        toggleItem.isEnabled = onToggle != nil && !dictation.isBusy
        switch dictation {
        case .idle: dictationItem.title = dictationShortcutAvailable
            ? "Start dictation" : "Start dictation (Right ⌥ unavailable)"
        case .preparing: dictationItem.title = "Cancel preparing dictation"
        case .listening: dictationItem.title = "Stop dictation"
        case .processing: dictationItem.title = "Processing dictation…"
        case .inserting: dictationItem.title = "Inserting dictation…"
        }
        dictationItem.isEnabled = onDictation != nil && !recording && dictation != .processing && dictation != .inserting
        cancelDictationItem.isHidden = !dictation.isBusy
        cancelDictationItem.isEnabled = dictation.canCancel
        if let button = statusItem.button {
            let image = recording || dictation.isBusy ? Self.eyesOpenImage() : Self.eyesClosedImage()
            if button.image !== image { button.image = image }
        }
        recordingRow?.syncLabels()
        dictationRow?.syncLabels()
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    // Inlined eye icons. Keeping them in source means the executable has no
    // separate resource bundle to install alongside it — true single-binary.
    // Both are monochrome strokes so macOS recolors them as template images;
    // colored gradients wouldn't survive menu-bar templating.
    private static let eyesClosedSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M1.5 10.5c2 3.2 6.5 3.2 8.5 0"/>\
    <path d="M3.6 12.7v1.9M5.75 13.5v1.9M7.9 12.7v1.9"/>\
    <path d="M14 10.5c2 3.2 6.5 3.2 8.5 0"/>\
    <path d="M16.1 12.7v1.9M18.25 13.5v1.9M20.4 12.7v1.9"/>\
    </svg>
    """

    /// Parsed once: refresh() runs every second while recording.
    private static let eyesClosed = svgImage(eyesClosedSVG)
    private static let eyesOpen = svgImage(eyesOpenSVG)

    private static func eyesClosedImage() -> NSImage? { eyesClosed }

    /// Open eyes: the recording-state variant. Stays a template image so
    /// macOS recolors it for the menu bar appearance.
    private static let eyesOpenSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M1.5 12c2-3.8 7-3.8 9 0-2 3.8-7 3.8-9 0Z"/>\
    <circle cx="6" cy="12" r="2" fill="currentColor" stroke="none"/>\
    <path d="M13.5 12c2-3.8 7-3.8 9 0-2 3.8-7 3.8-9 0Z"/>\
    <circle cx="18" cy="12" r="2" fill="currentColor" stroke="none"/>\
    </svg>
    """

    private static func eyesOpenImage() -> NSImage? { eyesOpen }

    private static func svgImage(_ svg: String) -> NSImage? {
        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
        guard let userData, let event else { return OSStatus(eventNotHandledErr) }
        let controller = Unmanaged<MenuBarController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        var id = EventHotKeyID()
        guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID), nil,
                                MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
              id.signature == 0x716C6C72 else { return OSStatus(eventNotHandledErr) }
        if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
            controller.heldHotKeys.remove(id.id)
            return noErr
        }
        guard controller.heldHotKeys.insert(id.id).inserted else { return noErr }
        switch id.id {
        case 1:
            if !controller.dictation.isBusy { controller.onToggle?() }
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    /// Runs on the main run loop. Consumes right-Option press/release so the
    /// key never reaches other apps, and reuses the hot-key press/release
    /// handling (id 2) for toggle vs push-to-talk behavior.
    private static let dictationTapCallback:
        @convention(c) (CGEventTapProxy, CGEventType, CGEvent, UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?
        = { _, type, event, userInfo in
        // macOS disables a tap whose callback is slow (or on some user input)
        // and never re-enables it; without this Right ⌥ stays dead until restart.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let controller = Unmanaged<MenuBarController>.fromOpaque(userInfo).takeUnretainedValue()
                controller.reenableDictationTap()
            }
            return Unmanaged.passUnretained(event)
        }
        guard let userInfo, type == .flagsChanged,
              event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_RightOption)
        else { return Unmanaged.passUnretained(event) }
        let controller = Unmanaged<MenuBarController>.fromOpaque(userInfo).takeUnretainedValue()
        if event.flags.contains(.maskAlternate) {
            guard controller.heldHotKeys.insert(2).inserted else { return nil }
            controller.handleDictationPress()
        } else {
            controller.heldHotKeys.remove(2)
            controller.handleDictationRelease()
        }
        return nil
    }

    private func reenableDictationTap() {
        guard let dictationEventTap else { return }
        Log.write("warning: right-option event tap was disabled by macOS; re-enabling")
        CGEvent.tapEnable(tap: dictationEventTap, enable: true)
        // The release may have been lost while the tap was off; a stale "held"
        // entry would swallow the next press.
        heldHotKeys.remove(2)
        dictationKeyPressDate = nil
    }

    private func handleDictationPress() {
        Log.write("dictation hotkey press state=\(dictation)\n")
        if dictation.isBusy {
            // A second press stops the current dictation; the matching release
            // must not toggle it again.
            dictationKeyPressDate = nil
            onDictation?()
        } else {
            dictationKeyPressDate = Date()
            if !recording { onDictation?() }
        }
    }

    private func handleDictationRelease() {
        defer { dictationKeyPressDate = nil }
        guard let pressedAt = dictationKeyPressDate else { return }
        let elapsed = Date().timeIntervalSince(pressedAt)
        Log.write("dictation hotkey release elapsed=\(elapsed)\n")
        if DictationShortcut.shouldStopOnRelease(elapsed: elapsed, state: dictation) {
            onDictation?()
        }
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func dictationClicked() { onDictation?() }
    @objc private func cancelDictationClicked() { onCancelDictation?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
