import Accelerate
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
    private var focusObserver: DictationFocusObserver?
    /// Audio before `committedSamples` is already recognized as `committedText`;
    /// previews and the final pass only transcribe what follows.
    private var committedSamples = 0
    private var committedText = ""

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
        committedSamples = 0
        committedText = ""
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
        Log.write("dictation start id=\(id.uuidString.prefix(8)) state=\(state)\n")
        let originalAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        destination = DictationDestination.capture()
        targetChanged = false
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            @Sendable [weak self] event in
            let shouldInvalidate = DictationInputPolicy.invalidatesDestination(
                type: event.type, keyCode: event.type == .keyDown ? event.keyCode : 0
            )
            guard shouldInvalidate else { return }
            Log.write("dictation input invalidated type=\(event.type.rawValue) keyCode=\(event.keyCode)\n")
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
        committedSamples = 0
        committedText = ""
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
                Log.write("dictation listening id=\(id.uuidString.prefix(8))\n")
                startPreview(id: id)
                // Focus and window changes arrive as AX notifications, so the
                // timer only backs them up (for apps that don't post them)
                // at 1 Hz instead of issuing AX IPC on the main thread at 4 Hz.
                startFocusObserver()
                let listeningStarted = ContinuousClock.now
                let maximum = Duration.seconds(Config.dictationMaximumSeconds())
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.state == .listening else { return }
                        self.checkDestination()
                        if self.capture.audio.isFull || listeningStarted.duration(to: .now) >= maximum {
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

    private func startFocusObserver() {
        guard let destination else { return }
        focusObserver = DictationFocusObserver(pid: destination.pid) { [weak self] in
            self?.checkDestination()
        }
    }

    /// Invalidate the destination once its app, window or field changes.
    private func checkDestination() {
        guard state == .listening, !targetChanged, let destination else { return }
        // Typed previews intentionally change the text, so
        // only focus/window/field changes invalidate the target.
        let reason = (previewUsedTyping || previewRange != nil)
            ? destination.focusRejectionReason()
            : destination.rejectionReason()
        if let reason {
            Log.write("dictation destination invalidated: \(reason)")
            targetChanged = true
        }
    }

    /// Each preview transcribes only the audio after the committed prefix.
    /// Once that tail grows long, its older part is recognized once at a quiet
    /// point and committed, so preview cost stays bounded instead of growing
    /// with the whole dictation, and the final pass only covers the tail.
    private func startPreview(id: UUID) {
        previewTask = Task {
            while !Task.isCancelled, generation == id, state == .listening {
                do {
                    try await Task.sleep(for: .milliseconds(1500))
                    guard !Task.isCancelled, generation == id, state == .listening else { return }
                    var tail = try capture.audio.snapshot(from: committedSamples)
                    guard tail.count >= 4000 else { continue }
                    if let split = DictationChunking.splitPoint(tail) {
                        let reply = try await recognizePreview(Array(tail[..<split]))
                        guard !Task.isCancelled, generation == id, state == .listening else { return }
                        committedText = DictationChunking.join(committedText, reply.text ?? "")
                        committedSamples += split
                        tail.removeFirst(split)
                        Log.write("dictation committed chunk seconds=\(split / 16_000)")
                    }
                    let reply = try await recognizePreview(tail)
                    guard !Task.isCancelled, generation == id, state == .listening else { return }
                    preview = DictationChunking.join(committedText, reply.text ?? "")
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

    private func recognizePreview(_ samples: [Float]) async throws -> InferenceReply {
        let task = Task {
            try await InferenceService.shared.request(InferenceRequest(operation: .dictate, samples: samples))
        }
        previewInFlight = task
        defer { previewInFlight = nil }
        return try await task.value
    }

    private func finish() {
        guard state == .listening else { return }
        let id = generation
        Log.write("dictation finish id=\(id.uuidString.prefix(8)) previewRange=\(previewRange != nil) targetChanged=\(targetChanged)\n")
        state = .processing
        ticker?.invalidate()
        ticker = nil
        focusObserver = nil
        capture.stop()
        previewTask?.cancel()
        previewTask = nil
        let activePreview = previewInFlight
        // A commit still in flight is discarded (state is no longer
        // .listening), so this prefix and offset stay consistent.
        let prefix = committedText
        let committed = committedSamples
        let began = ContinuousClock.now
        Task {
            do {
                let samples = try capture.audio.snapshot(from: committed)
                capture.audio.clear()
                if let activePreview { _ = try? await activePreview.value }
                guard generation == id else { return }
                guard !samples.isEmpty || committed > 0 else {
                    Log.write("dictation finish empty_audio id=\(id.uuidString.prefix(8))\n")
                    fail("No microphone audio received. Please retry.")
                    return
                }
                let tailText = samples.isEmpty ? "" : try await InferenceService.shared.request(
                    InferenceRequest(operation: .dictate, samples: samples)
                ).text ?? ""
                await InferenceService.shared.endDictation(id)
                guard generation == id else { return }
                let text = DictationChunking.join(prefix, tailText)
                let insertion: DictationDestination.InsertionResult
                stopInputMonitor()
                if !text.isEmpty, self.destination != nil {
                    state = .inserting
                    Log.write("dictation insert id=\(id.uuidString.prefix(8)) previewRange=\(previewRange != nil)\n")
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
                    Log.write("dictation copy fallback: destination=\(destination != nil) text=\(!text.isEmpty)\n")
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
                        Log.write("dictation insertion fallback=clipboard timing=\(timing)\n")
                    }
                } else {
                    Log.write("dictation result=no_speech timing=\(timing)\n")
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
        Log.write("dictation failed: \(message)\n")
    }

    private func stopInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        focusObserver = nil
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
                Log.write("dictation live preview unavailable\n")
                return
            }
            if !suffix.isEmpty, self.destination?.type(suffix) == true {
                insertedPreview = text
                previewUsedTyping = true
                Log.write("dictation live preview revised delete=\(deleteCount) len=\(suffix.utf16.count)\n")
            } else if deleteCount == 0 && suffix.isEmpty {
                insertedPreview = text
            } else {
                previewInsertFailed = true
                Log.write("dictation live preview unavailable\n")
            }
            return
        }
        if self.destination?.type(text) == true {
            insertedPreview = text
            previewUsedTyping = true
            Log.write("dictation live preview typed len=\(text.utf16.count)\n")
        } else {
            previewInsertFailed = true
            Log.write("dictation live preview unavailable\n")
        }
    }
}

/// Where live dictation splits long audio into independently recognized
/// chunks: at the quietest 100 ms between a minimum chunk length and the most
/// recent seconds, which stay uncommitted so words in progress aren't cut.
enum DictationChunking {
    static let commitAfterSamples = 20 * 16_000
    static let minimumChunkSamples = 8 * 16_000
    static let keepTailSamples = 4 * 16_000
    static let windowSamples = 1_600

    static func splitPoint(_ samples: [Float]) -> Int? {
        guard samples.count >= commitAfterSamples else { return nil }
        let upper = samples.count - keepTailSamples - windowSamples
        guard upper >= minimumChunkSamples else { return nil }
        return samples.withUnsafeBufferPointer { buffer -> Int in
            var best = minimumChunkSamples
            var bestEnergy = Float.infinity
            var start = minimumChunkSamples
            while start <= upper {
                var energy: Float = 0
                vDSP_svesq(buffer.baseAddress! + start, 1, &energy, vDSP_Length(windowSamples))
                if energy < bestEnergy {
                    bestEnergy = energy
                    best = start
                }
                start += windowSamples / 2
            }
            return best + windowSamples / 2
        }
    }

    static func join(_ prefix: String, _ text: String) -> String {
        [prefix, text].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Accessibility focus/window notifications for the dictation target, plus
/// app activation, so destination changes are seen as they happen without
/// polling the target app over AX IPC from the main thread.
@MainActor
final class DictationFocusObserver {
    private var observer: AXObserver?
    private let application: AXUIElement
    private var activation: NSObjectProtocol?
    fileprivate let onChange: () -> Void
    private static let notifications = [
        kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification, kAXApplicationDeactivatedNotification,
    ]

    init(pid: pid_t, onChange: @escaping () -> Void) {
        self.onChange = onChange
        application = AXUIElementCreateApplication(pid)
        var created: AXObserver?
        if AXObserverCreate(pid, Self.callback, &created) == .success, let created {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            for name in Self.notifications {
                _ = AXObserverAddNotification(created, application, name as CFString, refcon)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
            observer = created
        }
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange() }
        }
    }

    isolated deinit {
        if let observer {
            for name in Self.notifications {
                AXObserverRemoveNotification(observer, application, name as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
    }

    /// Delivered on the main run loop, where the source was added.
    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let address = UInt(bitPattern: refcon)
        MainActor.assumeIsolated {
            guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else { return }
            Unmanaged<DictationFocusObserver>.fromOpaque(pointer).takeUnretainedValue().onChange()
        }
    }
}
