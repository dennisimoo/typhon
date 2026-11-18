# App compatibility

Typhon reads and edits text through the macOS Accessibility (AX) API. Apps expose very different amounts of it, so this page records what was **actually verified** and what wasn't.

The self-test (`--selftest`) opens each app, clears an empty text field, types `cna u pikc up some milk on teh way hoem`, waits for the suggestion bubble, presses Tab, and reads the field back. It expects `Can you pick up some milk on the way home?`.

Last run: macOS 27.2 (Typhon targets macOS 26 or later), Apple M5, Debug build.

| App | Field role | Suggestion | Key-up → bubble | Caret | Apply method | Result |
|---|---|---|---|---|---|---|
| TextEdit | AXTextArea | ✅ | 242 ms | exact | Accessibility | ✅ exact |
| Notes | AXTextArea | ✅ | 232 ms | exact | Accessibility | ✅ exact |
| Safari (textarea) | AXTextArea | ✅ | 231 ms | exact | keyboard selection + paste | ✅ exact |
| Chrome (textarea) | AXTextArea | ✅ in the first run | 232 ms | derived | keyboard selection + paste | ⚠️ not yet reliable (see below) |
| Messages | — | not yet tested | | | | |
| Slack (Electron) | — | not yet tested | | | | |
| Discord (Electron) | — | not yet tested | | | | |
| Terminal | — | off by default | | | | |

"Key-up → bubble" is measured from the last synthetic key press to the panel appearing. It includes the 110 ms pause Typhon waits for in live mode. The Debug build's model time was about 105 ms; Release builds run about 60–80 ms.

## Per-app notes

**Native AppKit text views (TextEdit, Notes, Mail, Pages…)**
Everything works through AX: value, selection, `kAXBoundsForRangeParameterizedAttribute` for the caret, and a settable `kAXSelectedText`. Typhon selects just the changed words, sets the selected text, reads the value back to verify, then restores the caret.

**Safari and other WebKit views**
`kAXSelectedText` can report success without editing anything, and the AX selection can report a range it never selected. Doing that edit through AX turned a replace into an insert, which duplicated text in early builds. Typhon now selects the words with real Shift+Arrow keystrokes, confirms the selected text matches exactly (polling briefly, because WebKit updates its tree a beat late), then pastes and restores your clipboard.

**Chrome and Chromium browsers (Edge, Brave, Arc, Vivaldi…)**
Chrome keeps its accessibility tree dormant. Typhon sets `AXEnhancedUserInterface` on the app when it becomes active. Text-marker bounds are used when range bounds fail. Editing uses the same keyboard path as Safari. In two later self-test runs, the textarea's AX value read as empty right after typing, so no suggestion appeared. This is still being investigated, and Chrome is marked ⚠️ until it passes reliably.

> Side effect worth knowing: `AXEnhancedUserInterface` can make some window managers animate less smoothly in Chrome. Typhon only sets it on Chromium browsers.

**Electron (Slack, Discord, VS Code, Notion…)**
Typhon sets `AXManualAccessibility` on the app each time it becomes active, because VS Code-style apps can fall asleep again. Editing uses the keyboard path. Not yet verified with the self-test.

**Messages**
Return sends a message. Typhon never captures Return unless you change **Return key** in Settings. Not yet verified with the self-test.

**Terminals (Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm)**
Off by default: they don't expose an editable text field the way text views do, and Tab is shell completion. You can turn them on per app.

**Password managers and password fields**
Always skipped: `AXSecureTextField`, `AXProtectedContent`, fields whose label or placeholder mentions a password or one-time code, secure keyboard input (`IsSecureEventInputEnabled`), and a list of password-manager apps.
