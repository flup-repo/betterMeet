import ArgumentParser
import Darwin
import Foundation

struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-transcribe a recording into a NEW directory, without hooks or changes to the recording."
    )

    @Argument(help: "Existing recording directory containing meta.json.")
    var session: String

    @Option(name: .long, help: "Separate output directory. Its parent must exist.")
    var output: String

    @Option(name: .long, help: "Model: v2 (English) or v3 (multilingual).")
    var model: String?

    @Option(name: .long, help: "Speech detection: off, annotate (default), or filter (experimental).")
    var speechDetection: String?

    @Option(name: .long, help: "Absolute path to a FluidAudio vocabulary JSON file.")
    var vocabularyFile: String?

    @Flag(name: .long, help: "Declare this recording English-only for auxiliary CTC vocabulary rescoring.")
    var englishVocabulary = false

    @Flag(name: .long, help: "Disable vocabulary even when configured.")
    var noVocabulary = false

    @Flag(name: .long, help: "Retry failed tracks in a previous output, preserving successful checkpoints.")
    var retry = false

    func run() async throws {
        var settings = try Config.transcriptionSettings()
        if let model {
            guard let value = TranscriptionSettings.Model(rawValue: model) else {
                throw ValidationError("model must be v2 or v3")
            }
            settings.model = value
        }
        if let speechDetection {
            guard let value = TranscriptionSettings.SpeechDetection(rawValue: speechDetection) else {
                throw ValidationError("speech-detection must be off, annotate, or filter")
            }
            settings.speechDetection = value
        }
        if noVocabulary && (vocabularyFile != nil || englishVocabulary) {
            throw ValidationError("--no-vocabulary cannot be combined with vocabulary options")
        }
        if let vocabularyFile { settings.vocabularyFile = vocabularyFile }
        if englishVocabulary { settings.vocabularyLanguage = "en" }
        if noVocabulary {
            settings.vocabularyFile = nil
            settings.vocabularyLanguage = nil
            settings.vocabularySHA256 = nil
        }
        try settings.resolveVocabulary()
        let source = Self.url(session)
        let destination = Self.url(output)
        _ = try SessionMeta.read(from: source)
        try Self.prepareOutput(source: source, destination: destination, settings: settings, retry: retry)
        print("Transcribing locally. First use may download model weights.")
        let result = try await TranscriptionWorker.transcribe(source: source, output: destination, settings: settings)
        print("\(result.status): \(result.segments.count) segments → \(destination.path)")
        guard result.status == "complete" else {
            throw TranscriptionFailure("see transcript.json for per-track errors and coverage warnings")
        }
    }

    struct Manifest: Codable, Equatable {
        let source: String
        let settings: TranscriptionSettings
    }

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    static func prepareOutput(source: URL, destination: URL, settings: TranscriptionSettings, retry: Bool) throws {
        guard destination != source, !destination.path.hasPrefix(source.path + "/") else {
            throw TranscriptionFailure("output must be outside the original recording directory")
        }
        let marker = destination.appendingPathComponent(".bettermeet-retranscription.json")
        let expected = Manifest(source: source.path, settings: settings)
        if retry {
            let saved = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: marker))
            guard saved == expected else {
                throw TranscriptionFailure("retry source/settings differ; choose a new output directory")
            }
        } else {
            // mkdir is exclusive, unlike FileManager's createDirectory.
            guard mkdir(destination.path, 0o700) == 0 else {
                throw TranscriptionFailure("output must not exist and its parent must exist")
            }
            try JSONEncoder().encode(expected).write(to: marker, options: .atomic)
        }
    }
}
