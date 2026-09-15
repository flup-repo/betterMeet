import Foundation

/// Optional user config at ~/.config/betterMeet/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "inactivity_timeout_seconds": 600,
///       "max_duration_seconds": 14400,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/betterMeet/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Maximum dictation audio to keep in memory, in seconds. Defaults to 10
    /// minutes so long dictation is practical without unbounded memory.
    static func dictationMaximumSeconds() -> Int {
        guard let seconds = load()?["dictation_max_seconds"] as? Int, seconds > 0 else { return 600 }
        return seconds
    }

    /// Stop a recording automatically after this many seconds without any
    /// audible signal on either track (mic or system). Defaults to 10
    /// minutes; 0 disables.
    static func inactivityTimeoutSeconds() -> Int {
        guard let seconds = load()?["inactivity_timeout_seconds"] as? Int, seconds >= 0 else { return 600 }
        return seconds
    }

    /// Hard cap on recording length, in seconds — a backstop against a
    /// forgotten session even if silence never registers. Defaults to 4
    /// hours; 0 disables.
    static func maximumDurationSeconds() -> Int {
        guard let seconds = load()?["max_duration_seconds"] as? Int, seconds >= 0 else { return 14400 }
        return seconds
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    static func transcriptionSettings() throws -> TranscriptionSettings {
        guard FileManager.default.fileExists(atPath: path.path) else { return TranscriptionSettings() }
        let data = try Data(contentsOf: path)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionFailure("config must be a JSON object")
        }
        guard let value = root["transcription"] else { return TranscriptionSettings() }
        guard let object = value as? [String: Any] else {
            throw TranscriptionFailure("transcription must be a JSON object")
        }
        let settingsData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(TranscriptionSettings.self, from: settingsData)
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
