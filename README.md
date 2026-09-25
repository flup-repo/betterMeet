# betterMeet - Dictation and Live Meeting Transcription

A macOS menu-bar app that transcribes live meetings and offers live dictate functionality. 
For meetings, it records your microphone and system audio separately,
then transcribes them locally. 
Model weights download on first use.

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

1. Click the eye icon in the menu bar, then **Start recording**.
2. Grant microphone and system-audio permissions when prompted.
3. Click **Stop recording**. Transcription runs automatically.

**Control + Option + R** also toggles recording.

Recordings are saved under `~/Recordings/`. Each session contains:

- `mic.aac` and `system.aac`: microphone and all system playback.
- `transcript.md`: readable transcript, labeled `me` (mic) and `them` (system).
- `transcript.json`: structured transcript, settings, diagnostics, and original text.
- `meta.json` and `transcribe.log`: recording metadata and processing status.

The labels identify tracks, not individual people. Check JSON for track errors
if the transcript reports `partial` or `failed`. The system track is mixed to
mono by averaging both channels. The menu shows which track is being
transcribed and its progress. Dictation can run between the two tracks
instead of waiting for the whole transcript.

## Dictate into a text field

Put the cursor in the destination text field in any app. The text is automatically
inserted at the cursor position using live-preview.
If automatic insertion does not work, the recognized text is copied to the
clipboard so you can paste it manually.

Holding **Right ⌥** works as push-to-talk: dictation runs while the key is
held and stops when it is released. A short press keeps dictation running
until the next short press, as before. The key is fully dedicated to
dictation; the left Option key keeps its normal behavior.

Dictation always uses multilingual **Parakeet v3**, with automatic language
recognition across its 25 supported European languages.

### Measure dictation speed and accuracy

Use a real recording of up to 60 seconds and a manually checked reference:

```sh
/usr/local/bin/betterMeet dictation-benchmark /absolute/path/sample.wav \
  --reference /absolute/path/reference.txt --runs 3 \
  --output /absolute/path/new-result.json
```

This uses the same multilingual recognition path as the Right ⌥ dictation
without capturing the
microphone, inserting text, or running hooks. It reports model preparation time,
warm recognition times (including worker communication), and word error rate
with punctuation/case ignored. The optional output file must be new and includes
recognized text; stdout contains only metrics. These timings exclude microphone
startup, live preview already in flight, and insertion. The menu bar reports
the current state during interactive dictation.

## Settings

Configuration is optional. These are the defaults; merge changes into
`~/.config/betterMeet/config.json`:

```json
{
  "mic_voice_processing": false,
  "dictation_max_seconds": 600,
  "inactivity_timeout_seconds": 600,
  "max_duration_seconds": 14400,
  "inference_idle_seconds": 300,
  "transcription": {
    "model": "v3",
    "speech_detection": "annotate"
  }
}
```

- `v3` supports multilingual transcription; `v2` is English-only. Neither
  translates speech into English.
- `dictation_max_seconds` caps live dictation audio kept in memory. The default
  is 600 seconds (10 minutes).
- `inactivity_timeout_seconds` stops a recording after this many seconds with
  no audible sound on either track. A notification warns one minute ahead;
  making any sound cancels it. The default is 600 seconds (10 minutes).
- `max_duration_seconds` is a hard cap on recording length regardless of
  activity. The default is 14400 seconds (4 hours).
- `inference_idle_seconds` keeps the recognition models loaded this long
  after the last dictation, so the next one starts instantly. `0` unloads them
  right away to save memory, at the cost of a slower next dictation. After a
  meeting transcript is finished, the models are always unloaded unless a
  dictation or another meeting is waiting.
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

Expect `state = running` and `recording controls ready` in the log. The same
messages go to the unified log:

```sh
log stream --predicate 'subsystem == "com.flup-repo.betterMeet"'
```

At startup the daemon clears `/tmp/betterMeet.err.log` once it passes 5 MB. For permission
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
