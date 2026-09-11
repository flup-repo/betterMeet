import AppKit

@MainActor
final class DictationPanel {
    private let panel: NSPanel
    private let status = NSTextField(labelWithString: "")
    private let text = NSTextView()
    private let progress = NSProgressIndicator()
    private let copy = NSButton(title: "Copy text", target: nil, action: nil)
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: (() -> Void)?
    private var result = ""

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
                        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "betterMeet dictation"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        let content = NSView()
        panel.contentView = content
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.lineBreakMode = .byTruncatingTail
        progress.style = .spinning
        progress.controlSize = .small
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 14)
        text.drawsBackground = false
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.textContainerInset = NSSize(width: 4, height: 4)
        let buttons = NSStackView(views: [copy, cancel])
        buttons.spacing = 10
        for view in [status, progress, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            progress.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            progress.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            status.leadingAnchor.constraint(equalTo: progress.trailingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            status.centerYAnchor.constraint(equalTo: progress.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        copy.target = self
        copy.action = #selector(copyClicked)
        cancel.target = self
        cancel.action = #selector(cancelClicked)
    }

    func show(status message: String, text value: String = "", busy: Bool = true, cancellable: Bool = true) {
        result = value
        status.stringValue = message
        text.string = value
        text.isSelectable = !busy
        copy.isHidden = busy || value.isEmpty
        cancel.title = busy ? "Cancel" : "Dismiss"
        cancel.isEnabled = cancellable
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        progress.isHidden = !busy
        if !panel.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
                ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 60))
            }
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        text.string = ""
        result = ""
    }

    @objc private func copyClicked() {
        guard !result.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result, forType: .string)
        status.stringValue = "Copied. Paste into your chosen field."
    }

    @objc private func cancelClicked() { onCancel?() }
}
