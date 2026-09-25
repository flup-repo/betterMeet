import AVFoundation
import FluidAudio
import Synchronization
import XCTest
@testable import betterMeet

final class PerformanceTests: XCTestCase {
    func testRequestSamplesTravelAsRawFloatsBeyondTheOldJSONLimit() throws {
        // 180 s exceeded the 32 MiB frame as JSON (~13 bytes per sample).
        let samples = (0..<(180 * 16_000)).map { Float($0 % 2000) / 2000 - 0.5 }
        let pipe = Pipe()
        let writer = Thread {
            try? InferenceWire.writeRequest(InferenceRequest(operation: .dictate, samples: samples),
                                            to: pipe.fileHandleForWriting)
            try? InferenceWire.write(InferenceReply(text: "after"), to: pipe.fileHandleForWriting)
        }
        writer.start()
        let request = try InferenceWire.readRequest(from: pipe.fileHandleForReading, maximumSamples: samples.count)
        XCTAssertEqual(request.operation, .dictate)
        XCTAssertEqual(request.samples, samples)
        XCTAssertNil(request.sampleCount)
        // Framing stays aligned for the next message.
        XCTAssertEqual(try InferenceWire.read(InferenceReply.self, from: pipe.fileHandleForReading).text, "after")
    }

    func testRequestsWithoutSamplesAndOversizedSampleFrames() throws {
        let pipe = Pipe()
        try InferenceWire.writeRequest(InferenceRequest(operation: .meeting, track: "me"), to: pipe.fileHandleForWriting)
        let meeting = try InferenceWire.readRequest(from: pipe.fileHandleForReading, maximumSamples: 10)
        XCTAssertEqual(meeting.track, "me")
        XCTAssertNil(meeting.samples)

        try InferenceWire.writeRequest(InferenceRequest(operation: .dictate, samples: [0, 0, 0]),
                                       to: pipe.fileHandleForWriting)
        XCTAssertThrowsError(try InferenceWire.readRequest(from: pipe.fileHandleForReading, maximumSamples: 2))
    }

    func testProgressIsForwardedInWholeFivePercentSteps() {
        let seen = Mutex<[Double]>([])
        let throttle = ProgressThrottle { value in seen.withLock { $0.append(value) } }
        for value in [0, 0.01, 0.049, 0.05, 0.07, 0.5, 0.4, 1, 1] { throttle.report(value) }
        XCTAssertEqual(seen.withLock { $0 }, [0, 0.05, 0.5, 1])
    }

    func testStreamingDecoderAveragesChannelsAndResamples() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 2, interleaved: false))
        // Three seconds: longer than one decoder chunk, so chunk boundaries are exercised.
        let frames: AVAudioFrameCount = 144_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            channels[0][frame] = 0.8
            channels[1][frame] = 0.2
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        let samples = try AudioDecoder.decodeMono16k(url)
        XCTAssertEqual(Double(samples.count), 48_000, accuracy: 64)
        // Steady state is the channel average, not the left channel.
        let middle = samples[20_000..<28_000]
        XCTAssertEqual(Double(middle.min() ?? 0), 0.5, accuracy: 0.01)
        XCTAssertEqual(Double(middle.max() ?? 0), 0.5, accuracy: 0.01)
    }

    func testDownmixHandlesInterleavedInput() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 2, interleaved: true))
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                              channels: 1, interleaved: false))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        input.frameLength = 4
        let data = try XCTUnwrap(input.floatChannelData?[0])
        for frame in 0..<4 {
            data[frame * 2] = 1
            data[frame * 2 + 1] = Float(frame) / 4
        }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4))
        try AudioDecoder.downmix(input, into: output)
        XCTAssertEqual(output.frameLength, 4)
        let result = Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: 4))
        XCTAssertEqual(result, [0.5, 0.625, 0.75, 0.875])
    }

    func testPeakUsesAllChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        for channel in 0..<2 {
            for frame in 0..<8 { buffer.floatChannelData![channel][frame] = 0 }
        }
        buffer.floatChannelData![1][5] = -0.3
        XCTAssertEqual(MicRecorder.peak(of: buffer), 0.3)
    }

    func testSpeechOverlapCursorMatchesExhaustiveSearch() {
        let speech = [(0.0, 1.0), (2.0, 2.5), (5.0, 9.0), (12.0, 12.1)].map {
            VadSegment(startTime: $0.0, endTime: $0.1)
        }
        let segments = [(0.0, 0.5), (1.1, 1.7), (3.0, 4.0), (4.9, 5.0), (9.1, 11.0), (11.5, 11.85), (13.0, 14.0)]
        var cursor = 0
        for (start, end) in segments {
            let expected = speech.contains { $0.startTime < end + 0.2 && $0.endTime > start - 0.2 }
            XCTAssertEqual(ParakeetEngine.overlapsSpeech(speech, start: start, end: end, cursor: &cursor), expected,
                           "segment \(start)-\(end)")
        }
    }

    func testRmsMatchesDirectComputation() throws {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        XCTAssertEqual(try XCTUnwrap(ParakeetEngine.rmsDBFS(samples[...])), 20 * log10(0.5), accuracy: 1e-4)
        XCTAssertNil(ParakeetEngine.rmsDBFS([Float]()[...]))
    }

    func testDictationCommitsLongAudioAtTheQuietestPoint() throws {
        XCTAssertNil(DictationChunking.splitPoint([Float](repeating: 0.1, count: 19 * 16_000)))
        var samples = [Float](repeating: 0.2, count: 24 * 16_000)
        for index in (12 * 16_000)..<(12 * 16_000 + 3_200) { samples[index] = 0 }
        let split = try XCTUnwrap(DictationChunking.splitPoint(samples))
        XCTAssertGreaterThanOrEqual(split, 12 * 16_000)
        XCTAssertLessThanOrEqual(split, 12 * 16_000 + 3_200)
        // The most recent audio is never committed.
        let silentEnd = [Float](repeating: 0.2, count: 22 * 16_000) + [Float](repeating: 0, count: 2 * 16_000)
        XCTAssertLessThanOrEqual(try XCTUnwrap(DictationChunking.splitPoint(silentEnd)),
                                 silentEnd.count - DictationChunking.keepTailSamples)
        XCTAssertEqual(DictationChunking.join("", "Hello."), "Hello.")
        XCTAssertEqual(DictationChunking.join("Hello.", ""), "Hello.")
        XCTAssertEqual(DictationChunking.join("Hello.", "World."), "Hello. World.")
    }

    func testTailSnapshotsStartAtTheCommittedOffset() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_000))
        buffer.frameLength = 1_000
        for index in 0..<1_000 { buffer.floatChannelData![0][index] = Float(index) / 1_000 }
        let audio = DictationAudio()
        try audio.configure(inputFormat: format)
        audio.append(buffer)
        audio.append(buffer)
        let all = try audio.snapshot()
        XCTAssertEqual(audio.count, all.count)
        XCTAssertEqual(try audio.snapshot(from: 600), Array(all[600...]))
        XCTAssertTrue(try audio.snapshot(from: all.count + 5).isEmpty)
    }

    func testTrackRunRejectsUnknownTracksWithoutModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"schema_version":2,"files":{"mic":"mic.aac"}}"#.utf8)
            .write(to: root.appendingPathComponent("meta.json"))
        do {
            try await TranscriptionJob.runTrack("them", source: root, output: root,
                                                settings: TranscriptionSettings(), engine: ParakeetEngine())
            XCTFail("unknown track must be rejected")
        } catch {
            XCTAssertEqual(String(describing: error), "unknown track")
        }
        // A missing file is reported per track, not thrown, and never checkpointed.
        try await TranscriptionJob.runTrack("me", source: root, output: root,
                                            settings: TranscriptionSettings(), engine: ParakeetEngine())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".transcription-me.json").path))
    }
}

final class SystemAudioPoolTests: XCTestCase {
    /// The IO proc hands the pool a buffer list it doesn't own; the copy must
    /// carry the samples for both layouts a process tap can report.
    func testPoolCopiesInterleavedAndPlanarBufferLists() throws {
        for interleaved in [true, false] {
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                                    channels: 2, interleaved: interleaved))
            let source = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            source.frameLength = 512
            let list = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
            var value: Float = 0
            for buffer in list {
                let floats = buffer.mData!.assumingMemoryBound(to: Float.self)
                for index in 0..<(Int(buffer.mDataByteSize) / 4) {
                    value += 0.001
                    floats[index] = value
                }
            }
            let pool = PCMBufferPool(format: format, frameCapacity: 4096, count: 2)
            let copy = try XCTUnwrap(pool.copy(UnsafePointer(source.mutableAudioBufferList)))
            XCTAssertEqual(copy.frameLength, 512, "interleaved=\(interleaved)")
            let copied = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            XCTAssertEqual(copied.count, list.count)
            for (original, duplicate) in zip(list, copied) {
                XCTAssertEqual(duplicate.mDataByteSize, original.mDataByteSize)
                XCTAssertEqual(memcmp(duplicate.mData!, original.mData!, Int(original.mDataByteSize)), 0)
            }
            XCTAssertGreaterThan(MicRecorder.peak(of: copy), 0)
            // Written to a real AAC file, the audio must survive.
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).aac")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let file = try AVAudioFile(forWriting: url, settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
                ], commonFormat: .pcmFormatFloat32, interleaved: interleaved)
                for _ in 0..<40 {
                    let chunk = try XCTUnwrap(pool.copy(UnsafePointer(source.mutableAudioBufferList)))
                    try file.write(from: chunk)
                    pool.recycle(chunk)
                }
            }
            let decoded = try AudioDecoder.decodeMono16k(url)
            XCTAssertGreaterThan(decoded.map(abs).max() ?? 0, 0.01, "interleaved=\(interleaved)")
            pool.recycle(copy)
        }
    }
}
