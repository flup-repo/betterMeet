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
        case hookLaunchFailed(Error)

        var description: String {
            switch self {
            case .hookLaunchFailed(let error):
                return "on_stop hook failed to launch: \(error)"
            }
        }
    }

    enum Status: Sendable {
        case idle
        /// `detail` is e.g. "track 1/2 · 40%" once the worker reports it.
        case transcribing(session: String, queued: Int, detail: String?)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var queued: Set<URL> = []
    private var queueIndex = 0
    private var draining = false
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
            Log.write("resuming \(pending.count) untranscribed session(s)\n")
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
            publish(.transcribing(session: dir.lastPathComponent, queued: remaining, detail: nil))
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
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("transcribe.log"))
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
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        drainIfIdle()
    }

    /// One worker request per track, then one that assembles the transcript
    /// from their checkpoints, so dictation can run between tracks.
    private func transcribe(_ dir: URL) async throws {
        let settings = try Config.transcriptionSettings()
        let tracks = try SessionMeta.read(from: dir).tracks
        let session = dir.lastPathComponent
        for (index, track) in tracks.enumerated() {
            let step = "track \(index + 1)/\(tracks.count)"
            let remaining = queue.count - queueIndex
            publish(.transcribing(session: session, queued: remaining, detail: step))
            _ = try await InferenceService.shared.request(
                InferenceRequest(operation: .meeting, source: dir, output: dir, settings: settings,
                                 track: track.speaker)
            ) { [weak self] progress in
                Task {
                    await self?.progress(session: session, step: step, value: progress)
                }
            }
        }
        _ = try await InferenceService.shared.request(InferenceRequest(
            operation: .meeting, source: dir, output: dir, settings: settings
        ))
        let document = try JSONDecoder().decode(
            TranscriptDocument.self, from: Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        )
        guard document.status == "complete" else {
            log(dir, "\(document.status) — \(document.segments.count) segments")
            throw TranscriptionFailure("incomplete transcription; successful tracks saved, see transcript.json")
        }
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

    private func progress(session: String, step: String, value: Double) {
        guard draining else { return }
        publish(.transcribing(session: session, queued: queue.count - queueIndex,
                              detail: "\(step) · \(Int((value * 100).rounded()))%"))
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let schemaVersion: Int
    let tracks: [Track]
    let duration: Double?

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
        if let value = json["start_offset_ms"], !(value is [String: Int]) {
            throw MetaError.unreadable(url)
        }
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        guard offsets.values.allSatisfy({ $0 >= 0 }) else {
            throw MetaError.unreadable(url)
        }
        var tracks: [Track] = []
        guard files.values.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\")
        }) else { throw MetaError.unreadable(url) }
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        guard !tracks.isEmpty else { throw MetaError.unreadable(url) }
        let duration = json["duration_seconds"] as? Double
        if let duration {
            guard duration.isFinite, duration >= 0 else { throw MetaError.unreadable(url) }
        }
        return SessionMeta(schemaVersion: json["schema_version"] as? Int ?? 1, tracks: tracks, duration: duration)
    }
}
