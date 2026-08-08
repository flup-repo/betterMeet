import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.aac → "me", system.aac → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum PipelineError: Error, CustomStringConvertible {
        case noReadableTracks
        case invalidTimestamp
        case hookLaunchFailed(Error)

        var description: String {
            switch self {
            case .noReadableTracks:
                return "no readable audio tracks"
            case .invalidTimestamp:
                return "transcription produced an invalid timestamp"
            case .hookLaunchFailed(let error):
                return "on_stop hook failed to launch: \(error)"
            }
        }
    }

    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var queued: Set<URL> = []
    private var queueIndex = 0
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            do {
                try runHook(for: sessionDir)
            } catch {
                log(sessionDir, String(describing: error))
            }
            return
        }
        guard queued.insert(sessionDir).inserted else { return }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions without a completion marker.
    /// Metadata is written at capture start, so uncleanly stopped sessions are
    /// recoverable too. Folder names sort chronologically.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        var pending: [URL] = []
        for dir in entries {
            guard let meta = try? SessionMeta.read(from: dir) else { continue }
            if meta.schemaVersion >= 2 {
                if !fm.fileExists(atPath: dir.appendingPathComponent(".complete").path) {
                    pending.append(dir)
                }
            } else if !fm.fileExists(
                atPath: dir.appendingPathComponent("transcript.json").path
            ) {
                pending.append(dir)
            }
        }
        pending.sort { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where queued.insert(dir).inserted {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, queueIndex < queue.count else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while queueIndex < queue.count {
            let dir = queue[queueIndex]
            queueIndex += 1
            let remaining = queue.count - queueIndex
            publish(.transcribing(session: dir.lastPathComponent, queued: remaining))
            do {
                let transcribed = dir.appendingPathComponent(".transcribed")
                if !FileManager.default.fileExists(atPath: transcribed.path) {
                    try await transcribe(dir)
                    try Data().write(to: transcribed, options: .atomic)
                }
                try runHook(for: dir)
                try Data().write(
                    to: dir.appendingPathComponent(".complete"),
                    options: .atomic
                )
                notifyUser(title: "betterMeet — transcript ready", body: dir.lastPathComponent)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "betterMeet — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
            queued.remove(dir)
        }
        queue.removeAll(keepingCapacity: true)
        queueIndex = 0
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        var readableTracks = 0
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }
            readableTracks += 1
            let offset = TimeInterval(track.offsetMs) / 1000
            for segment in segments {
                guard
                    let startMs = Self.milliseconds(segment.start + offset),
                    let endMs = Self.milliseconds(segment.end + offset),
                    endMs >= startMs
                else {
                    throw PipelineError.invalidTimestamp
                }
                merged.append(Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: startMs,
                    end_ms: endMs,
                    text: segment.text
                ))
            }
        }
        guard readableTracks > 0 else { throw PipelineError.noReadableTracks }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int? {
        let milliseconds = seconds * 1000
        guard
            milliseconds.isFinite,
            milliseconds >= 0,
            milliseconds <= Double(Int.max)
        else { return nil }
        return Int(milliseconds)
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) throws {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            throw PipelineError.hookLaunchFailed(error)
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let schemaVersion: Int
    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        guard offsets.values.allSatisfy({ $0 >= 0 }) else {
            throw MetaError.unreadable(url)
        }
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(schemaVersion: json["schema_version"] as? Int ?? 1, tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write Markdown first and canonical JSON last. Both writes are atomic,
    /// and the coordinator writes its completion marker after post-processing.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
