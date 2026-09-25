# betterMeet

## Build, test, install

- `swift build`, `swift test`, `python3 -m unittest discover -s Scripts -p 'test_*.py'`
- The LaunchAgent runs `/usr/local/bin/betterMeet`, not `.build`. A change is only
  deployed once installed. Install through a fresh file, never in place: replacing the
  running binary makes macOS kill it (`OS_REASON_CODESIGNING`):

  ```sh
  swift build -c release
  tmp=$(sudo mktemp /usr/local/bin/betterMeet.XXXXXX) && sudo install -o root -g wheel -m 755 .build/release/betterMeet "$tmp" && sudo mv -f "$tmp" /usr/local/bin/betterMeet && launchctl kickstart -k "gui/$(id -u)/com.flup-repo.betterMeet"
  ```

- `sudo` needs the user's password: run the install in the user's terminal, never
  type credentials. Check first that no recording or `_inference-worker` is active.
- Verify with `launchctl print "gui/$(id -u)/com.flup-repo.betterMeet"` and
  `tail /tmp/betterMeet.err.log` (expect `recording controls ready`). Never start a
  second daemon next to the LaunchAgent.
- The binary is ad-hoc signed, so every install invalidates the Accessibility and
  Input Monitoring grants. The app prompts and retries; the user must grant again
  before Right ⌥ works (`right-option dictation shortcut ready` in the log).

## Gotchas

- Inference runs in a child process (`_inference-worker`) spawned from
  `Bundle.main.executableURL`. In tests that is the xctest runner, so integration
  tests must pass the built binary via `InferenceService(executable:)`.
- Keep the resampler at Mastering/max quality (`AudioDecoder.Resampling.standard`).
  Faster settings change 4–9% of recognized words on real meetings. ASR is
  deterministic, so compare transcripts before and after any audio pipeline change.
- Measure peak memory by polling `ps` over the CLI and its child worker;
  `/usr/bin/time -l` misses the worker.
- Recordings under `~/Recordings` hold private meeting audio. Report metrics only,
  never transcript text, and delete scratch transcripts afterwards.
- The shell aliases `ls` and `cp` (interactive). Use `command ls` / `command cp -f`.
