import Foundation

struct TrackReport: Codable, Sendable {
    let file: String
    let speaker: String
    let offsetMS: Int
    let sourceBytes: Int?
    let sourceModified: Date?
    let result: TrackTranscription?
    let error: String?
    let warnings: [String]
}

struct TranscriptDocument: Codable, Sendable {
    struct Segment: Codable, Sendable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
        let original_text: String?
        let flags: [String]
        let rms_dbfs: Double?
    }

    let schema_version: Int
    let engine: String
    let model: String
    let encoder_precision: String
    let fluidaudio_version: String
    let created_at: String
    let source: String
    let settings: TranscriptionSettings
    let status: String
    let processing_seconds: Double
    let tracks: [TrackReport]
    let segments: [Segment]

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Data(rendered().utf8).write(to: directory.appendingPathComponent("transcript.md"), options: .atomic)
        try encoder.encode(self).write(to: directory.appendingPathComponent("transcript.json"), options: .atomic)
    }

    func rendered() -> String {
        var lines = ["# \(URL(fileURLWithPath: source).lastPathComponent)", "",
                     "engine: \(engine) (\(model))", "", "status: \(status)", ""]
        if status != "complete" {
            lines += ["**Warning: transcription is incomplete. See track reports in transcript.json.**", ""]
        }
        for segment in segments {
            let seconds = segment.start_ms / 1000
            let clock = String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            lines += ["**[\(clock)] \(segment.speaker):** \(segment.text)", ""]
        }
        return lines.joined(separator: "\n")
    }
}

/// Shared by the daemon and the offline CLI. Successful tracks are checkpointed
/// independently so retrying a failed track does not overwrite successful work.
enum TranscriptionJob {
    struct Checkpoint: Codable {
        let schemaVersion: Int
        let source: String
        let settings: TranscriptionSettings
        let report: TrackReport
    }

    static func run(source: URL, output: URL, settings: TranscriptionSettings,
                    preparedEngine: ParakeetEngine? = nil,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> TranscriptDocument {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let meta = try SessionMeta.read(from: source)
        var settings = settings
        try settings.resolveVocabulary()
        let began = Date()
        let engine = preparedEngine ?? ParakeetEngine(settings: settings)
        var reports: [TrackReport] = []
        do {
            for track in meta.tracks {
                reports.append(try await report(for: track, meta: meta, source: source, output: output,
                                                settings: settings, engine: engine, progress: progress))
            }
        } catch {
            if preparedEngine == nil { await engine.release() }
            throw error
        }
        if preparedEngine == nil { await engine.release() }
        // Tracks transcribed by earlier per-track requests come from their
        // checkpoints, so wall time here is only the assembly; report at least
        // the tracks' own recognition time.
        let trackSeconds = reports.compactMap { $0.result?.processingSeconds }.reduce(0, +)
        let document = try document(source: source, settings: settings, reports: reports,
                                    processingSeconds: max(Date().timeIntervalSince(began), trackSeconds))
        try document.write(to: output)
        cleanupSuccessfulOutput(document, in: output)
        return document
    }

    /// Transcribe and checkpoint one track only. A later `run` over the same
    /// output reuses the checkpoint, so a meeting can be processed track by
    /// track with dictation allowed to run in between.
    static func runTrack(_ speaker: String, source: URL, output: URL, settings: TranscriptionSettings,
                         engine: ParakeetEngine, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let meta = try SessionMeta.read(from: source)
        guard let track = meta.tracks.first(where: { $0.speaker == speaker }) else {
            throw TranscriptionFailure("unknown track")
        }
        var settings = settings
        try settings.resolveVocabulary()
        _ = try await report(for: track, meta: meta, source: source, output: output,
                             settings: settings, engine: engine, progress: progress)
    }

    /// A saved checkpoint when it still matches the source and settings,
    /// otherwise a fresh transcription (checkpointed on success).
    private static func report(for track: SessionMeta.Track, meta: SessionMeta, source: URL, output: URL,
                               settings: TranscriptionSettings, engine: ParakeetEngine,
                               progress: (@Sendable (Double) -> Void)?) async throws -> TrackReport {
        let audio = source.appendingPathComponent(track.file)
        let values = try? audio.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let checkpointURL = output.appendingPathComponent(".transcription-\(track.speaker).json")
        if let data = try? Data(contentsOf: checkpointURL),
           let saved = try? JSONDecoder().decode(Checkpoint.self, from: data),
           saved.schemaVersion == 1, saved.source == source.path,
           saved.settings == settings, saved.report.file == track.file,
           saved.report.offsetMS == track.offsetMs,
           saved.report.sourceBytes == values?.fileSize,
           saved.report.sourceModified == values?.contentModificationDate,
           saved.report.result != nil, saved.report.error == nil {
            return saved.report
        }
        // Never replace a successful checkpoint under different settings.
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            throw TranscriptionFailure("checkpoint differs from source/settings; use a new output directory")
        }
        let report: TrackReport
        do {
            guard audio.resolvingSymlinksInPath().deletingLastPathComponent() == source else {
                throw TranscriptionFailure("audio must reside inside the recording directory")
            }
            guard FileManager.default.fileExists(atPath: audio.path) else {
                throw TranscriptionFailure("missing audio file")
            }
            try await engine.prepare()
            let result = try await engine.transcribe(audio, progress: progress)
            var warnings: [String] = []
            if let duration = meta.duration,
               abs(result.duration + Double(track.offsetMs) / 1000 - duration) > 5 {
                warnings.append("decoded duration differs from session duration by more than 5 seconds")
            }
            report = TrackReport(file: track.file, speaker: track.speaker, offsetMS: track.offsetMs,
                                 sourceBytes: values?.fileSize, sourceModified: values?.contentModificationDate,
                                 result: result, error: nil, warnings: warnings)
        } catch {
            report = TrackReport(file: track.file, speaker: track.speaker, offsetMS: track.offsetMs,
                                 sourceBytes: values?.fileSize, sourceModified: values?.contentModificationDate,
                                 result: nil, error: String(describing: error), warnings: [])
        }
        if report.result != nil {
            let saved = Checkpoint(schemaVersion: 1, source: source.path, settings: settings, report: report)
            try JSONEncoder().encode(saved).write(to: checkpointURL, options: .atomic)
        }
        return report
    }

    static func cleanupSuccessfulOutput(_ document: TranscriptDocument, in output: URL) {
        guard document.status == "complete" else { return }
        // Retry data is redundant only after both final transcripts are saved.
        // Leave the lock file in place: unlinking it can bypass an active flock.
        for name in [".transcription-me.json", ".transcription-them.json", "transcribe.log"] {
            try? FileManager.default.removeItem(at: output.appendingPathComponent(name))
        }
    }

    static func document(source: URL, settings: TranscriptionSettings, reports: [TrackReport],
                         processingSeconds: Double) throws -> TranscriptDocument {
        var merged: [TranscriptDocument.Segment] = []
        for track in reports {
            for segment in track.result?.segments ?? [] where !segment.excluded {
                guard let start = milliseconds(segment.start, offsetMS: track.offsetMS),
                      let end = milliseconds(segment.end, offsetMS: track.offsetMS), end >= start else {
                    throw TranscriptionFailure("invalid segment timestamp")
                }
                merged.append(.init(speaker: track.speaker, start_ms: start, end_ms: end, text: segment.text,
                                    original_text: segment.originalText, flags: segment.flags,
                                    rms_dbfs: segment.rmsDBFS))
            }
        }
        merged.sort { ($0.start_ms, $0.speaker, $0.end_ms) < ($1.start_ms, $1.speaker, $1.end_ms) }
        let succeeded = reports.filter { $0.result != nil }.count
        let status = succeeded == 0 ? "failed" :
            (succeeded == reports.count && reports.allSatisfy { $0.warnings.isEmpty } ? "complete" : "partial")
        return TranscriptDocument(
            schema_version: 2, engine: "parakeet", model: "parakeet-tdt-0.6b-\(settings.model.rawValue)-coreml",
            encoder_precision: "int8", fluidaudio_version: "0.15.5",
            created_at: ISO8601DateFormatter().string(from: Date()), source: source.path, settings: settings,
            status: status, processing_seconds: processingSeconds, tracks: reports, segments: merged
        )
    }

    static func milliseconds(_ seconds: Double, offsetMS: Int) -> Int? {
        let value = seconds * 1000 + Double(offsetMS)
        guard seconds.isFinite, seconds >= 0, offsetMS >= 0,
              value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
        return Int(value)
    }
}
