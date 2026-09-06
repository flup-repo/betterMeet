import CryptoKit
import Foundation

struct TranscriptionSettings: Codable, Equatable, Sendable {
    enum Model: String, Codable, Sendable { case v2, v3 }
    enum SpeechDetection: String, Codable, Sendable { case off, annotate, filter }

    var model: Model = .v3
    var speechDetection: SpeechDetection = .annotate
    var vocabularyFile: String?
    // The auxiliary CTC model is English. An explicit declaration is required.
    var vocabularyLanguage: String?
    var vocabularySHA256: String?
    var silenceGap: Double = 1.5

    enum CodingKeys: String, CodingKey, CaseIterable {
        case model
        case speechDetection = "speech_detection"
        case vocabularyFile = "vocabulary_file"
        case vocabularyLanguage = "vocabulary_language"
        case vocabularySHA256 = "vocabulary_sha256"
        case silenceGap = "silence_gap_seconds"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let object = try decoder.container(keyedBy: SettingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue) + ["enabled", "engine"])
        guard object.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw TranscriptionFailure("unknown transcription setting")
        }
        _ = try object.decodeIfPresent(Bool.self, forKey: SettingKey("enabled"))
        if let engine = try object.decodeIfPresent(String.self, forKey: SettingKey("engine")), engine != "parakeet" {
            throw TranscriptionFailure("only the parakeet engine is supported")
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(Model.self, forKey: .model) ?? .v3
        speechDetection = try c.decodeIfPresent(SpeechDetection.self, forKey: .speechDetection) ?? .annotate
        vocabularyFile = try c.decodeIfPresent(String.self, forKey: .vocabularyFile)
        vocabularyLanguage = try c.decodeIfPresent(String.self, forKey: .vocabularyLanguage)
        vocabularySHA256 = try c.decodeIfPresent(String.self, forKey: .vocabularySHA256)
        silenceGap = try c.decodeIfPresent(Double.self, forKey: .silenceGap) ?? 1.5
        try validate()
    }

    func validate() throws {
        guard silenceGap.isFinite, (0.5...5).contains(silenceGap) else {
            throw TranscriptionFailure("silence_gap_seconds must be between 0.5 and 5")
        }
        guard vocabularyLanguage == nil || vocabularyLanguage == "en" else {
            throw TranscriptionFailure("auxiliary vocabulary rescoring supports English-only recordings")
        }
        if let vocabularyFile {
            guard vocabularyFile.hasPrefix("/") || vocabularyFile.hasPrefix("~/"),
                  vocabularyLanguage == "en" else {
                throw TranscriptionFailure(
                    "vocabulary_file requires an absolute path and vocabulary_language: \"en\"; "
                    + "enable only for English recordings, not mixed-language meetings"
                )
            }
        }
    }

    mutating func resolveVocabulary() throws {
        try validate()
        if let vocabularyFile {
            let path = (vocabularyFile as NSString).expandingTildeInPath
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            self.vocabularyFile = path
            vocabularySHA256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            vocabularySHA256 = nil
        }
    }
}

private struct SettingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

struct TranscriptionFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
