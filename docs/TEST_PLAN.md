# Test plan

## Automated

1. **Unit tests** (`TyphonCore`, 22 tests): word diff, text scoping (paragraphs, sentences, UTF-16 offsets, emoji), smart edits (minimal word-aligned edit, rebasing after further typing, caret placement, full-stop rule) and the model manifest.
   `cd TyphonCore && xcodebuild test -scheme TyphonCore-Package -destination 'platform=macOS'`
2. **Model parity and speed** with `typhon-bench <model-dir> ref.json`. It compares Swift output with the reference `dspark_mlx.py` output, prints median and p90 latency, and checks that the newest request wins when several overlap.
3. **End-to-end self-test**: `open Typhon.app --args --selftest --apps textedit,notes,safari,chrome`. Results go to `~/Library/Application Support/Typhon/selftest.json`. It only ever types a fixed test sentence.

## Manual checklist (per app)

For each of TextEdit, Notes, Safari, Chrome, Messages, Slack, Discord and Terminal:

- [ ] A sloppy sentence shows a suggestion within about 300 ms of pausing.
- [ ] The bubble sits next to the caret and stays fully on screen near screen edges and on a second display.
- [ ] **Tab** replaces only the changed words; text typed afterwards is untouched; the caret stays where it was.
- [ ] **Esc** dismisses; the same text isn't suggested again.
- [ ] **Return** sends or adds a new line as usual (default setting).
- [ ] Password fields show nothing.
- [ ] The clipboard is the same after an accept that used paste.
- [ ] Turning the app off in the menu bar stops suggestions there.

## Performance

- [ ] Model time per fix is under 100 ms in Release (Turbo on); key-up to bubble is under 300 ms.
- [ ] Idle CPU is about 0% in Activity Monitor when not typing (no timers run while idle).
- [ ] Memory shown in Settings → Model is about 1 GB with Turbo.

## Onboarding

- [ ] Fresh install: welcome → live demo → Accessibility (the drag helper appears; the step continues by itself once access is granted) → download (progress; survives a quit and resumes) → done.

## Results so far

See [COMPATIBILITY.md](COMPATIBILITY.md). Verified: unit tests, model parity (10/10), speed, the download with resume after a relaunch, and TextEdit, Notes and Safari end to end. **Not yet verified:** Chrome (unreliable), Messages, Slack, Discord, Terminal, idle CPU, and the multi-display panel placement.
