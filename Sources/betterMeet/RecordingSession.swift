import CoreAudio
import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus durable session metadata. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    enum SessionError: Error, CustomStringConvertible {
        case metadataWriteFailed(Error)

        var description: String {
            switch self {
            case .metadataWriteFailed(let error):
                return "session metadata write failed: \(error)"
            }
        }
    }

    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()
    var onFailure: (@Sendable (String) -> Void)? {
        didSet {
            mic.onFailure = onFailure
            system.onFailure = onFailure
        }
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so we never run half a session silently.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.aac"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.aac"))
            try writeMetadata(endedAt: nil, failure: nil)
        } catch {
            mic.stop()
            system.stop()
            throw error
        }
    }

    /// Stop both tracks and finalize meta.json.
    func stop(failure: String? = nil) {
        mic.stop()
        system.stop()

        let ended = Date()
        do {
            try writeMetadata(endedAt: ended, failure: failure)
        } catch {
            let message = String(describing: error)
            FileHandle.standardError.write(Data("\(message)\n".utf8))
            onFailure?(message)
        }
    }

    private func writeMetadata(endedAt: Date?, failure: String?) throws {
        let iso = ISO8601DateFormatter()
        let offsets = endedAt == nil ? (mic: 0, system: 0) : trackOffsets()
        var meta: [String: Any] = [
            "schema_version": 2,
            "started": iso.string(from: startedAt),
            "state": endedAt == nil ? "recording" : (failure == nil ? "finished" : "failed"),
            "files": ["mic": "mic.aac", "system": "system.aac"],
            "start_offset_ms": ["mic": offsets.mic, "system": offsets.system],
        ]
        if let endedAt {
            meta["ended"] = iso.string(from: endedAt)
            meta["duration_seconds"] = Int(endedAt.timeIntervalSince(startedAt))
        }
        if let failure {
            meta["capture_error"] = failure
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: meta,
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            throw SessionError.metadataWriteFailed(error)
        }
    }

    private func trackOffsets() -> (mic: Int, system: Int) {
        if let micHost = mic.firstBufferHostTime,
           let systemHost = system.firstBufferHostTime {
            let earliest = min(micHost, systemHost)
            return (
                milliseconds(fromHostDelta: micHost - earliest),
                milliseconds(fromHostDelta: systemHost - earliest)
            )
        }

        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)
        return (
            max(0, Int(micStart.timeIntervalSince(earliest) * 1000)),
            max(0, Int(systemStart.timeIntervalSince(earliest) * 1000))
        )
    }

    private func milliseconds(fromHostDelta delta: UInt64) -> Int {
        Int(AudioConvertHostTimeToNanos(delta) / 1_000_000)
    }
}
