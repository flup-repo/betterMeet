@preconcurrency import AVFoundation
import Accelerate
import Foundation

/// Streams an audio file to mono 16 kHz Float32 in fixed-size chunks.
///
/// FluidAudio's `resampleAudioFile` first collects the whole track at the
/// source rate, copies it into one buffer and resamples that: ~1.6 GB peak for
/// an hour at 48 kHz. Chunked conversion keeps only the output (~230 MB per
/// hour) plus a few small buffers. Channels are averaged; AVAudioConverter's
/// default 2→1 mapping silently keeps only the left channel.
///
/// The mastering-quality resampler is the slow part (~20 s per hour of audio
/// on one core), so long files are split into segments resampled in parallel.
/// Segment edges fall on exact output samples and each segment is fed an
/// extra second on both sides that is discarded, so seams carry no filter or
/// AAC priming artifacts.
enum AudioDecoder {
    static let sampleRate = 16_000.0
    private static let chunkFrames: AVAudioFrameCount = 65_536
    /// Files shorter than this per segment are resampled on one core.
    private static let minimumSegmentSeconds = 60.0
    private static let maximumSegments = 8

    struct Resampling: Sendable {
        var algorithm: String
        var quality: AVAudioQuality
    }

    private final class PullState: @unchecked Sendable {
        var finished = false
        var error: Error?
    }

    /// First error raised by any parallel segment.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        func set(_ error: Error) { lock.withLock { if stored == nil { stored = error } } }
        var error: Error? { lock.withLock { stored } }
    }

    static func decodeMono16k(_ url: URL, resampling: Resampling = .standard) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0, file.processingFormat.channelCount > 0 else {
            throw TranscriptionFailure("unsupported audio format")
        }
        let length = file.length
        let estimated = Int((Double(length) * sampleRate / rate).rounded(.up)) + 1024

        // Boundaries must map to whole output samples: multiples of
        // rate / gcd(rate, 16 kHz) input frames (3 at 48 kHz, 441 at 44.1 kHz).
        let segments = min(maximumSegments, ProcessInfo.processInfo.activeProcessorCount,
                           Int(Double(length) / rate / minimumSegmentSeconds))
        guard rate != sampleRate, rate == rate.rounded(), segments >= 2 else {
            return try [Float](unsafeUninitializedCapacity: estimated) { buffer, count in
                count = try decode(url, frames: 0..<length, pad: 0, into: buffer, resampling: resampling)
            }
        }
        let inputRate = Int64(rate)
        let step = inputRate / gcd(inputRate, Int64(sampleRate))
        let outputPerStep = step * Int64(sampleRate) / inputRate
        let pad = max(step, inputRate / step * step)
        let bounds = (0...segments).map { index -> Int64 in
            index == segments ? length : Int64(Double(length) * Double(index) / Double(segments)) / step * step
        }

        let errors = ErrorBox()
        // Each parallel segment writes only its own index here and its own
        // disjoint range of the output.
        nonisolated(unsafe) let produced = UnsafeMutableBufferPointer<Int>.allocate(capacity: segments)
        produced.initialize(repeating: 0)
        defer { produced.deallocate() }
        let samples = try [Float](unsafeUninitializedCapacity: estimated) { buffer, count in
            nonisolated(unsafe) let destination = buffer
            DispatchQueue.concurrentPerform(iterations: segments) { index in
                let frames = bounds[index]..<bounds[index + 1]
                let offset = Int(frames.lowerBound / step * outputPerStep)
                let isLast = index == segments - 1
                let capacity = isLast ? destination.count - offset
                    : Int((frames.upperBound - frames.lowerBound) / step * outputPerStep)
                guard capacity >= 0, offset + capacity <= destination.count else {
                    errors.set(TranscriptionFailure("audio segment out of range"))
                    return
                }
                let slice = UnsafeMutableBufferPointer(rebasing: destination[offset..<(offset + capacity)])
                do {
                    let written = try decode(url, frames: frames, pad: pad, into: slice,
                                             resampling: resampling, exact: !isLast)
                    produced[index] = written
                } catch {
                    errors.set(error)
                }
            }
            if let error = errors.error { throw error }
            let lastOffset = Int(bounds[segments - 1] / step * outputPerStep)
            count = lastOffset + produced[segments - 1]
        }
        return samples
    }

    /// Decode `frames` (plus up to `pad` frames of context on each side, whose
    /// output is dropped) into `destination`. Returns the samples written;
    /// `exact` requires filling `destination` completely.
    private static func decode(_ url: URL, frames: Range<Int64>, pad: Int64,
                               into destination: UnsafeMutableBufferPointer<Float>,
                               resampling: Resampling, exact: Bool = false) throws -> Int {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate,
                                       channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunkFrames),
              let mixed = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: chunkFrames) else {
            throw TranscriptionFailure("unsupported audio format")
        }
        let start = max(0, frames.lowerBound - pad)
        let end = min(file.length, frames.upperBound + pad)
        file.framePosition = start
        let ratio = sampleRate / source.sampleRate
        var skip = Int((Double(frames.lowerBound - start) * ratio).rounded())
        var written = 0

        func emit(_ pointer: UnsafePointer<Float>, _ count: Int) {
            var pointer = pointer
            var count = count
            if skip > 0 {
                let dropped = min(skip, count)
                skip -= dropped
                pointer += dropped
                count -= dropped
            }
            let kept = min(count, destination.count - written)
            guard kept > 0 else { return }
            (destination.baseAddress! + written).update(from: pointer, count: kept)
            written += kept
        }

        // Read one chunk and average its channels into `mixed`. False past `end`.
        func readChunk() throws -> Bool {
            let remaining = end - file.framePosition
            guard remaining > 0 else { return false }
            try file.read(into: input, frameCount: AVAudioFrameCount(min(Int64(chunkFrames), remaining)))
            guard input.frameLength > 0 else { return false }
            try downmix(input, into: mixed)
            return true
        }

        if source.sampleRate == sampleRate {
            while written < destination.count, try readChunk() {
                emit(mixed.floatChannelData![0], Int(mixed.frameLength))
            }
        } else {
            guard let resampler = AVAudioConverter(from: mono, to: target) else {
                throw TranscriptionFailure("unsupported audio format")
            }
            resampler.sampleRateConverterAlgorithm = resampling.algorithm
            resampler.sampleRateConverterQuality = resampling.quality.rawValue
            let capacity = AVAudioFrameCount((Double(chunkFrames) * ratio).rounded(.up)) + 1024
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                throw TranscriptionFailure("cannot allocate audio buffer")
            }
            let state = PullState()
            while written < destination.count {
                output.frameLength = 0
                var conversionError: NSError?
                let status = resampler.convert(to: output, error: &conversionError) { _, inputStatus in
                    if state.finished {
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    do {
                        guard try readChunk() else {
                            state.finished = true
                            inputStatus.pointee = .endOfStream
                            return nil
                        }
                    } catch {
                        state.error = error
                        state.finished = true
                        inputStatus.pointee = .endOfStream
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return mixed
                }
                if let error = state.error { throw error }
                if status == .error {
                    throw conversionError ?? TranscriptionFailure("audio conversion failed")
                }
                emit(output.floatChannelData![0], Int(output.frameLength))
                if status == .endOfStream { break }
            }
        }
        if exact, written != destination.count {
            throw TranscriptionFailure("audio segment decoded short")
        }
        return written
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        b == 0 ? a : gcd(b, a % b)
    }

    /// Average all channels of a float buffer into a mono buffer of the same rate.
    static func downmix(_ input: AVAudioPCMBuffer, into output: AVAudioPCMBuffer) throws {
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        guard frames <= Int(output.frameCapacity), let destination = output.floatChannelData?[0] else {
            throw TranscriptionFailure("cannot mix audio channels")
        }
        if let planar = input.floatChannelData, !input.format.isInterleaved {
            if channels == 1 {
                destination.update(from: planar[0], count: frames)
            } else {
                var scale = 1 / Float(channels)
                vDSP_vsmul(planar[0], 1, &scale, destination, 1, vDSP_Length(frames))
                for channel in 1..<channels {
                    vDSP_vsma(planar[channel], 1, &scale, destination, 1, destination, 1, vDSP_Length(frames))
                }
            }
        } else if let interleaved = input.floatChannelData?[0] {
            var scale = 1 / Float(channels)
            vDSP_vsmul(interleaved, channels, &scale, destination, 1, vDSP_Length(frames))
            for channel in 1..<max(channels, 1) {
                vDSP_vsma(interleaved + channel, channels, &scale, destination, 1, destination, 1,
                          vDSP_Length(frames))
            }
        } else {
            throw TranscriptionFailure("unsupported audio sample format")
        }
        output.frameLength = input.frameLength
    }
}

extension AudioDecoder.Resampling {
    /// The quality FluidAudio used: faster settings measurably change
    /// recognized words on real meetings, so keep recognition unchanged.
    static let standard = Self(algorithm: AVSampleRateConverterAlgorithm_Mastering, quality: .max)
}
