import Accelerate
import AVFoundation
import FluidAudio
import Foundation

/// Local ASR with optional audio-backed vocabulary rescoring and speech diagnostics.
actor ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "parakeet engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    nonisolated let name = "parakeet"
    nonisolated let model: String
    private let settings: TranscriptionSettings
    private let models: ParakeetModels
    private let ownsModels: Bool

    private var manager: AsrManager?
    private var vad: VadManager?
    private var vocabulary: CustomVocabularyContext?
    private var spotter: CtcKeywordSpotter?
    private var rescorer: VocabularyRescorer?

    /// Pass a shared `models` cache to reuse loaded recognizers across engines
    /// with different settings; the cache owner then releases it.
    init(settings: TranscriptionSettings = TranscriptionSettings(), models: ParakeetModels? = nil) {
        self.settings = settings
        self.models = models ?? ParakeetModels()
        ownsModels = models == nil
        model = "parakeet-tdt-0.6b-\(settings.model.rawValue)-coreml"
    }

    func prepare() async throws {
        guard manager == nil else { return }
        try settings.validate()
        let manager = try await models.asr(settings.model)
        if settings.speechDetection != .off {
            vad = try await models.vad()
        }
        if let path = settings.vocabularyFile {
            let (vocabulary, models) = try await CustomVocabularyContext.loadWithCtcTokens(from: path)
            let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
            self.vocabulary = vocabulary
            self.spotter = spotter
            rescorer = try await VocabularyRescorer.create(
                spotter: spotter, vocabulary: vocabulary,
                config: .init(shortTermCbwTaperPivot: 5, spotterRescueEnabled: false),
                ctcModelDirectory: CtcModels.defaultCacheDirectory(for: models.variant)
            )
        }
        self.manager = manager
    }

    func transcribe(_ audio: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws -> TrackTranscription {
        // A track with no frames (recorder died before its first buffer)
        // makes AVFoundation raise an ObjC exception deep inside the
        // resampler — uncatchable from Swift, so it takes the whole daemon
        // down. Check readability up front instead.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        // Decode once, streaming. Duration is based on decoded PCM, not unreliable ADTS estimates.
        let samples = try AudioDecoder.decodeMono16k(audio)
        guard !samples.isEmpty else { throw EngineError.unreadableAudio(audio, nil) }
        return try await transcribe(samples: samples, progress: progress)
    }

    /// Dictation supplies mono 16 kHz PCM directly, without temporary recordings.
    func transcribe(samples: [Float], progress: (@Sendable (Double) -> Void)? = nil) async throws -> TrackTranscription {
        guard let manager else { throw EngineError.notPrepared }
        guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
            throw TranscriptionFailure("invalid audio samples")
        }
        let began = Date()
        let duration = Double(samples.count) / 16_000
        var state = try TdtDecoderState()
        // FluidAudio reports progress only for audio past one model window.
        var progressTask: Task<Void, Never>?
        if let progress {
            let stream = await manager.transcriptionProgressStream
            progressTask = Task {
                do {
                    for try await value in stream { progress(value) }
                } catch {}
            }
        }
        defer { progressTask?.cancel() }
        let result = try await manager.transcribe(samples, decoderState: &state)
        progress?(1)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        var segments = Self.segments(from: words, silenceGap: settings.silenceGap)
        if words.isEmpty {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            segments = text.isEmpty ? [] : [TranscriptSegment(
                start: 0, end: duration, text: text, flags: ["missing_word_timings"]
            )]
        }
        let speech = try await vad?.segmentSpeech(samples, config: VadSegmentationConfig(
            minSpeechDuration: 0.1, minSilenceDuration: 0.75,
            maxSpeechDuration: .infinity, speechPadding: 0.1
        ))
        let tokenTimings = result.tokenTimings ?? []
        // Segments, VAD spans and tokens are all time-ordered; walk them with
        // cursors instead of rescanning every list for each segment.
        var speechCursor = 0
        var tokenCursor = 0
        for index in segments.indices {
            let segment = segments[index]
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end >= segment.start,
                  segment.end <= duration + 1 else {
                throw TranscriptionFailure("ASR returned invalid or out-of-range timings")
            }
            let lower = min(samples.count, Int(segment.start * 16_000))
            let upper = min(samples.count, Int(segment.end * 16_000))
            segments[index].rmsDBFS = Self.rmsDBFS(samples[lower..<upper])
            if let speech {
                let overlaps = Self.overlapsSpeech(speech, start: segment.start, end: segment.end,
                                                   cursor: &speechCursor)
                Self.annotate(&segments[index], overlapsSpeech: overlaps, mode: settings.speechDetection)
            }
            if let vocabulary, let spotter, let rescorer, !segments[index].excluded,
               !words.isEmpty {
                // Rescore bounded spans, retaining their original timing and text.
                // Never rebuild corrected output from the uncorrected token strings.
                let from = max(0, lower - 3_200)
                let to = min(samples.count, upper + 3_200)
                let offset = Double(from) / 16_000
                while tokenCursor < tokenTimings.count, tokenTimings[tokenCursor].startTime < segment.start {
                    tokenCursor += 1
                }
                var timings: [TokenTiming] = []
                var scan = tokenCursor
                while scan < tokenTimings.count, tokenTimings[scan].startTime <= segment.end {
                    let token = tokenTimings[scan]
                    if token.endTime <= segment.end + 0.001 {
                        timings.append(TokenTiming(token: token.token, tokenId: token.tokenId,
                                                   startTime: token.startTime - offset,
                                                   endTime: token.endTime - offset,
                                                   confidence: token.confidence))
                    }
                    scan += 1
                }
                guard !timings.isEmpty else { continue }
                let evidence = try await spotter.spotKeywordsWithLogProbs(
                    audioSamples: Array(samples[from..<to]), customVocabulary: vocabulary, minScore: nil
                )
                guard !evidence.logProbs.isEmpty else { continue }
                let bias = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
                let corrected = rescorer.ctcTokenRescore(
                    transcript: segment.text, tokenTimings: timings,
                    logProbs: evidence.logProbs, frameDuration: evidence.frameDuration,
                    cbw: bias.cbw, minSimilarity: max(bias.minSimilarity, vocabulary.minSimilarity)
                )
                if corrected.wasModified, !corrected.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments[index] = TranscriptSegment(
                        start: segment.start, end: segment.end, text: corrected.text,
                        originalText: segment.text, flags: segments[index].flags + ["vocabulary_corrected"],
                        rmsDBFS: segments[index].rmsDBFS
                    )
                }
            }
        }
        return TrackTranscription(duration: duration, processingSeconds: Date().timeIntervalSince(began),
                                  rawText: result.text, segments: segments)
    }

    func release() async {
        if ownsModels { await models.release() }
        manager = nil
        vad = nil
        vocabulary = nil
        spotter = nil
        rescorer = nil
    }

    static func rmsDBFS(_ samples: ArraySlice<Float>) -> Double? {
        guard !samples.isEmpty else { return nil }
        let power = samples.withUnsafeBufferPointer { buffer -> Double in
            var sum: Float = 0
            vDSP_svesq(buffer.baseAddress!, 1, &sum, vDSP_Length(buffer.count))
            return Double(sum) / Double(buffer.count)
        }
        return 10 * log10(max(power, 1e-12))
    }

    /// Whether any VAD span overlaps [start, end] with 0.2 s tolerance.
    /// `cursor` only moves forward, since segments arrive in time order.
    static func overlapsSpeech(_ speech: [VadSegment], start: Double, end: Double, cursor: inout Int) -> Bool {
        while cursor < speech.count, speech[cursor].endTime <= start - 0.2 {
            cursor += 1
        }
        var index = cursor
        while index < speech.count, speech[index].startTime < end + 0.2 {
            if speech[index].endTime > start - 0.2 { return true }
            index += 1
        }
        return false
    }

    static func annotate(_ segment: inout TranscriptSegment, overlapsSpeech: Bool,
                         mode: TranscriptionSettings.SpeechDetection) {
        if !overlapsSpeech {
            segment.flags.append("no_vad_speech")
            segment.excluded = mode == .filter
        }
        if let rms = segment.rmsDBFS, rms < -45 {
            segment.flags.append("quiet_audio")
        }
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation (parakeet v2 emits punctuation), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps.
    static func segments(from words: [WordTiming], silenceGap: Double = 1.5) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(TranscriptSegment(
                start: first.startTime,
                end: last.endTime,
                text: current.map(\.word).joined(separator: " ")
            ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > silenceGap {
                flush()
            }
            current.append(word)
            let endsSentence = word.word.hasSuffix(".")
                || word.word.hasSuffix("?")
                || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }
}

/// Loaded recognizer models, shared by every engine in one process so that
/// switching between dictation and meeting settings never reloads them.
actor ParakeetModels {
    private var asrTasks: [TranscriptionSettings.Model: Task<AsrManager, Error>] = [:]
    private var vadTask: Task<VadManager, Error>?

    func asr(_ version: TranscriptionSettings.Model) async throws -> AsrManager {
        if let task = asrTasks[version] { return try await task.value }
        let task = Task {
            let models = try await AsrModels.downloadAndLoad(
                version: version == .v2 ? .v2 : .v3, encoderPrecision: .int8
            )
            let manager = AsrManager()
            try await manager.loadModels(models)
            return manager
        }
        asrTasks[version] = task
        do {
            return try await task.value
        } catch {
            asrTasks[version] = nil
            throw error
        }
    }

    func vad() async throws -> VadManager {
        if let vadTask { return try await vadTask.value }
        let task = Task { try await VadManager(config: VadConfig(defaultThreshold: 0.5)) }
        vadTask = task
        do {
            return try await task.value
        } catch {
            vadTask = nil
            throw error
        }
    }

    func release() async {
        for task in asrTasks.values {
            if let manager = try? await task.value { await manager.cleanup() }
        }
        asrTasks = [:]
        vadTask = nil
    }
}
