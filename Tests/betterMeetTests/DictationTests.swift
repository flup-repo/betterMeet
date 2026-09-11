import ArgumentParser
import AppKit
import Carbon.HIToolbox
import AVFoundation
import Foundation
import XCTest
@testable import betterMeet

final class DictationTests: XCTestCase {
    func testBusyStateIncludesModelLoadingAndFinalization() {
        XCTAssertFalse(DictationState.idle.isBusy)
        for state in [DictationState.preparing, .listening, .processing, .inserting] {
            XCTAssertTrue(state.isBusy)
            XCTAssertNotEqual(state.label, "idle")
        }
        XCTAssertTrue(DictationState.processing.canCancel)
        XCTAssertFalse(DictationState.inserting.canCancel)
    }

    func testMultilingualScoringPreservesNumbersAndAccents() {
        XCTAssertEqual(DictationScoring.words("Hello, ROMÂNĂ 649!"), ["hello", "română", "649"])
        XCTAssertEqual(DictationScoring.wordErrorRate(reference: "Bună ziua!", hypothesis: "bună ziua"), 0)
        XCTAssertEqual(DictationScoring.wordErrorRate(reference: "649", hypothesis: "694"), 1)
        XCTAssertEqual(DictationScoring.wordErrorRate(reference: "a b", hypothesis: "a"), 0.5)
        XCTAssertEqual(DictationScoring.wordErrorRate(reference: "a b", hypothesis: "a x b"), 0.5)
        XCTAssertNil(DictationScoring.wordErrorRate(reference: "", hypothesis: "a"))
    }

    func testDictationRequestsDefaultToMultilingualWithoutEnglishVocabulary() throws {
        let request = InferenceRequest(operation: .dictate, samples: [0.1, 0.2])
        let decoded = try JSONDecoder().decode(InferenceRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.settings.model, .v3)
        XCTAssertNil(decoded.settings.vocabularyFile)
        XCTAssertNil(decoded.settings.vocabularyLanguage)
        XCTAssertEqual(decoded.samples, request.samples)
    }

    func testFramedMessagesRoundTripAndRemainSeparate() throws {
        let pipe = Pipe()
        try InferenceWire.write(InferenceReply(text: "Bună ziua.\n你好!", processingSeconds: 0.4),
                                to: pipe.fileHandleForWriting)
        try InferenceWire.write(InferenceReply(text: "Second."), to: pipe.fileHandleForWriting)
        let first = try InferenceWire.read(InferenceReply.self, from: pipe.fileHandleForReading)
        let second = try InferenceWire.read(InferenceReply.self, from: pipe.fileHandleForReading)
        XCTAssertEqual(first.text, "Bună ziua.\n你好!")
        XCTAssertEqual(first.processingSeconds, 0.4)
        XCTAssertEqual(second.text, "Second.")
    }

    func testRejectsOversizedTruncatedAndEmptyFrames() throws {
        for bytes: [UInt8] in [[255, 255, 255, 255], [0, 0, 0, 0], [0, 0, 0, 8, 123], [0, 0]] {
            let pipe = Pipe()
            try pipe.fileHandleForWriting.write(contentsOf: Data(bytes))
            try pipe.fileHandleForWriting.close()
            XCTAssertThrowsError(try InferenceWire.read(InferenceReply.self, from: pipe.fileHandleForReading))
        }
    }

    func testBenchmarkRejectsInvalidRunCounts() throws {
        for count in ["0", "11"] {
            XCTAssertThrowsError(try DictationBenchmark.parse(["/tmp/audio.wav", "--runs", count]))
        }
        XCTAssertNoThrow(try DictationBenchmark.parse(["/tmp/audio.wav", "--runs", "3"]))
    }

    func testAudioStorageStartsEmptyAndClears() throws {
        let audio = DictationAudio()
        XCTAssertTrue(try audio.snapshot().isEmpty)
        XCTAssertFalse(audio.isFull)
        audio.clear()
        XCTAssertTrue(try audio.snapshot().isEmpty)
        XCTAssertEqual(DictationAudio.maximumSamples, 60 * 16_000)
    }

    func testAudioConversionAndSnapshotsAreIndependent() throws {
        // PCM plumbing only, not an ASR quality or latency benchmark.
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<4800 { channel[index] = 0 }
        let audio = DictationAudio()
        try audio.configure(inputFormat: format)
        audio.append(buffer)
        let first = try audio.snapshot()
        XCTAssertFalse(first.isEmpty)
        XCTAssertTrue(first.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(first.count, 1632)
        audio.append(buffer)
        XCTAssertGreaterThan(try audio.snapshot().count, first.count)
        audio.clear()
        XCTAssertTrue(try audio.snapshot().isEmpty)
        XCTAssertFalse(first.isEmpty)
    }

    func testAudioCaptureIsBounded() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<16_000 { channel[index] = 0 }
        let audio = DictationAudio()
        try audio.configure(inputFormat: format)
        for _ in 0..<65 { audio.append(buffer) }
        XCTAssertTrue(audio.isFull)
        XCTAssertEqual(try audio.snapshot().count, DictationAudio.maximumSamples)
    }

    @MainActor
    func testMicrophoneTapRunsOffMainActorAtDeviceSampleRate() async throws {
        let audio = DictationAudio()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 192_000, channels: 2, interleaved: false))
        try audio.configure(inputFormat: format)
        // Use the exact callback installed by start(), not a direct append call.
        // The old actor-inheriting callback traps before reaching audio.append.
        let callback = DictationCapture.makeTapHandler(for: audio)
        try await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 192_000, channels: 2, interleaved: false))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            buffer.frameLength = 4096
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<4096 { channels[channel][frame] = 0 }
            }
            for _ in 0..<4 {
                callback(buffer, AVAudioTime(sampleTime: 0, atRate: 192_000))
            }
        }.value
        let samples = try audio.snapshot()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(samples.count, 1400)
    }

    func testStoppedServiceFailsWithoutLaunchingWorker() async {
        let service = InferenceService()
        await service.shutdown()
        do {
            _ = try await service.request(InferenceRequest(operation: .prepare))
            XCTFail("stopped service must reject work")
        } catch {
            XCTAssertEqual(String(describing: error), "inference service stopped")
        }
    }

    func testSelectionReplacementUsesUTF16AndRejectsInvalidRanges() {
        XCTAssertEqual(DictationDestination.replacement(in: "Hello world", range: CFRange(location: 6, length: 5),
                                                       text: "România"), "Hello România")
        XCTAssertEqual(DictationDestination.replacement(in: "🎤 text", range: CFRange(location: 3, length: 4),
                                                       text: "voce"), "🎤 voce")
        XCTAssertNil(DictationDestination.replacement(in: "abc", range: CFRange(location: -1, length: 0), text: "x"))
        XCTAssertNil(DictationDestination.replacement(in: "abc", range: CFRange(location: 2, length: Int.max), text: "x"))
    }

    func testCustomEditorsDoNotNeedSelectedRangeToAllowPaste() {
        let customEditor = DictationTextState()
        XCTAssertTrue(customEditor.matches(DictationTextState()))
        XCTAssertNil(customEditor.expectedValue(inserting: "Hello"))
        XCTAssertFalse(customEditor.confirmsInsertion("Hello", currentValue: nil))

        let webEditor = DictationTextState(value: "Draft")
        XCTAssertTrue(webEditor.matches(DictationTextState(value: "Draft")))
        XCTAssertFalse(webEditor.matches(DictationTextState(value: "Edited")))
        XCTAssertFalse(webEditor.matches(DictationTextState()))
        XCTAssertNil(webEditor.expectedValue(inserting: " text"))
        XCTAssertTrue(webEditor.confirmsInsertion(" text", currentValue: "Draft text"))
        XCTAssertFalse(webEditor.confirmsInsertion(" text", currentValue: "Draft"))
    }

    func testKnownSelectionAndValueMustStillMatch() {
        let original = DictationTextState(value: "Draft", selection: .init(location: 5, length: 0))
        XCTAssertTrue(original.matches(original))
        XCTAssertFalse(original.matches(DictationTextState(value: "Draft", selection: .init(location: 0, length: 0))))
        XCTAssertFalse(original.matches(DictationTextState(value: "Draft")))
        XCTAssertEqual(original.expectedValue(inserting: " text"), "Draft text")
        XCTAssertTrue(original.confirmsInsertion(" text", currentValue: "Draft text"))
        XCTAssertFalse(original.confirmsInsertion(" text", currentValue: " textDraft"))
    }

    func testTypingOrClickingInvalidatesDestinationButF9DoesNot() {
        XCTAssertFalse(DictationInputPolicy.invalidatesDestination(type: .keyDown, keyCode: UInt16(kVK_F9)))
        XCTAssertTrue(DictationInputPolicy.invalidatesDestination(type: .keyDown, keyCode: UInt16(kVK_ANSI_A)))
        XCTAssertTrue(DictationInputPolicy.invalidatesDestination(type: .leftMouseDown, keyCode: 0))
        XCTAssertTrue(DictationInputPolicy.invalidatesDestination(type: .rightMouseDown, keyCode: 0))
    }

    @MainActor
    func testClipboardRestoresAllFormatsWithoutOverwritingNewerCopy() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: .init("org.bettermeet.test"))
        board.writeObjects([item])
        let saved = try XCTUnwrap(DictationClipboard.capture(from: board))
        board.clearContents()
        board.setString("dictated", forType: .string)
        saved.restore(on: board, ifUnchangedSince: board.changeCount)
        XCTAssertEqual(board.string(forType: .string), "original")
        XCTAssertEqual(board.data(forType: .init("org.bettermeet.test")), Data([1, 2, 3]))
        board.clearContents()
        board.setString("dictated", forType: .string)
        let ownedChange = board.changeCount
        board.clearContents()
        board.setString("new user copy", forType: .string)
        saved.restore(on: board, ifUnchangedSince: ownedChange)
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }

    @MainActor
    func testLargeClipboardDisablesAutomaticPaste() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(Data(repeating: 0, count: 4 * 1024 * 1024 + 1), forType: .init("org.bettermeet.test"))
        XCTAssertNil(DictationClipboard.capture(from: board))
    }
}
