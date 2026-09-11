import ArgumentParser
import AVFoundation
import FluidAudio
import Foundation

/// The same in-memory, multilingual recognition path as F9. No insertion or hooks.
struct DictationBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictation-benchmark",
        abstract: "Measure local dictation on real audio (up to 60 seconds), optionally against a reference."
    )
    @Argument(help: "An existing audio file, up to 60 seconds.")
    var audio: String
    @Option(help: "Manually verified UTF-8 reference text for word error rate.")
    var reference: String?
    @Option(help: "Number of warm runs (1–10).")
    var runs = 3
    @Option(help: "Optional NEW JSON file containing recognized text and timings.")
    var output: String?

    struct Report: Codable {
        let model: String
        let audioSeconds: Double
        let prepareSeconds: Double
        let warmSeconds: [Double]
        let wordErrorRate: Double?
        let referenceWords: Int?
        let text: String?
    }

    func validate() throws {
        guard (1...10).contains(runs) else { throw ValidationError("runs must be between 1 and 10") }
    }

    func run() async throws {
        let url = Transcribe.url(audio)
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.sampleRate > 0,
              Double(file.length) / file.processingFormat.sampleRate <= 60 else {
            throw ValidationError("provide readable audio between 0 and 60 seconds")
        }
        let samples = try AudioConverter().resampleAudioFile(url)
        guard !samples.isEmpty, samples.count <= DictationAudio.maximumSamples,
              samples.allSatisfy(\.isFinite) else { throw ValidationError("invalid audio samples") }
        let referenceText = try reference.map { try String(contentsOf: Transcribe.url($0), encoding: .utf8) }
        if let referenceText, DictationScoring.words(referenceText).isEmpty {
            throw ValidationError("reference must contain manually verified speech")
        }
        let service = InferenceService()
        do {
            let began = ContinuousClock.now
            _ = try await service.request(InferenceRequest(operation: .prepare))
            let prepare = Self.seconds(since: began)
            var timings: [Double] = []
            var text = ""
            for _ in 0..<runs {
                let began = ContinuousClock.now
                let result = try await service.request(InferenceRequest(operation: .dictate, samples: samples))
                timings.append(Self.seconds(since: began))
                text = result.text ?? ""
            }
            await service.shutdown()
            let wer = referenceText.map { DictationScoring.wordErrorRate(reference: $0, hypothesis: text) }
            let count = referenceText.map { DictationScoring.words($0).count }
            func report(includeText: Bool) -> Report {
                Report(model: "parakeet-tdt-0.6b-v3-coreml", audioSeconds: Double(samples.count) / 16_000,
                       prepareSeconds: prepare, warmSeconds: timings, wordErrorRate: wer ?? nil,
                       referenceWords: count, text: includeText ? text : nil)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let output {
                try encoder.encode(report(includeText: true)).write(
                    to: Transcribe.url(output), options: .withoutOverwriting
                )
            }
            // Metrics only on stdout. Recognized content requires an explicit output file.
            print(String(decoding: try encoder.encode(report(includeText: false)), as: UTF8.self))
        } catch {
            await service.shutdown()
            throw error
        }
    }

    private static func seconds(since began: ContinuousClock.Instant) -> Double {
        let value = began.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
}

enum DictationScoring {
    static func words(_ text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted
        return text.precomposedStringWithCanonicalMapping.lowercased()
            .components(separatedBy: separators).filter { !$0.isEmpty }
    }

    static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        let expected = words(reference), actual = words(hypothesis)
        guard !expected.isEmpty else { return nil }
        var previous = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var current = [i + 1]
            for (j, candidate) in actual.enumerated() {
                current.append(min(previous[j] + (word == candidate ? 0 : 1),
                                   previous[j + 1] + 1, current[j] + 1))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(expected.count)
    }
}
