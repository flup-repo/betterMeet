import Foundation
import FluidAudio
import XCTest
@testable import betterMeet

final class TranscriptionTests: XCTestCase {
    func testDefaultsAndInvalidSettings() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(TranscriptionSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(defaults.model, .v3)
        XCTAssertEqual(defaults.speechDetection, .annotate)
        for json in [
            #"{"model":"unknown"}"#, #"{"speech_detection":"aggressive"}"#,
            #"{"model_name":"v3"}"#, #"{"enabled":"true"}"#, #"{"engine":"whisper"}"#,
            #"{"silence_gap_seconds":0}"#, #"{"silence_gap_seconds":6}"#,
            #"{"vocabulary_file":"/tmp/vocabulary.json"}"#,
            #"{"vocabulary_file":"relative.json","vocabulary_language":"en"}"#,
            #"{"vocabulary_file":"/tmp/vocabulary.json","vocabulary_language":"ro"}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(TranscriptionSettings.self, from: Data(json.utf8)))
        }
    }

    func testGroupingPreservesWordsAndPauses() {
        let words = [
            WordTiming(word: "A", startTime: 0, endTime: 0.2),
            WordTiming(word: "quiet", startTime: 1.3, endTime: 1.6),
            WordTiming(word: "reply.", startTime: 1.7, endTime: 2),
            WordTiming(word: "Yes.", startTime: 4, endTime: 4.3),
        ]
        let segments = ParakeetEngine.segments(from: words)
        XCTAssertEqual(segments.map(\.text), ["A quiet reply.", "Yes."])
        XCTAssertEqual(segments.first?.start, 0)
        XCTAssertEqual(segments.first?.end, 2)
    }

    func testHardCapDoesNotLoseWords() {
        let words = (0..<121).map { WordTiming(word: "\($0)", startTime: Double($0), endTime: Double($0) + 0.5) }
        let segments = ParakeetEngine.segments(from: words)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.map(\.text).joined(separator: " "), words.map(\.word).joined(separator: " "))
    }

    func testQuietSpeechIsNotDeleted() {
        var segment = TranscriptSegment(start: 0, end: 1, text: "Yes.", rmsDBFS: -60)
        ParakeetEngine.annotate(&segment, overlapsSpeech: true, mode: .filter)
        XCTAssertFalse(segment.excluded)
        XCTAssertEqual(segment.flags, ["quiet_audio"])
        ParakeetEngine.annotate(&segment, overlapsSpeech: false, mode: .annotate)
        XCTAssertFalse(segment.excluded)
        XCTAssertTrue(segment.flags.contains("no_vad_speech"))
    }

    func testFilteringRemainsAuditable() throws {
        var excluded = TranscriptSegment(start: 0, end: 1, text: "Uncertain.")
        ParakeetEngine.annotate(&excluded, overlapsSpeech: false, mode: .filter)
        let result = TrackTranscription(duration: 2, processingSeconds: 0, rawText: "Uncertain.", segments: [excluded])
        let report = report(result: result)
        let doc = try TranscriptionJob.document(source: URL(fileURLWithPath: "/recording"),
                                               settings: TranscriptionSettings(), reports: [report], processingSeconds: 0)
        XCTAssertTrue(doc.segments.isEmpty)
        XCTAssertEqual(doc.tracks.first?.result?.segments.first?.text, "Uncertain.")
        XCTAssertTrue(doc.tracks.first?.result?.segments.first?.excluded == true)
    }

    func testCorrectionPersistsInBothFormats() throws {
        let corrected = TranscriptSegment(start: 1, end: 2, text: "Correct phrase.",
                                          originalText: "Original phrase.", flags: ["vocabulary_corrected"])
        let track = TrackTranscription(duration: 3, processingSeconds: 0, rawText: "Original phrase.", segments: [corrected])
        let doc = try TranscriptionJob.document(source: URL(fileURLWithPath: "/recording"),
                                               settings: TranscriptionSettings(), reports: [report(result: track)],
                                               processingSeconds: 0)
        XCTAssertEqual(doc.segments.first?.text, "Correct phrase.")
        XCTAssertEqual(doc.segments.first?.original_text, "Original phrase.")
        XCTAssertEqual(doc.segments.first?.start_ms, 1062)
        XCTAssertEqual(doc.segments.first?.end_ms, 2062)
        XCTAssertTrue(doc.rendered().contains("Correct phrase."))
        let roundtrip = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(roundtrip.segments.first?.text, doc.segments.first?.text)
    }

    func testPartialAndFailedStatus() throws {
        let good = report(result: TrackTranscription(duration: 3, processingSeconds: 0, rawText: "", segments: []))
        let bad = report(result: nil)
        for (reports, expected) in [([good, bad], "partial"), ([bad], "failed"), ([good], "complete")] {
            let doc = try TranscriptionJob.document(source: URL(fileURLWithPath: "/recording"),
                                                   settings: TranscriptionSettings(), reports: reports, processingSeconds: 0)
            XCTAssertEqual(doc.status, expected)
        }
    }

    func testInvalidTimestamps() {
        for value in [Double.nan, .infinity, -1, Double(Int.max)] {
            XCTAssertNil(TranscriptionJob.milliseconds(value, offsetMS: 0))
        }
        XCTAssertNil(TranscriptionJob.milliseconds(0, offsetMS: -1))
        XCTAssertEqual(TranscriptionJob.milliseconds(1.5, offsetMS: 62), 1562)
    }

    func testOutputIsExclusiveAndRetryRequiresMatchingSettings() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let output = root.appendingPathComponent("result")
        let settings = TranscriptionSettings()
        XCTAssertThrowsError(try Transcribe.prepareOutput(source: source, destination: source,
                                                          settings: settings, retry: false))
        try Transcribe.prepareOutput(source: source, destination: output, settings: settings, retry: false)
        XCTAssertThrowsError(try Transcribe.prepareOutput(source: source, destination: output,
                                                          settings: settings, retry: false))
        try Transcribe.prepareOutput(source: source, destination: output, settings: settings, retry: true)
        var other = settings
        other.model = .v2
        XCTAssertThrowsError(try Transcribe.prepareOutput(source: source, destination: output,
                                                          settings: other, retry: true))
    }

    func testMissingTracksProduceRetryableReportWithoutModels() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"schema_version":2,"files":{"mic":"mic.aac","system":"system.aac"}}"#.utf8)
            .write(to: root.appendingPathComponent("meta.json"))
        let doc = try await TranscriptionJob.run(source: root, output: root, settings: TranscriptionSettings())
        XCTAssertEqual(doc.status, "failed")
        XCTAssertEqual(doc.tracks.count, 2)
        XCTAssertTrue(doc.tracks.allSatisfy { $0.error != nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".complete").path))
    }

    func testRejectsMetadataPathTraversal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"files":{"mic":"../outside.aac"}}"#.utf8).write(to: root.appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try SessionMeta.read(from: root))
    }

    func testRetryReusesSuccessfulCheckpointAndRejectsChangedSource() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Metadata/cache fixture only. No inference or audio decoding is used.
        let file = root.appendingPathComponent("source.dat")
        try Data("cache identity fixture".utf8).write(to: file)
        try Data(#"{"schema_version":2,"files":{"mic":"source.dat"}}"#.utf8)
            .write(to: root.appendingPathComponent("meta.json"))
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let savedReport = TrackReport(
            file: "source.dat", speaker: "me", offsetMS: 0,
            sourceBytes: values.fileSize, sourceModified: values.contentModificationDate,
            result: TrackTranscription(duration: 1, processingSeconds: 0, rawText: "Saved.",
                                       segments: [TranscriptSegment(start: 0, end: 1, text: "Saved.")]),
            error: nil, warnings: []
        )
        let checkpoint = TranscriptionJob.Checkpoint(
            schemaVersion: 1, source: root.path, settings: TranscriptionSettings(), report: savedReport
        )
        let checkpointURL = root.appendingPathComponent(".transcription-me.json")
        let data = try JSONEncoder().encode(checkpoint)
        try data.write(to: checkpointURL)
        let doc = try await TranscriptionJob.run(source: root, output: root, settings: TranscriptionSettings())
        XCTAssertEqual(doc.segments.first?.text, "Saved.")
        XCTAssertEqual(try Data(contentsOf: checkpointURL), data)
        try Data("changed cache identity fixture".utf8).write(to: file)
        do {
            _ = try await TranscriptionJob.run(source: root, output: root, settings: TranscriptionSettings())
            XCTFail("changed source must not replace a successful checkpoint")
        } catch {
            XCTAssertEqual(try Data(contentsOf: checkpointURL), data)
        }
    }

    private func report(result: TrackTranscription?) -> TrackReport {
        TrackReport(file: "mic.aac", speaker: "me", offsetMS: 62, sourceBytes: nil, sourceModified: nil,
                    result: result, error: result == nil ? "missing" : nil, warnings: [])
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
