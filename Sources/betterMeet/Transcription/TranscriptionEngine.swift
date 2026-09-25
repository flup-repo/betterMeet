import Foundation

/// One timed span of recognized speech from a single track, relative to that
/// track's own start.
struct TranscriptSegment: Codable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    var originalText: String? = nil
    var flags: [String] = []
    var rmsDBFS: Double? = nil
    var excluded: Bool = false
}

struct TrackTranscription: Codable, Sendable {
    let duration: Double
    let processingSeconds: Double
    let rawText: String
    let segments: [TranscriptSegment]
}

/// A speech-to-text engine betterMeet can run locally. Engines are prepared lazily
/// (model download + load) when the transcription queue has work and released
/// when it drains, so betterMeet never idles holding gigabytes of model weights.
protocol TranscriptionEngine: Sendable {
    /// Short engine identifier recorded as transcript.json provenance.
    var name: String { get }
    /// Concrete model identifier recorded as transcript.json provenance.
    var model: String { get }
    func prepare() async throws
    /// `progress` receives 0...1 for long audio; it may be called from any task.
    func transcribe(_ audio: URL, progress: (@Sendable (Double) -> Void)?) async throws -> TrackTranscription
    func release() async
}

extension TranscriptionEngine {
    func transcribe(_ audio: URL) async throws -> TrackTranscription {
        try await transcribe(audio, progress: nil)
    }
}
