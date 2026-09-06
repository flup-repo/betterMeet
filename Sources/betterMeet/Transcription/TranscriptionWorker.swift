import ArgumentParser
import Darwin
import Foundation

/// FluidAudio's debug logger can include recognized words. Keep its console
/// output inside a worker with null stdout/stderr, never in the daemon's logs.
struct TranscriptionWorker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_transcribe-worker", abstract: "Internal inference worker.", shouldDisplay: false
    )

    @Argument var request: String

    struct Request: Codable, Sendable {
        let source: URL
        let output: URL
        let settings: TranscriptionSettings
        let parentPID: Int32
    }

    func run() async throws {
        let value = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(fileURLWithPath: request)))
        guard getppid() == value.parentPID else {
            throw TranscriptionFailure("inference parent exited before startup")
        }
        let lock = open(value.output.appendingPathComponent(".transcription.lock").path,
                        O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw TranscriptionFailure("cannot open transcription lock") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw TranscriptionFailure("another transcription is using this output")
        }
        let monitor = DispatchSource.makeTimerSource(queue: .global())
        monitor.schedule(deadline: .now() + 1, repeating: 1)
        monitor.setEventHandler {
            // LaunchAgent restarts must not leave an orphan writing over its successor.
            if getppid() != value.parentPID { _exit(1) }
        }
        monitor.resume()
        defer { monitor.cancel() }
        _ = try await TranscriptionJob.run(source: value.source, output: value.output, settings: value.settings)
    }

    static func transcribe(source: URL, output: URL, settings: TranscriptionSettings) async throws -> TranscriptDocument {
        guard let executable = Bundle.main.executableURL else {
            throw TranscriptionFailure("cannot locate the inference worker executable")
        }
        let request = Request(source: source, output: output, settings: settings, parentPID: getpid())
        let requestURL = output.appendingPathComponent(".transcription-request-\(UUID().uuidString).json")
        try JSONEncoder().encode(request).write(to: requestURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: requestURL) }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["_transcribe-worker", requestURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { child in
                continuation.resume(returning: child.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else {
            throw TranscriptionFailure(
                "inference worker exited with status \(status); successful track checkpoints are retained"
            )
        }
        return try JSONDecoder().decode(
            TranscriptDocument.self, from: Data(contentsOf: output.appendingPathComponent("transcript.json"))
        )
    }
}
