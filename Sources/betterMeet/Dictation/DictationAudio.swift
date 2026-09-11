@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// Bounded PCM storage shared by the audio callback and recognition snapshots.
final class DictationAudio: Sendable {
    static let sampleRate = 16_000.0
    static let maximumSamples = 60 * 16_000
    private struct State {
        var samples: [Float] = []
        var converter: AVAudioConverter?
        var error: String?
    }
    private let state = Mutex(State())

    func configure(inputFormat: AVAudioFormat) throws {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw TranscriptionFailure("Unsupported microphone format.")
        }
        converter.primeMethod = .none
        state.withLock {
            $0 = State()
            $0.samples.reserveCapacity(Self.maximumSamples)
            $0.converter = converter
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        state.withLock { state in
            guard state.error == nil, state.samples.count < Self.maximumSamples,
                  let converter = state.converter else { return }
            let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength)
                * Self.sampleRate / buffer.format.sampleRate)) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
                state.error = "Cannot allocate microphone buffer."
                return
            }
            let supplied = Mutex(false)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                guard supplied.withLock({ value in
                    if value { return false }
                    value = true
                    return true
                }) else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, let channel = output.floatChannelData?[0] else {
                state.error = "Microphone conversion failed."
                return
            }
            let count = min(Int(output.frameLength), Self.maximumSamples - state.samples.count)
            state.samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        }
    }

    func snapshot() throws -> [Float] {
        try state.withLock {
            if let error = $0.error { throw TranscriptionFailure(error) }
            // Copy here, not on the next realtime append via Array's copy-on-write.
            return $0.samples.withUnsafeBufferPointer { Array($0) }
        }
    }

    var isFull: Bool { state.withLock { $0.samples.count >= Self.maximumSamples } }

    func clear() {
        state.withLock { $0 = State() }
    }
}

@MainActor
final class DictationCapture {
    let audio = DictationAudio()
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    var onFailure: (() -> Void)?

    func start() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        try audio.configure(inputFormat: format)
        input.installTap(onBus: 0, bufferSize: 1024, format: format,
                         block: Self.makeTapHandler(for: audio))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audio.clear()
            throw TranscriptionFailure("Cannot start the microphone.")
        }
        self.engine = engine
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onFailure?() }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
    }

    func discard() {
        stop()
        audio.clear()
    }

    /// Core Audio invokes taps off the main actor. Constructing the callback
    /// inside start() would inherit its isolation and trap on the first buffer.
    nonisolated static func makeTapHandler(
        for audio: DictationAudio
    ) -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, _ in audio.append(buffer) }
    }
}
