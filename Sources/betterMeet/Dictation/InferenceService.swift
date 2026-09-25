import ArgumentParser
import Darwin
import Foundation
import Synchronization

struct InferenceRequest: Codable, Sendable {
    enum Operation: String, Codable { case prepare, dictate, meeting }
    var operation: Operation
    /// Travels as a raw Float32 frame after the JSON header, never as JSON:
    /// JSON costs ~13 bytes per sample and capped dictation at ~165 seconds.
    var samples: [Float]?
    var source: URL?
    var output: URL?
    var settings = TranscriptionSettings()
    /// Only the meeting track to transcribe; nil means every track. Lets
    /// dictation run between the tracks of a long meeting job.
    var track: String?
    /// Sample count of the raw frame that follows the header, if any.
    var sampleCount: Int?
}

struct InferenceReply: Codable, Sendable {
    var text: String?
    var processingSeconds: Double?
    var error: String?
    /// Set only on interim progress frames (0...1), never on the final reply.
    var progress: Double?
}

/// Length-framed private pipes, never stdout logging or transcript files.
enum InferenceWire {
    static let maximumBytes = 32 * 1024 * 1024

    static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw TranscriptionFailure("inference message too large") }
        var count = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &count) { try writeAll($0, to: handle) }
        try data.withUnsafeBytes { try writeAll($0, to: handle) }
    }

    static func read<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T {
        let count = Int(try readLength(from: handle))
        guard count > 0, count <= maximumBytes else {
            throw TranscriptionFailure("invalid inference message")
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try readExactly(into: $0, from: handle) }
        return try JSONDecoder().decode(type, from: data)
    }

    /// A request is a JSON header followed, for dictation, by the samples as
    /// native Float32 bytes (both ends are the same binary on the same host).
    static func writeRequest(_ request: InferenceRequest, to handle: FileHandle) throws {
        var header = request
        header.samples = nil
        header.sampleCount = request.samples?.count
        try write(header, to: handle)
        if let samples = request.samples, !samples.isEmpty {
            try samples.withUnsafeBytes { try writeAll($0, to: handle) }
        }
    }

    static func readRequest(from handle: FileHandle, maximumSamples: Int) throws -> InferenceRequest {
        var request = try read(InferenceRequest.self, from: handle)
        guard let count = request.sampleCount else {
            request.samples = nil
            return request
        }
        guard count > 0, count <= maximumSamples else {
            throw TranscriptionFailure("invalid inference message")
        }
        request.samples = try [Float](unsafeUninitializedCapacity: count) { buffer, initialized in
            try readExactly(into: UnsafeMutableRawBufferPointer(buffer), from: handle)
            initialized = count
        }
        request.sampleCount = nil
        return request
    }

    private static func readLength(from handle: FileHandle) throws -> UInt32 {
        var length: UInt32 = 0
        try withUnsafeMutableBytes(of: &length) { try readExactly(into: $0, from: handle) }
        return UInt32(bigEndian: length)
    }

    /// POSIX I/O straight into the destination buffer: no intermediate Data
    /// chunks for multi-megabyte sample frames.
    private static func readExactly(into buffer: UnsafeMutableRawBufferPointer, from handle: FileHandle) throws {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.read(handle.fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TranscriptionFailure("inference worker disconnected") }
            offset += count
        }
    }

    private static func writeAll(_ buffer: UnsafeRawBufferPointer, to handle: FileHandle) throws {
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(handle.fileDescriptor, buffer.baseAddress! + offset, buffer.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TranscriptionFailure("inference worker disconnected") }
            offset += count
        }
    }
}

/// One warm model owner shared by dictation and the daemon's meeting queue.
/// Dictation jumps queued meeting work, but never interrupts an active job;
/// meetings are sent one track at a time so dictation waits at most one track.
actor InferenceService {
    static let shared = InferenceService()
    private struct Pending: Sendable {
        let request: InferenceRequest
        let progress: (@Sendable (Double) -> Void)?
        let continuation: CheckedContinuation<InferenceReply, Error>
    }
    /// Blocking pipe I/O runs here, never on the Swift cooperative pool: a
    /// meeting track can keep a read pending for minutes.
    private static let ioQueue = DispatchQueue(label: "com.flup-repo.betterMeet.inference-io")
    private var queue: [Pending] = []
    private var draining = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var idleTask: Task<Void, Never>?
    private var stopped = false
    private var dictationSession: UUID?
    /// The last request was one track of a meeting; its next track or the
    /// assembly request follows immediately, so don't unload models between.
    private var meetingInProgress = false
    private let executable: URL?

    /// `executable` overrides the worker binary (defaults to this executable).
    init(executable: URL? = nil) {
        self.executable = executable
    }

    func beginDictation(_ id: UUID) {
        dictationSession = id
        idleTask?.cancel()
    }

    func endDictation(_ id: UUID) {
        guard dictationSession == id else { return }
        dictationSession = nil
        drainIfNeeded()
        if !draining { scheduleIdleShutdown() }
    }

    func request(_ request: InferenceRequest,
                 progress: (@Sendable (Double) -> Void)? = nil) async throws -> InferenceReply {
        guard !stopped else { throw TranscriptionFailure("inference service stopped") }
        idleTask?.cancel()
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Pending(request: request, progress: progress, continuation: continuation)
            if request.operation == .meeting {
                queue.append(pending)
            } else {
                let index = queue.firstIndex { $0.request.operation == .meeting } ?? queue.count
                queue.insert(pending, at: index)
            }
            drainIfNeeded()
        }
    }

    func shutdown() {
        stopped = true
        idleTask?.cancel()
        closeWorker()
        for pending in queue {
            pending.continuation.resume(throwing: TranscriptionFailure("inference service stopped"))
        }
        queue.removeAll()
    }

    private func drain() async {
        while !queue.isEmpty {
            if dictationSession != nil, queue[0].request.operation == .meeting { break }
            let pending = queue.removeFirst()
            meetingInProgress = pending.request.operation == .meeting && pending.request.track != nil
            do {
                try startWorker()
                guard let input, let output, let child = process else {
                    throw TranscriptionFailure("inference worker unavailable")
                }
                // A failed model download or hung inference must not leave the UI stuck.
                let timeout: UInt64 = pending.request.operation == .meeting ? 3600 : 180
                let watchdog = Task {
                    do {
                        try await Task.sleep(for: .seconds(timeout))
                        if !Task.isCancelled, child.isRunning { child.terminate() }
                    } catch {}
                }
                defer { watchdog.cancel() }
                let reply = try await Self.exchange(pending.request, progress: pending.progress,
                                                    input: input, output: output)
                if let error = reply.error { throw TranscriptionFailure(error) }
                pending.continuation.resume(returning: reply)
            } catch {
                closeWorker()
                pending.continuation.resume(throwing: error)
            }
            // A finished meeting leaves the worker holding models plus a large,
            // fragmented heap. Unless more work is waiting, recycle it now
            // rather than idling on that memory.
            if pending.request.operation == .meeting, pending.request.track == nil,
               queue.isEmpty, dictationSession == nil {
                closeWorker()
            }
        }
        draining = false
        if dictationSession == nil { scheduleIdleShutdown() }
    }

    private static func exchange(_ request: InferenceRequest, progress: (@Sendable (Double) -> Void)?,
                                 input: FileHandle, output: FileHandle) async throws -> InferenceReply {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    try InferenceWire.writeRequest(request, to: input)
                    while true {
                        let reply = try InferenceWire.read(InferenceReply.self, from: output)
                        // Progress frames precede the one final reply.
                        if let value = reply.progress {
                            progress?(value)
                            continue
                        }
                        continuation.resume(returning: reply)
                        return
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func scheduleIdleShutdown() {
        idleTask?.cancel()
        guard !stopped, process != nil else { return }
        // Between a meeting's tracks, keep models loaded briefly even when the
        // configured idle time is zero; the follow-up request is imminent.
        let seconds = meetingInProgress ? max(Config.inferenceIdleSeconds(), 60) : Config.inferenceIdleSeconds()
        guard seconds > 0 else {
            closeWorker()
            return
        }
        idleTask = Task {
            do {
                try await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, !self.draining, self.queue.isEmpty,
                      self.dictationSession == nil else { return }
                self.closeWorker()
            } catch {}
        }
    }

    private func drainIfNeeded() {
        guard !stopped, !draining, !queue.isEmpty else { return }
        draining = true
        idleTask?.cancel()
        Task { await drain() }
    }

    private func startWorker() throws {
        if process?.isRunning == true { return }
        closeWorker()
        guard let executable = executable ?? Bundle.main.executableURL else {
            throw TranscriptionFailure("cannot locate inference executable")
        }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = executable
        child.arguments = ["_inference-worker", "--parent-pid", String(getpid())]
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        try child.run()
        // Close the parent's copies of child-side endpoints so EOF is observable.
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        process = child
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
    }

    /// Whether a worker process is currently alive (for diagnostics and tests).
    var workerRunning: Bool { process?.isRunning == true }

    private func closeWorker() {
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        // The active reader observes EOF when the child exits.
        process = nil
        input = nil
        output = nil
    }
}

/// Serializes reply frames: progress is reported from a separate task while
/// the request itself is still running.
private final class ReplyWriter: Sendable {
    private let handle: FileHandle
    private let lock = Mutex(())

    init(handle: FileHandle) { self.handle = handle }

    func write(_ reply: InferenceReply) throws {
        try lock.withLock { _ in try InferenceWire.write(reply, to: handle) }
    }
}

struct InferenceWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_inference-worker", abstract: "Internal shared inference worker.", shouldDisplay: false
    )
    @Option var parentPid: Int32

    func run() async throws {
        guard getppid() == parentPid else { return }
        // FluidAudio may print recognized words. Reserve a duplicate for the
        // protocol and redirect all library stdout/stderr to /dev/null.
        let descriptor = dup(STDOUT_FILENO)
        guard descriptor >= 0 else { throw TranscriptionFailure("cannot open inference response pipe") }
        let replies = ReplyWriter(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
        let null = open("/dev/null", O_WRONLY)
        guard null >= 0 else { throw TranscriptionFailure("cannot isolate inference logging") }
        dup2(null, STDOUT_FILENO)
        dup2(null, STDERR_FILENO)
        close(null)
        signal(SIGPIPE, SIG_IGN)
        let parent = parentPid
        let monitor = DispatchSource.makeTimerSource(queue: .global())
        monitor.schedule(deadline: .now() + 1, repeating: 1)
        monitor.setEventHandler { if getppid() != parent { _exit(1) } }
        monitor.resume()
        defer { monitor.cancel() }
        // Recognizers stay loaded across settings changes, so alternating
        // dictation (default settings) with meeting settings never reloads them.
        let models = ParakeetModels()
        var engine: ParakeetEngine?
        var loadedSettings: TranscriptionSettings?
        while let request = try? InferenceWire.readRequest(from: .standardInput,
                                                           maximumSamples: DictationAudio.maximumSamples) {
            do {
                var settings = request.operation == .meeting ? request.settings : TranscriptionSettings()
                try settings.resolveVocabulary()
                if loadedSettings != settings {
                    await engine?.release()
                    engine = ParakeetEngine(settings: settings, models: models)
                    loadedSettings = settings
                }
                guard let engine else { throw TranscriptionFailure("recognizer unavailable") }
                let began = ContinuousClock.now
                try await engine.prepare()
                var reply = InferenceReply()
                switch request.operation {
                case .prepare:
                    break
                case .dictate:
                    guard let samples = request.samples, !samples.isEmpty else {
                        throw TranscriptionFailure("invalid dictation audio")
                    }
                    let result = try await engine.transcribe(samples: samples)
                    // No-speech output stays out of the destination application.
                    reply.text = result.segments.filter { !$0.flags.contains("no_vad_speech") }
                        .map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                case .meeting:
                    guard let source = request.source, let output = request.output else {
                        throw TranscriptionFailure("invalid meeting request")
                    }
                    let lock = open(output.appendingPathComponent(".transcription.lock").path,
                                    O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
                    guard lock >= 0 else { throw TranscriptionFailure("cannot open transcription lock") }
                    defer { close(lock) }
                    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                        throw TranscriptionFailure("another transcription is using this output")
                    }
                    let progress = ProgressThrottle { value in
                        try? replies.write(InferenceReply(progress: value))
                    }
                    if let track = request.track {
                        try await TranscriptionJob.runTrack(track, source: source, output: output,
                                                            settings: settings, engine: engine,
                                                            progress: progress.report)
                    } else {
                        _ = try await TranscriptionJob.run(source: source, output: output, settings: settings,
                                                           preparedEngine: engine, progress: progress.report)
                    }
                }
                let elapsed = began.duration(to: .now).components
                reply.processingSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                try replies.write(reply)
            } catch {
                // Never forward library errors that could embed audio or transcript content.
                try replies.write(InferenceReply(error: "Local recognition failed. Check model availability and retry."))
            }
        }
        await engine?.release()
        await models.release()
    }
}

/// Forwards progress only in whole 5% steps, keeping the pipe quiet.
final class ProgressThrottle: Sendable {
    private let last = Mutex(-1)
    private let forward: @Sendable (Double) -> Void

    init(_ forward: @escaping @Sendable (Double) -> Void) { self.forward = forward }

    var report: @Sendable (Double) -> Void {
        { [self] value in
            let step = Int((min(max(value, 0), 1) * 20).rounded(.down))
            let changed = last.withLock { last in
                guard step > last else { return false }
                last = step
                return true
            }
            if changed { forward(Double(step) / 20) }
        }
    }
}
