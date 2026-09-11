import AVFoundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum DictationState: Equatable {
    case idle, preparing, listening, processing, inserting

    var isBusy: Bool { self != .idle }
    var canCancel: Bool { isBusy && self != .inserting }
    var label: String {
        switch self {
        case .idle: return "idle"
        case .preparing: return "preparing dictation…"
        case .listening: return "dictating · F9 to finish"
        case .processing: return "processing dictation…"
        case .inserting: return "inserting dictation…"
        }
    }
}

enum DictationInputPolicy {
    static func invalidatesDestination(type: NSEvent.EventType, keyCode: UInt16) -> Bool {
        type != .keyDown || keyCode != UInt16(kVK_F9)
    }
}

@MainActor
final class DictationController {
    private(set) var state = DictationState.idle {
        didSet { onState?(state) }
    }
    var onState: ((DictationState) -> Void)?
    private let capture = DictationCapture()
    private let panel = DictationPanel()
    private var destination: DictationDestination?
    private var generation = UUID()
    private var previewTask: Task<Void, Never>?
    private var ticker: Timer?
    private var previewInFlight: Task<InferenceReply, Error>?
    private var preview = ""
    private var targetChanged = false
    private var sleepObserver: NSObjectProtocol?
    private var inputMonitor: Any?

    init() {
        panel.onCancel = { [weak self] in
            guard let self, self.state != .inserting else { return }
            self.cancel()
        }
        capture.onFailure = { [weak self] in
            self?.fail("Microphone changed. Dictation cancelled; please retry.")
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.cancel() }
        }
    }

    func toggle() {
        switch state {
        case .idle: start()
        case .listening: finish()
        case .preparing: cancel()
        case .processing, .inserting: break
        }
    }

    func cancel() {
        let previous = generation
        generation = UUID()
        Task { await InferenceService.shared.endDictation(previous) }
        previewTask?.cancel()
        previewTask = nil
        previewInFlight = nil
        ticker?.invalidate()
        ticker = nil
        stopInputMonitor()
        capture.discard()
        destination = nil
        preview = ""
        state = .idle
        panel.hide()
    }

    private func start() {
        generation = UUID()
        let id = generation
        let originalAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        destination = DictationDestination.capture()
        targetChanged = false
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            @Sendable [weak self] event in
            let shouldInvalidate = DictationInputPolicy.invalidatesDestination(
                type: event.type, keyCode: event.type == .keyDown ? event.keyCode : 0
            )
            guard shouldInvalidate else { return }
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.targetChanged = true
            }
        }
        preview = ""
        state = .preparing
        panel.show(status: "Preparing multilingual model…",
                   text: "First use may download models. Waiting for any active meeting transcription.")
        if !AXIsProcessTrusted() { DictationDestination.requestPermission() }
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == id else { return }
            guard allowed else {
                fail("Enable Microphone permission in System Settings to dictate.")
                return
            }
            do {
                await InferenceService.shared.beginDictation(id)
                guard generation == id else {
                    await InferenceService.shared.endDictation(id)
                    return
                }
                _ = try await InferenceService.shared.request(InferenceRequest(operation: .prepare))
                guard generation == id else { return }
                // Chromium may need an event-loop turn to populate its AX tree.
                if destination == nil, !targetChanged,
                   NSWorkspace.shared.frontmostApplication?.processIdentifier == originalAppPID {
                    destination = DictationDestination.capture()
                }
                try capture.start()
                state = .listening
                panel.show(status: "Listening · F9 to finish · 60-second limit",
                           text: destination == nil ? "No supported text field. Your result will have a Copy button." : "")
                startPreview(id: id)
                let listeningStarted = ContinuousClock.now
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.state == .listening else { return }
                        if !self.targetChanged, let reason = self.destination?.rejectionReason() {
                            FileHandle.standardError.write(Data("dictation destination invalidated: \(reason)\n".utf8))
                            self.targetChanged = true
                        }
                        if self.capture.audio.isFull || listeningStarted.duration(to: .now) >= .seconds(60) {
                            self.finish()
                        }
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                ticker = timer
            } catch {
                guard generation == id else { return }
                fail("Cannot prepare dictation. Check your microphone and model downloads, then retry.")
            }
        }
    }

    private func startPreview(id: UUID) {
        previewTask = Task {
            while !Task.isCancelled, generation == id, state == .listening {
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled, generation == id, state == .listening else { return }
                    let samples = try capture.audio.snapshot()
                    guard samples.count >= 4000 else { continue }
                    let task = Task {
                        try await InferenceService.shared.request(
                            InferenceRequest(operation: .dictate, samples: samples)
                        )
                    }
                    previewInFlight = task
                    let reply = try await task.value
                    guard !Task.isCancelled, generation == id, state == .listening else { return }
                    previewInFlight = nil
                    preview = reply.text ?? ""
                    panel.show(status: "Listening · F9 to finish · preview may change", text: preview)
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == id, state == .listening else { return }
                    fail("Dictation recognition failed. Please retry.")
                    return
                }
            }
        }
    }

    private func finish() {
        guard state == .listening else { return }
        let id = generation
        state = .processing
        ticker?.invalidate()
        ticker = nil
        capture.stop()
        previewTask?.cancel()
        previewTask = nil
        let activePreview = previewInFlight
        panel.show(status: "Processing dictation…", text: preview)
        let began = ContinuousClock.now
        Task {
            do {
                let samples = try capture.audio.snapshot()
                capture.audio.clear()
                if let activePreview { _ = try? await activePreview.value }
                guard generation == id else { return }
                guard !samples.isEmpty else {
                    fail("No microphone audio received. Please retry.")
                    return
                }
                let reply = try await InferenceService.shared.request(
                    InferenceRequest(operation: .dictate, samples: samples)
                )
                await InferenceService.shared.endDictation(id)
                guard generation == id else { return }
                let text = reply.text ?? ""
                let insertion: DictationDestination.InsertionResult
                stopInputMonitor()
                if !text.isEmpty, !targetChanged, let destination {
                    state = .inserting
                    panel.show(status: "Inserting dictation…", text: text, cancellable: false)
                    insertion = await destination.insert(text)
                } else {
                    insertion = .copyRequired
                    FileHandle.standardError.write(Data(
                        "dictation copy fallback: destination=\(destination != nil) input_or_target_changed=\(targetChanged)\n".utf8
                    ))
                }
                guard generation == id else { return }
                let elapsed = began.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let timing = String(format: "%.2f s", seconds)
                state = .idle
                preview = ""
                if text.isEmpty {
                    panel.show(status: "No speech detected.", busy: false)
                } else if insertion == .inserted {
                    panel.show(status: "Inserted · \(timing) · review names and numbers", text: text, busy: false)
                } else if insertion == .unconfirmed {
                    panel.show(status: "Paste sent · check your destination before pasting again", text: text, busy: false)
                } else {
                    panel.show(status: "Ready · \(timing) · copy to your chosen field", text: text, busy: false)
                }
                destination = nil
            } catch {
                guard generation == id else { return }
                fail("Dictation failed. Please retry; no text was inserted.")
            }
        }
    }

    private func fail(_ message: String) {
        cancel()
        panel.show(status: message, busy: false)
    }

    private func stopInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }
}
