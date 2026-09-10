import AppKit
import Carbon.HIToolbox

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
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    var onToggle: (() -> Void)? {
        didSet { toggleItem.isEnabled = onToggle != nil }
    }
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
            keyEquivalent: "r"
        )
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        toggleItem.isEnabled = false
        menu.addItem(toggleItem)

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

        for item in [toggleItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = Self.eyesClosedImage()
            button.imagePosition = .imageLeft
        }

        installGlobalShortcut()
    }

    /// Register the shortcut with macOS rather than relying on the menu item's
    /// key equivalent, which is only evaluated while the menu is active.
    private func installGlobalShortcut() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.hotKeyHandler,
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            FileHandle.standardError.write(Data(
                "warning: couldn't install recording shortcut handler (\(handlerStatus))\n".utf8
            ))
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
            RemoveEventHandler(eventHandlerRef)
            eventHandlerRef = nil
            FileHandle.standardError.write(Data(
                "warning: couldn't register Control + Option + R (\(hotKeyStatus))\n".utf8
            ))
        }
    }

    func shutdown() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
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
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        if let button = statusItem.button {
            button.image = recording ? Self.eyesOpenImage() : Self.eyesClosedImage()
        }
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

    private static func eyesClosedImage() -> NSImage? {
        svgImage(eyesClosedSVG)
    }

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

    private static func eyesOpenImage() -> NSImage? {
        svgImage(eyesOpenSVG)
    }

    private static func svgImage(_ svg: String) -> NSImage? {
        guard let data = svg.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    private static let hotKeyHandler: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let controller = Unmanaged<MenuBarController>
            .fromOpaque(userData)
            .takeUnretainedValue()
        controller.onToggle?()
        return noErr
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
