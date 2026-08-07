import AVFoundation
import Foundation

/// Records the default input device to a file via AVAudioEngine, encoding AAC
/// mono. Buffers stream straight to disk — nothing is held in memory, so
/// session length is unbounded.
///
/// With voice processing enabled, Apple's echo canceller subtracts
/// speaker playback from the mic so the system track doesn't bleed into the
/// mic track. VoiceProcessingIO is a duplex unit, not an input effect: it
/// needs a rendered output path and one explicit mono client format on both
/// sides, or it silently delivers zeroed buffers (rca-001). A first-second
/// liveness check catches routes where even the correct graph stays silent
/// and restarts capture raw.
final class MicRecorder: @unchecked Sendable {
    private static let recordingSampleRate = 48_000.0

    private final class ConversionState: @unchecked Sendable {
        var input: AVAudioPCMBuffer?
        var output: AVAudioPCMBuffer?
        var supplied = false
    }

    enum RecorderError: Error, CustomStringConvertible {
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported(AVAudioFormat)

        var description: String {
            switch self {
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported(let f): return "can't downmix mic format \(f)"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var url: URL?
    private(set) var isRecording = false
    /// Wall-clock time of the first captured buffer — the track's true start,
    /// used to offset-align the two tracks' transcript timestamps.
    private(set) var firstBufferAt: Date?

    // Liveness check state (voice-processing path only). Written from the tap
    // callback, read on main when deciding to fall back.
    private var livenessFrames = 0
    private var livenessPeak: Float = 0
    private var livenessSettled = false
    private var writeFailed = false

    /// Start capturing the mic, encoding AAC into `url` (use a .caf extension
    /// — CAF needs no finalization pass, so a crash loses nothing written).
    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        self.url = url
        try attach(voiceProcessing: Config.micVoiceProcessing())
        isRecording = true
    }

    /// Stop capturing and finalize the file. Idempotent.
    func stop() {
        guard isRecording else { return }
        isRecording = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
    }

    // MARK: -

    /// Build the engine graph, create the AAC file, and start capture. Called
    /// once at start, and a second time (voiceProcessing: false) if the
    /// liveness check trips.
    private func attach(voiceProcessing: Bool) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode

        var voice = voiceProcessing
        if voice {
            do {
                try input.setVoiceProcessingEnabled(true)
                // The live voice unit makes macOS treat the session like a
                // call and duck all other audio — meetings played through the
                // speakers would get quieter the moment recording starts.
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                FileHandle.standardError.write(Data(
                    "warning: mic voice processing unavailable (\(error)) — recording raw mic\n".utf8
                ))
                voice = false
            }
        }
        let inputFormat = input.outputFormat(forBus: 0)

        // VoiceProcessingIO needs the client format to use the engine's I/O
        // sample rate. Never accept the inherited multichannel route format
        // here: a 9-channel device yielded digital silence.
        guard let captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.recordingSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: recordingFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url!,
                settings: settings,
                commonFormat: recordingFormat.commonFormat,
                interleaved: recordingFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
        writeFailed = false

        if voice {
            // Complete the duplex graph: VoiceProcessingIO must render to an
            // output device or the input side never produces audio. The mixer
            // has no sources — nothing is monitored or played — its connection
            // exists solely to give the unit a formatted output path.
            engine.connect(engine.mainMixerNode, to: engine.outputNode, format: captureFormat)
            livenessFrames = 0
            livenessPeak = 0
            livenessSettled = false
            try installVoiceTap(
                on: input,
                captureFormat: captureFormat,
                recordingFormat: recordingFormat
            )
        } else {
            try installRawTap(
                on: input,
                inputFormat: inputFormat,
                recordingFormat: recordingFormat
            )
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }

        let report = "mic: voiceProcessing=\(input.isVoiceProcessingEnabled) "
            + "input=\(input.outputFormat(forBus: 0)) recording=\(recordingFormat)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }

    /// Voice-processing path: the unit converts to the mono client format
    /// itself, so tapped buffers write straight to the file. Tracks signal
    /// peak over the first second — an unsupported route (device pair, macOS
    /// AUVPAggregate defects) delivers callbacks full of digital zeros, and
    /// the only recovery is restarting raw.
    private func installVoiceTap(
        on input: AVAudioInputNode,
        captureFormat: AVAudioFormat,
        recordingFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: captureFormat, to: recordingFormat) else {
            throw RecorderError.formatUnsupported(captureFormat)
        }
        configure(converter)
        let conversionState = ConversionState()

        let checkFrames = Int(captureFormat.sampleRate)
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: captureFormat
        ) { [weak self] buffer, _ in
            guard let self, let file = self.file, !self.writeFailed else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }

            if !self.livenessSettled {
                let frames = Int(buffer.frameLength)
                if let data = buffer.floatChannelData?[0] {
                    for i in 0..<frames {
                        self.livenessPeak = max(self.livenessPeak, abs(data[i]))
                    }
                }
                self.livenessFrames += frames
                if self.livenessFrames >= checkFrames {
                    self.livenessSettled = true
                    if self.livenessPeak == 0 {
                        DispatchQueue.main.async { self.fallBackToRaw() }
                        return
                    }
                }
            }

            do {
                let converted = try self.convert(
                    buffer,
                    to: recordingFormat,
                    using: converter,
                    state: conversionState
                )
                if converted.frameLength > 0 {
                    try file.write(from: converted)
                }
            } catch {
                self.reportWriteFailure(error)
            }
        }
    }

    /// Raw path: tap at the device's native format, then downmix and resample
    /// to the fixed recording format. AVAudioEngine can expose the default
    /// output device's rate here, even when the physical mic uses another
    /// rate (for example, a 48 kHz mic with a 192 kHz output interface).
    private func installRawTap(
        on input: AVAudioInputNode,
        inputFormat: AVAudioFormat,
        recordingFormat: AVAudioFormat
    ) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw RecorderError.formatUnsupported(inputFormat)
        }
        configure(converter)
        let conversionState = ConversionState()

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file, !self.writeFailed else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            do {
                let converted = try self.convert(
                    buffer,
                    to: recordingFormat,
                    using: converter,
                    state: conversionState
                )
                if converted.frameLength > 0 {
                    try file.write(from: converted)
                }
            } catch {
                self.reportWriteFailure(error)
            }
        }
    }

    private func configure(_ converter: AVAudioConverter) {
        converter.primeMethod = .none
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        using converter: AVAudioConverter,
        state: ConversionState
    ) throws -> AVAudioPCMBuffer {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 1
        let output: AVAudioPCMBuffer
        if let existing = state.output, existing.frameCapacity >= capacity {
            existing.frameLength = 0
            output = existing
        } else {
            guard let allocated = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: capacity
            ) else {
                throw RecorderError.formatUnsupported(input.format)
            }
            state.output = allocated
            output = allocated
        }

        state.input = input
        state.supplied = false
        defer { state.input = nil }

        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if state.supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            state.supplied = true
            inputStatus.pointee = .haveData
            return state.input
        }

        if status == .error {
            throw conversionError ?? RecorderError.formatUnsupported(input.format)
        }
        return output
    }

    private func reportWriteFailure(_ error: Error) {
        guard !writeFailed else { return }
        writeFailed = true
        FileHandle.standardError.write(Data("mic track write failed: \(error)\n".utf8))
    }

    /// The voice-processing route delivered a full second of digital silence:
    /// tear the engine down and restart raw, discarding the silent prefix so
    /// the track's timestamps start at real audio.
    private func fallBackToRaw() {
        guard isRecording else { return }
        FileHandle.standardError.write(Data(
            "warning: voice processing delivered silence — restarting mic raw\n".utf8
        ))
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        firstBufferAt = nil
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
        do {
            try attach(voiceProcessing: false)
        } catch {
            FileHandle.standardError.write(Data(
                "mic raw fallback failed: \(error) — session continues without mic track\n".utf8
            ))
            file = nil
        }
    }
}
