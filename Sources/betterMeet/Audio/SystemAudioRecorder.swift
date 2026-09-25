import AVFoundation
import CoreAudio
import Foundation
import os

/// Records all system audio output to a file via a Core Audio process tap
/// (macOS 14.2+). No virtual device, no kernel extension — the tap mixes every
/// process's output to stereo and hands us buffers through a private aggregate
/// device. First use triggers the one-time "System Audio Recording" TCC prompt
/// and lights the purple recording indicator while active.
/// Unchecked, like MicRecorder: each capture field is written from one queue
/// (IO or writer) and only read elsewhere for status and metadata.
final class SystemAudioRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case tapFormatUnreadable(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
        case fileCreationFailed(Error)
        case writeFailed(Error)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):
                return "process tap creation failed (OSStatus \(s)) — check System Settings → Privacy & Security → Screen & System Audio Recording"
            case .tapFormatUnreadable(let s): return "couldn't read tap stream format (OSStatus \(s))"
            case .aggregateCreationFailed(let s): return "aggregate device creation failed (OSStatus \(s))"
            case .ioProcCreationFailed(let s): return "IO proc creation failed (OSStatus \(s))"
            case .deviceStartFailed(let s): return "device start failed (OSStatus \(s))"
            case .fileCreationFailed(let e): return "output file creation failed: \(e)"
            case .writeFailed(let e): return "system track write failed: \(e)"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "com.flup-repo.betterMeet.system-tap")
    /// AAC encoding and file I/O run here, not in the Core Audio IO cycle:
    /// the IO proc only copies PCM into a preallocated buffer.
    private let writerQueue = DispatchQueue(label: "com.flup-repo.betterMeet.system-writer", qos: .userInitiated)
    private var pool: PCMBufferPool?
    private(set) var isRecording = false
    private var failed = false
    var onFailure: (@Sendable (String) -> Void)?
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?
    /// Host time for the first frame, shared with AVAudioEngine's clock.
    private(set) var firstBufferHostTime: UInt64?
    /// Wall-clock time of the most recent buffer with audible signal. Written
    /// from the IO proc, read from main by the auto-stop logic.
    private(set) var lastActivityAt: Date?

    /// Start capturing system audio as an ADTS AAC stream. Each packet is
    /// independently framed, so audio remains readable after an unclean exit.
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        failed = false

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "betterMeet system tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr else { throw RecorderError.tapCreationFailed(status) }
        tapID = newTapID

        do {
            let format = try tapStreamFormat()
            try createAggregateDevice(tapUUID: description.uuid)
            file = try makeFile(url: url, format: format)
            try installIOProc(format: format)
        } catch {
            cleanup()
            throw error
        }

        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
        }
        // Let queued buffers reach the file before it is closed.
        writerQueue.sync {}
        cleanup()
    }

    // MARK: -

    private func tapStreamFormat() throws -> AVAudioFormat {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            throw RecorderError.tapFormatUnreadable(status)
        }
        return format
    }

    private func createAggregateDevice(tapUUID: UUID) throws {
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "betterMeet-tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &newAggregateID)
        guard status == noErr else { throw RecorderError.aggregateCreationFailed(status) }
        aggregateID = newAggregateID
    }

    private func makeFile(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 96_000 * Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
    }

    private func installIOProc(format: AVAudioFormat) throws {
        // ~5 s of backlog at typical 512-frame IO cycles, ~4 MB for stereo.
        let pool = PCMBufferPool(format: format, frameCapacity: 4096, count: 128)
        self.pool = pool
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self, self.file != nil, !self.failed else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            if self.firstBufferHostTime == nil,
               inInputTime.pointee.mFlags.contains(.hostTimeValid) {
                self.firstBufferHostTime = inInputTime.pointee.mHostTime
            }
            guard let copied = pool.copy(inInputData) else {
                self.reportDrop()
                return
            }
            // Owned by the writer until recycled; the IO proc never touches it again.
            nonisolated(unsafe) let buffer = copied
            self.writerQueue.async { [weak self] in
                defer { pool.recycle(buffer) }
                guard let self, let file = self.file, !self.failed else { return }
                do {
                    try file.write(from: buffer)
                    if MicRecorder.peak(of: buffer) > MicRecorder.activityThreshold {
                        self.lastActivityAt = Date()
                    }
                } catch {
                    self.reportFailure(RecorderError.writeFailed(error))
                }
            }
        }
        guard status == noErr, let procID else { throw RecorderError.ioProcCreationFailed(status) }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw RecorderError.deviceStartFailed(status) }
    }

    private var droppedBuffers = 0

    /// The writer fell more than the pool behind. Losing a slice beats
    /// blocking the IO cycle; log the first drop and every 100th after.
    private func reportDrop() {
        droppedBuffers += 1
        if droppedBuffers == 1 || droppedBuffers % 100 == 0 {
            let count = droppedBuffers
            Log.write("warning: system audio writer behind; dropped \(count) buffer(s)")
        }
    }

    private func reportFailure(_ error: Error) {
        guard !failed else { return }
        failed = true
        let message = String(describing: error)
        Log.write("\(message)\n")
        let handler = onFailure
        DispatchQueue.main.async {
            handler?(message)
        }
    }

    private func cleanup() {
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        file = nil
        pool = nil
    }
}

/// Fixed set of PCM buffers handed from the IO proc to the writer queue, so
/// the IO cycle never allocates. Oversized cycles get a one-off buffer.
private final class PCMBufferPool: @unchecked Sendable {
    private let format: AVAudioFormat
    private let frameCapacity: AVAudioFrameCount
    // A plain unfair lock around the free list: AVAudioPCMBuffer isn't
    // Sendable, so Mutex's region checks reject it. Held only for push/pop.
    private let lock = OSAllocatedUnfairLock()
    private var free: [AVAudioPCMBuffer]

    init(format: AVAudioFormat, frameCapacity: AVAudioFrameCount, count: Int) {
        self.format = format
        self.frameCapacity = frameCapacity
        let buffers = (0..<count).compactMap { _ in
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
        }
        free = buffers
    }

    /// Copy one IO cycle's buffer list, or nil when every buffer is in use.
    func copy(_ source: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, let first = input.first else { return nil }
        let frames = AVAudioFrameCount(Int(first.mDataByteSize) / bytesPerFrame)
        guard frames > 0 else { return nil }
        let target: AVAudioPCMBuffer?
        if frames <= frameCapacity {
            lock.lock()
            target = free.popLast()
            lock.unlock()
        } else {
            target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        }
        guard let target else { return nil }
        let output = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        for index in 0..<min(input.count, output.count) {
            // Non-interleaved formats carry one channel per buffer; bytesPerFrame
            // is per buffer either way.
            let bytes = min(input[index].mDataByteSize, UInt32(Int(target.frameCapacity) * bytesPerFrame))
            if let destination = output[index].mData, let origin = input[index].mData {
                memcpy(destination, origin, Int(bytes))
            }
            output[index].mDataByteSize = bytes
        }
        target.frameLength = frames
        return target
    }

    func recycle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameCapacity == frameCapacity else { return }
        lock.lock()
        free.append(buffer)
        lock.unlock()
    }
}
