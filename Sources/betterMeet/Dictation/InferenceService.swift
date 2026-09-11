import ArgumentParser
import Darwin
import Foundation

struct InferenceRequest: Codable, Sendable {
    enum Operation: String, Codable { case prepare, dictate, meeting }
    var operation: Operation
    var samples: [Float]?
    var source: URL?
    var output: URL?
    var settings = TranscriptionSettings()
}

struct InferenceReply: Codable, Sendable {
    var text: String?
    var processingSeconds: Double?
    var error: String?
}

/// Length-framed private pipes, never stdout logging or transcript files.
enum InferenceWire {
    static let maximumBytes = 32 * 1024 * 1024

    static func write<T: Encodable>(_ value: T, to handle: FileHandle) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw TranscriptionFailure("inference message too large") }
        var count = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &count) { try handle.write(contentsOf: Data($0)) }
        try handle.write(contentsOf: data)
    }

    static func read<T: Decodable>(_ type: T.Type, from handle: FileHandle) throws -> T {
        let header = try readExactly(4, from: handle)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard count > 0, count <= maximumBytes else {
            throw TranscriptionFailure("invalid inference message")
        }
        return try JSONDecoder().decode(type, from: readExactly(count, from: handle))
    }

    private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else {
                throw TranscriptionFailure("inference worker disconnected")
            }
            data.append(part)
        }
        return data
    }
}

/// One warm model owner shared by dictation and the daemon's meeting queue.
/// Dictation jumps queued meeting work, but never interrupts an active job.
actor InferenceService {
    static let shared = InferenceService()
    private struct Pending {
        let request: InferenceRequest
        let continuation: CheckedContinuation<InferenceReply, Error>
    }
    private var queue: [Pending] = []
    private var draining = false
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var idleTask: Task<Void, Never>?
    private var stopped = false
    private var dictationSession: UUID?

    func beginDictation(_ id: UUID) {
        dictationSession = id
        idleTask?.cancel()
    }

    func endDictation(_ id: UUID) {
        guard dictationSession == id else { return }
        dictationSession = nil
        drainIfNeeded()
    }

    func request(_ request: InferenceRequest) async throws -> InferenceReply {
        guard !stopped else { throw TranscriptionFailure("inference service stopped") }
        idleTask?.cancel()
        return try await withCheckedThrowingContinuation { continuation in
            let pending = Pending(request: request, continuation: continuation)
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
                let reply = try await Task.detached {
                    try InferenceWire.write(pending.request, to: input)
                    return try InferenceWire.read(InferenceReply.self, from: output)
                }.value
                if let error = reply.error { throw TranscriptionFailure(error) }
                pending.continuation.resume(returning: reply)
            } catch {
                closeWorker()
                pending.continuation.resume(throwing: error)
            }
        }
        draining = false
        if !stopped, dictationSession == nil {
            idleTask = Task {
                do {
                    try await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled, !self.draining, self.queue.isEmpty,
                          self.dictationSession == nil else { return }
                    self.closeWorker()
                } catch {}
            }
        }
    }

    private func drainIfNeeded() {
        guard !stopped, !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func startWorker() throws {
        if process?.isRunning == true { return }
        closeWorker()
        guard let executable = Bundle.main.executableURL else {
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

    private func closeWorker() {
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        // The active reader observes EOF when the child exits.
        process = nil
        input = nil
        output = nil
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
        let replies = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
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
        var engine: ParakeetEngine?
        var loadedSettings: TranscriptionSettings?
        while let request = try? InferenceWire.read(InferenceRequest.self, from: .standardInput) {
            do {
                var settings = request.operation == .meeting ? request.settings : TranscriptionSettings()
                try settings.resolveVocabulary()
                if loadedSettings != settings {
                    await engine?.release()
                    engine = ParakeetEngine(settings: settings)
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
                    guard let samples = request.samples, !samples.isEmpty,
                          samples.count <= DictationAudio.maximumSamples,
                          samples.allSatisfy(\.isFinite) else {
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
                    _ = try await TranscriptionJob.run(source: source, output: output, settings: settings,
                                                       preparedEngine: engine)
                }
                let elapsed = began.duration(to: .now).components
                reply.processingSeconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                try InferenceWire.write(reply, to: replies)
            } catch {
                // Never forward library errors that could embed audio or transcript content.
                try InferenceWire.write(InferenceReply(error: "Local recognition failed. Check model availability and retry."),
                                        to: replies)
            }
        }
        await engine?.release()
    }
}
