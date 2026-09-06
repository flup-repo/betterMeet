# betterMeet

A macOS menu-bar app that records your microphone and system audio separately,
then transcribes them locally. Model weights download on first use.

Requires macOS 15+ and Swift 6 to build. Apple Silicon is recommended.

## Build and install

Run from the repository root. Stop any recording and quit the app before updating.

```sh
swift build -c release
sudo mkdir -p /usr/local/bin
tmp=$(sudo mktemp /usr/local/bin/betterMeet.XXXXXX) &&
  sudo install -o root -g wheel -m 755 .build/release/betterMeet "$tmp" &&
  sudo mv -f "$tmp" /usr/local/bin/betterMeet &&
  /usr/local/bin/betterMeet install --launch-at-login
```

This installs and starts the LaunchAgent, including on future logins. The fresh
file avoids the code-signing cache issue seen with in-place updates. The agent
runs `/usr/local/bin/betterMeet`, not the build output.

## Record

1. Click the feather in the menu bar, then **Start recording**.
2. Grant microphone and system-audio permissions when prompted.
3. Click **Stop recording**. Transcription runs automatically.

**Control + Option + R** also toggles recording.

Recordings are saved under `~/Recordings/`. Each session contains:

- `mic.aac` and `system.aac`: microphone and all system playback.
- `transcript.md`: readable transcript, labeled `me` (mic) and `them` (system).
- `transcript.json`: structured transcript, settings, diagnostics, and original text.
- `meta.json` and `transcribe.log`: recording metadata and processing status.

The labels identify tracks, not individual people. Check JSON for track errors
if the transcript reports `partial` or `failed`.

## Settings

Configuration is optional. These are the defaults; merge changes into
`~/.config/betterMeet/config.json`:

```json
{
  "mic_voice_processing": false,
  "transcription": {
    "model": "v3",
    "speech_detection": "annotate"
  }
}
```

- `v3` supports multilingual transcription; `v2` is English-only. Neither
  translates speech into English.
- `annotate` flags suspicious audio without removing words. `off` disables speech
  detection; experimental `filter` excludes non-speech spans from the readable
  transcript while retaining them in JSON.
- With speaker playback, try `mic_voice_processing: true` for echo cancellation.
  Leave it off with headphones. It can affect playback volume and quiet speech.

For English-only vocabulary correction, set `vocabulary_file` to an absolute
JSON path and `vocabulary_language` to `"en"` inside `transcription`. The file
format is `{"terms":[{"text":"Kubernetes"}]}`. Leave this unset for multilingual
meetings; the auxiliary vocabulary model is English-only.

## Re-transcribe an existing recording

Replace `SESSION` with the recording folder:

```sh
/usr/local/bin/betterMeet transcribe "$HOME/Recordings/SESSION" \
  --output "$HOME/Recordings/SESSION-v3-test" \
  --model v3 --speech-detection annotate --no-vocabulary
```

The output directory must be new, outside the source folder, with an existing
parent. Original files remain untouched and hooks are not run. To retry failed
tracks, repeat the same command with `--retry`; successful checkpoints are reused.
Use `betterMeet transcribe --help` for other options.

## Troubleshooting

Restart after quitting, inspect the service, or read startup errors:

```sh
launchctl kickstart -k "gui/$(id -u)/com.flup-repo.betterMeet"
launchctl print "gui/$(id -u)/com.flup-repo.betterMeet"
tail -n 30 /tmp/betterMeet.err.log
```

Expect `state = running` and `recording controls ready` in the log. For permission
or folder checks, run `/usr/local/bin/betterMeet doctor`. Do not start a second
menu-bar instance alongside the LaunchAgent.

## Development

```sh
swift build
swift test
python3 -m unittest discover -s Scripts -p 'test_*.py'
```

Use `.build/debug/betterMeet transcribe` to test without replacing the installed
app. Optional Python tools in `Scripts/` provide local Ollama punctuation cleanup
(`clean_transcript.py`) and scoring against a manually verified reference
(`evaluate_transcript.py`); each has `--help`. Cleanup writes a separate file.
Custom `on_stop` hooks can execute external commands and are not sandboxed.
