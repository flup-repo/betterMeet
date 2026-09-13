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
        case .listening: return "dictating · Right ⌥ to finish"
        case .processing: return "processing dictation…"
        case .inserting: return "inserting dictation…"
        }
    }
}

enum DictationInputPolicy {
    static func invalidatesDestination(type: NSEvent.EventType, keyCode: UInt16) -> Bool {
        type != .keyDown || keyCode != UInt16(kVK_RightOption)
    }
}

@MainActor
final class DictationController {
    private(set) var state = DictationState.idle {
        didSet { onState?(state) }
    }
    var onState: ((DictationState) -> Void)?
    private let capture = DictationCapture()
    private var destination: DictationDestination?
    private var generation = UUID()
    private var previewTask: Task<Void, Never>?
    private var ticker: Timer?
    private var previewInFlight: Task<InferenceReply, Error>?
    private var preview = ""
    private var previewRange: CFRange?
    private var insertedPreview: String?
    private var previewUsedTyping = false
    private var previewInsertFailed = false
    private var targetChanged = false
    private var sleepObserver: NSObjectProtocol?
    private var inputMonitor: Any?

    init() {
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
        previewRange = nil
        insertedPreview = nil
        previewUsedTyping = false
        previewInsertFailed = false
        state = .idle
    }

    private func start() {
        generation = UUID()
        let id = generation
        FileHandle.standardError.write(Data("dictation start id=\(id.uuidString.prefix(8)) state=\(state)\n".utf8))
        let originalAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        destination = DictationDestination.capture()
        targetChanged = false
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            @Sendable [weak self] event in
            let shouldInvalidate = DictationInputPolicy.invalidatesDestination(
                type: event.type, keyCode: event.type == .keyDown ? event.keyCode : 0
            )
            guard shouldInvalidate else { return }
            FileHandle.standardError.write(Data("dictation input invalidated type=\(event.type.rawValue) keyCode=\(event.keyCode)\n".utf8))
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.targetChanged = true
            }
        }
        preview = ""
        previewRange = nil
        insertedPreview = nil
        previewUsedTyping = false
        previewInsertFailed = false
        state = .preparing
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
                FileHandle.standardError.write(Data("dictation listening id=\(id.uuidString.prefix(8))\n".utf8))
                startPreview(id: id)
                let listeningStarted = ContinuousClock.now
                let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.state == .listening else { return }
                        if !self.targetChanged, let destination = self.destination {
                            // Typed previews intentionally change the text, so
                            // only focus/window/field changes invalidate the target.
                            let reason = (self.previewUsedTyping || self.previewRange != nil)
                                ? destination.focusRejectionReason()
                                : destination.rejectionReason()
                            if let reason {
                                FileHandle.standardError.write(Data("dictation destination invalidated: \(reason)\n".utf8))
                                self.targetChanged = true
                            }
                        }
                        if self.capture.audio.isFull || listeningStarted.duration(to: .now) >= .seconds(Config.dictationMaximumSeconds()) {
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
                    insertPreview(preview)
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
        FileHandle.standardError.write(Data("dictation finish id=\(id.uuidString.prefix(8)) previewRange=\(previewRange != nil) targetChanged=\(targetChanged)\n".utf8))
        state = .processing
        ticker?.invalidate()
        ticker = nil
        capture.stop()
        previewTask?.cancel()
        previewTask = nil
        let activePreview = previewInFlight
        let began = ContinuousClock.now
        Task {
            do {
                let samples = try capture.audio.snapshot()
                capture.audio.clear()
                if let activePreview { _ = try? await activePreview.value }
                guard generation == id else { return }
                guard !samples.isEmpty else {
                    FileHandle.standardError.write(Data("dictation finish empty_audio id=\(id.uuidString.prefix(8))\n".utf8))
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
                if !text.isEmpty, self.destination != nil {
                    state = .inserting
                    FileHandle.standardError.write(Data("dictation insert id=\(id.uuidString.prefix(8)) previewRange=\(previewRange != nil)\n".utf8))
                    if previewUsedTyping, let inserted = insertedPreview {
                        if text == inserted {
                            insertion = .inserted
                        } else if self.destination?.deleteBackward(inserted.utf16.count) == true,
                                  self.destination?.type(text) == true {
                            insertion = .inserted
                        } else {
                            insertion = .copyRequired
                        }
                    } else if let range = previewRange {
                        insertion = self.destination?.replace(range: range, with: text) == true ? .inserted : .copyRequired
                    } else if let destination = self.destination {
                        insertion = await destination.insert(text)
                    } else {
                        insertion = .copyRequired
                    }
                } else {
                    insertion = .copyRequired
                    FileHandle.standardError.write(Data(
                        "dictation copy fallback: destination=\(destination != nil) text=\(!text.isEmpty)\n".utf8
                    ))
                }
                guard generation == id else { return }
                let elapsed = began.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let timing = String(format: "%.2f s", seconds)
                state = .idle
                preview = ""
                if !text.isEmpty {
                    switch insertion {
                    case .inserted:
                        break
                    case .unconfirmed, .copyRequired:
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(text, forType: .string)
                        FileHandle.standardError.write(Data("dictation insertion fallback=clipboard timing=\(timing)\n".utf8))
                    }
                } else {
                    FileHandle.standardError.write(Data("dictation result=no_speech timing=\(timing)\n".utf8))
                }
                destination = nil
                previewRange = nil
                insertedPreview = nil
                previewUsedTyping = false
            } catch {
                guard generation == id else { return }
                fail("Dictation failed. Please retry; no text was inserted.")
            }
        }
    }

    private func fail(_ message: String) {
        cancel()
        FileHandle.standardError.write(Data("dictation failed: \(message)\n".utf8))
    }

    private func stopInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    /// Best-effort live preview: type only the part of the transcript that
    /// actually changed, so pauses don't erase the whole preview.
    private func insertPreview(_ text: String) {
        guard !text.isEmpty, !targetChanged, !previewInsertFailed,
              self.destination != nil, self.destination?.focusUnchanged() == true else { return }
        if let inserted = insertedPreview {
            guard text != inserted else { return }
            let oldUnits = Array(inserted.utf16)
            let newUnits = Array(text.utf16)
            var common = 0
            while common < oldUnits.count, common < newUnits.count,
                  oldUnits[common] == newUnits[common] {
                common += 1
            }
            let deleteCount = oldUnits.count - common
            let suffix = String(decoding: newUnits[common...], as: UTF16.self)
            if deleteCount > 0, self.destination?.deleteBackward(deleteCount) != true {
                previewInsertFailed = true
                FileHandle.standardError.write(Data("dictation live preview unavailable\n".utf8))
                return
            }
            if !suffix.isEmpty, self.destination?.type(suffix) == true {
                insertedPreview = text
                previewUsedTyping = true
                FileHandle.standardError.write(Data("dictation live preview revised delete=\(deleteCount) len=\(suffix.utf16.count)\n".utf8))
            } else if deleteCount == 0 && suffix.isEmpty {
                insertedPreview = text
            } else {
                previewInsertFailed = true
                FileHandle.standardError.write(Data("dictation live preview unavailable\n".utf8))
            }
            return
        }
        if self.destination?.type(text) == true {
            insertedPreview = text
            previewUsedTyping = true
            FileHandle.standardError.write(Data("dictation live preview typed len=\(text.utf16.count)\n".utf8))
        } else {
            previewInsertFailed = true
            FileHandle.standardError.write(Data("dictation live preview unavailable\n".utf8))
        }
    }
}
