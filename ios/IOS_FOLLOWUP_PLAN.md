# Zellij Agent iOS Follow-up Plan

## Current Baseline

The app can connect to Zellij Web, list / attach / create sessions, render through SwiftTerm, reconnect after lifecycle changes, resize around the iOS keyboard, and use SwiftTerm's built-in `TerminalAccessory` row when the keyboard is visible. Custom multi-finger gestures cover keyboard toggle, agent interrupt, shell history, and Ctrl-D without needing the on-screen keyboard. This is enough for self-testing with Claude Code and Codex CLI.

## SwiftTerm Capability Inventory

Read of `migueldeicaza/SwiftTerm` (`iOS/iOSTerminalView.swift`, `iOS/iOSAccessoryView.swift`, `Apple/AppleTerminalView.swift`). Public API the app can lean on:

### Input
- `view.send(data: ArraySlice<UInt8>)` — send raw bytes as if the user typed them. Bypasses re-implementing key encoding for Esc, Ctrl-C, arrows, etc.
- `view.send(_ bytes: [UInt8])`, `view.send(txt: String)` — convenience overloads.
- `controlModifier: Bool` — when true, the next character typed is sent with Ctrl. Posts `terminalViewControlModifierReset` after consumption. Lets a "sticky Ctrl" UI toggle work without app-side bookkeeping.
- `metaModifier: Bool` — same idea for Meta/Alt.
- `optionAsMetaKey: Bool` — Mac-style Option = Meta. Wired from server `SetConfig.mac_option_is_meta`.
- `backspaceSendsControlH: Bool` — configurable backspace behavior.

### Selection / clipboard
- Long-press → context menu (Copy / Paste / Select All) via UIKit menu actions.
- Double-tap = word select. Triple-tap = line select.
- `selectionActive`, `getSelection() -> String?`, `selectAll()`, `selectNone()`.
- `paste(_:)` honors bracketed paste when the remote terminal advertises it.

### Scroll
- `pageUp()`, `pageDown()`, `scrollUp(lines: Int)`, `scrollDown(lines: Int)`.
- `scrollPosition: Double`, `scrollThumbsize: CGFloat`, `canScroll: Bool`, `scrollTo(row:notifyAccessibility:)`.
- `changeScrollback(_ newScrollback: Int?)` — adjust local scrollback line count.

### Mouse reporting
- `allowMouseReporting: Bool` — when true, taps and pans become mouse events forwarded to the remote (lets vim / htop see clicks). When false, SwiftTerm's local selection/copy path is available; our app should decide whether normal one-finger pan means scrollback or selection.
- `panMouseGesture` (mouse-mode pan) and `panSelectionGesture` (select-mode pan) are SwiftTerm-internal. Our custom one-finger pan coexists via `shouldRecognizeSimultaneouslyWith == true` but should be reviewed in mouse mode (see Priority 1 below).

### Rendering
- `setUseMetal(_ enabled: Bool) throws` — flip to GPU-backed renderer. `isUsingMetalRenderer` to query.
- `metalBufferingMode = .perRowPersistent` — buffering strategy.
- `customBlockGlyphs: Bool` (default true) — render box-drawing chars natively.
- `antiAliasCustomBlockGlyphs: Bool`.
- `useBrightColors: Bool`.
- `setFonts(normal:bold:italic:boldItalic:)` — distinct fonts per style.
- `installColors([Color])`, `nativeForegroundColor`, `nativeBackgroundColor`, `caretColor`, `caretTextColor`, `selectedTextBackgroundColor`, `selectionHandleColor`.

### Accessory bar (`TerminalAccessory`)
- Already on by default (the `inputAccessoryView` of `TerminalView`). Visible above the iOS keyboard when first responder.
- Buttons: Esc, Tab, Ctrl, sticky modifier indicators, ↑ ↓ ← →, F1–F10, slash, pipe, tilde, dash.
- Toggle to alternate "terminal keyboard" view (`iOSKeyboardView`).
- Toggle for mouse reporting.
- Reachable as `view.inputAccessoryView as? TerminalAccessory` for customization. SwiftTerm's `terminalAccessory` helper is internal and not visible to this app module.

### Linking
- `linkReporting: LinkReporting` (`.implicit` default, `.explicit`, `.disabled`).
- `linkHighlightMode: LinkHighlightMode` (`.hover`, `.always`, `.never`).
- `requestOpenLink(source:link:params:)` delegate callback.

### Misc
- `caretViewTracksFocus: Bool`, `caretFrame: CGRect`.
- `hostCurrentDirectoryUpdate(source:directory:)` — picks up OSC 7 cwd from the shell.
- `setTerminalTitle(source:title:)` — shell-set title.
- `pointerInteraction(...)` — trackpad / mouse pointer support.
- `notifyUpdateChanges`.
- `SwiftUITerminalView` — SwiftTerm's own SwiftUI wrapper. We chose our own because we wanted gesture / sizing control; revisit if our wrapper grows too thick.

## Final Gesture Map

| Gesture | Action | Source |
| --- | --- | --- |
| 1-finger tap | Cursor / focus | SwiftTerm default |
| 1-finger long-press | Context menu (Copy / Paste / Select All) | SwiftTerm default |
| 1-finger double-tap | Word select | SwiftTerm default |
| 1-finger triple-tap | Line select | SwiftTerm default |
| 1-finger pan | Local scrollback, line-by-line | App custom (uses `scrollUp/scrollDown(lines:)`) |
| 2-finger tap | Esc | App custom (calls `view.send([0x1B])`) |
| 3-finger tap | Ctrl-C | App custom (calls `view.send([0x03])`) |
| 4-finger tap | Ctrl-D | App custom (calls `view.send([0x04])`) |
| 2-finger swipe up | Show iOS keyboard | App custom |
| 2-finger swipe down | Hide iOS keyboard | App custom |
| 2-finger swipe left | Up arrow (history previous) | App custom (CSI A) |
| 2-finger swipe right | Down arrow (history next) | App custom (CSI B) |

When the iOS keyboard is visible, `TerminalAccessory` provides the full key set above the keyboard (Esc / Ctrl / Tab / arrows / F-keys / symbols / alt-keyboard / mouse-mode toggle). Custom gestures cover keyboard-hidden use, where the agent is being driven entirely by gesture.

## Done — SwiftTerm-native send path

Gesture handlers now call `TerminalView.send(_:)` directly. SwiftTerm forwards those bytes through its delegate (`Coordinator.send(source:data:)`) to `AppModel.sendData`, so Esc, Ctrl-C, Ctrl-D, and history arrows use the same path as real terminal input.

## Done — keep these stable

- Connect / list / attach / create sessions, with explicit `?create=true` for fresh names.
- Server `/sessions` returns `{ name, status }` with `live` or `resurrectable`.
- Server close `4404` is mapped in `AppModel.onClose` to the session picker without recreating a missing session.
- SwiftTerm rendering with raw byte feeding, no string round-trip on terminal frames.
- Auto-resize around iOS keyboard (no `.ignoresSafeArea(.keyboard, …)`).
- Multi-finger gestures listed above, including 4-finger Ctrl-D.
- Reconnect on `scenePhase == .active` and on `NWPathMonitor` interface change, with picker reopen guarded so a path flap during the picker does not loop.
- `connectWithRetry` 2-attempt loop with 2-second backoff before falling back to the session picker.
- `TerminalBuffer` capped at 120,000 characters.
- Wire protocol code isolated in `ZellijWebTransport`; unknown control variants tolerated; extra JSON fields ignored.
- TLS pinning with TOFU prompt, mismatch path, persisted SPKI hash.
- `optionAsMetaKey` from `SetConfig` applied.

## Level-Up Tiers (next-version targets)

The Priority 1–5 list below is maintenance / polish for the v1 shape. The Tiers below define what moves the app from "viewer of Mac" to "agent driver you carry". Implement in tier order.

### Tier A: Phone-as-driver

These three are all *remote-write* primitives. Every one of them needs the Security section enforced before merging.

**A1. Agent prompt detection + tap-to-respond**
- Lightweight regex over the SwiftTerm-fed byte stream after ANSI strip. Triggers on the trailing line only, when the cursor has been idle for ≥500 ms (no further bytes), to avoid mid-stream false matches.
- Match set is config-driven (loaded at runtime, user-editable in Settings) because Claude Code and Codex prompt wording drifts across versions. Initial pattern list lives in app config as JSON, not hard-coded.
- Surface a floating button row (Y / N / Esc) above the keyboard or near the cursor when matched.
- Each press calls `view.send(...)` with the appropriate byte.
- **Required guard**: never auto-fire. User must tap. The detection only surfaces the buttons; bytes are never sent without explicit user interaction.
- **False-positive budget**: track in diagnostics. If trigger fires more than 3× per minute the heuristic is broken and gets disabled until next launch.

**A2. Push notifications when agent stalls or finishes**

Pick path before coding. Recommended path:

- **Mac helper daemon** (~150 LOC, separate signed binary distributed alongside the iOS app). Attaches to a single named session as a **read-only zellij client** (read-only token). Watches output. Heuristic: streaming → idle for >30 s while a known prompt pattern is on the trailing line ⇒ "needs attention" event.
- Helper hits APNs with a token bound to one device. App receives, deep-links to that session.
- Apple Developer account required ($99/yr) for APNs.
- **Threat model** (must enforce before shipping):
  - Helper has read-only access to one named session per instance, not all sessions.
  - Helper cannot write to any pty.
  - Helper logs only to its own file under `~/Library/Logs/zellij-agent/`; never logs terminal bytes verbatim, only counts and timestamps.
  - Helper binary is signed and notarized. iOS app verifies a known signature on first install.
  - APNs key rotation procedure documented.

Alternative (lower scope, lower value):
- OSC-based notification: zellij plugin emits a custom OSC sequence on prompt detection; iOS app intercepts and shows a local notification. Only works while app is foregrounded — defeats the purpose. Document but do not ship as A2.

**A3. App Intents + Shortcuts + Siri**
- `SendPromptIntent(profile:String, prompt:String)` runs the HTTP/WS exchange in the background (no UI), sends bracketed paste, waits for response window or returns immediately.
- `AttachSessionIntent(profile:String, session:String)` deep-links the foreground app.
- Live Activity (Dynamic Island) while a sent prompt is awaiting response: lock-screen shows "Claude responding…".
- **Required guard**: send-mutating intents (`SendPromptIntent`) require per-profile allowlist confirmation on first use; persisted in Settings. No silent send to any profile that hasn't been explicitly enabled for Siri/Shortcuts.

**A4. URL scheme `zellij-agent://`**
- `zellij-agent://attach?profile=Mac&session=alpha` — read-only deep link. Foregrounds the app, switches to the session.
- `zellij-agent://send?profile=Mac&session=alpha&text=…` — write deep link. **Must** require a foreground confirmation sheet on first use per profile (same allowlist as A3). After confirmation, optionally allow silent re-use, but log every send to the diagnostics pane.
- Universal links from email / iMessage that land on a `zellij-agent://send` are otherwise a phishing primitive.

### Tier A Security Requirements

These apply to A1, A3, A4 collectively (and to any future "send to terminal" entry point):

1. **No silent remote write.** First use per profile per channel (gesture / Siri / URL) requires a foreground confirmation sheet that names the destination session.
2. **Per-channel allowlist** stored in Settings. User can revoke at any time.
3. **Rate limit**: at most N sends per minute per channel; hard-limit guards a stuck Shortcut from flooding.
4. **Diagnostics audit log**: every remote-write event (source channel, destination profile + session, byte count) recorded in the diagnostics ring. Never log the bytes themselves.
5. **A1 trailing-line + idle gate** (described above) is the equivalent confirmation primitive for the gesture path; tap is required, no auto-fire.

### Tier B: Mobile-native UX

**B1. Tab / pane switcher sheet** — pull-down sheet listing tabs from `setTerminalTitle` callbacks. Tap to switch via a zellij `GoToTab` action (sent as `Ctrl+T <n>` byte sequence today; switch to a structured action endpoint when zellij grows one).

**B2. First-run gesture cheat sheet** — modal on first launch + persistent `?` button in TopBar surfacing the same. Without this, gestures are undiscoverable.

**B3. Hardware keyboard shortcuts** — wire `keyCommands` on the responder chain: `⌘K` clear, `⌘T` new tab, `⌘W` close pane, `⌘1..9` jump tab, `⌘,` settings, `⌘?` cheat sheet, `⌘/` slash palette. Big iPad win, modest iPhone win.

**B4. iPad multi-window via `SceneDelegate`** — non-trivial state-management refactor. Default `UIScene` shape gives each window its own `URLSessionConfiguration` cookie store and Keychain access patterns; `AppModel` instances diverge across scenes, leading to confusing "logged in here, not there" states. Required design before implementing:

- `URLSessionConfiguration.httpCookieStorage`, `KeychainStore`, profile catalog, and certificate-pin store live in a singleton bound to the app process, not per-scene.
- Per-scene `AppModel` is fine; transports built by it must consult the singleton.
- One shared cert-trust prompt at most across scenes.

### Tier C: Cross-device + persistence

**C1. iCloud profile + snippet sync** — `NSUbiquitousKeyValueStore`. Profiles, snippets, prompt history all under the 1 MB cap. **Auth tokens stay device-local in Keychain (do not sync).** Document the boundary in code comments and in `ios/README.md`.

**C2. Tailscale auto-detect** — probe `100.64.0.0/10` interfaces via `NWPathMonitor`; suggest Tailnet IP when the user's Mac is on Tailnet. Reduces first-run friction.

**C3. Offline transcript review** — cache last ~1 MB of ANSI-stripped output per session. "Review" tab in Settings shows the recent agent transcript even when offline. Useful for re-reading a long agent reply on a flaky connection. Ties to the `TerminalBuffer` cap bump in Priority 4.3.

---

## Priority 1: Touch-mode finalization

Goal: stop fighting SwiftTerm's gestures; offer the user an explicit mode.

1. `TouchMode` is persisted per profile:
   - **Scroll** (default): `allowMouseReporting = false`. SwiftTerm's long-press / double-tap / triple-tap selection remains available. Our 1-finger pan owns scrollback. SwiftTerm's tap owns focus / cursor behavior. Multi-finger gestures = shortcuts.
   - **Select**: `allowMouseReporting = false`, but suppress our 1-finger pan so SwiftTerm's selection gestures are not competing with app scrollback. Use case: long-press or double-tap, then adjust text selection.
   - **Mouse**: `allowMouseReporting = true`. Pans / taps go to remote. Useful for vim / htop. Multi-finger gestures still resolve locally (mouse reporting is single-touch).
2. Done: expose the mode as a Settings row.
3. Done: `installFingerScroll` disables the custom pan recognizer when mode is Select or Mouse.
4. Remaining: decide whether to customize SwiftTerm's `TerminalAccessory` mouse button or keep Settings as the source of truth. Avoid letting accessory state and profile state fight each other.

## Priority 2: Agent UX

1. **Slash-command palette** in the top bar, separate from the profile menu:
   - `/resume`, `/fork`, `/memory`, `/compact`, `/clear`, `/help`, `/cost`, `/model` (Claude Code).
   - `/c`, `/q`, etc. for Codex (placeholder; finalize from Codex docs).
   - Tap inserts via bracketed paste so multi-line snippets land cleanly.
2. Done: **Compose Prompt shortcut** lives in the profile menu. Keep it there unless top-bar space is revisited; the user preferred fewer top-right icons.
3. **PromptComposerView**:
   - Done: command and history sections with one-tap insert or send.
   - Done: missing built-in slash snippets are merged into existing settings files.
   - Remaining: user snippet management (add / edit / delete from Settings).
   - Bracketed paste already on; verify multi-line preservation against Claude Code and Codex.
4. Done: **4-finger tap = Ctrl-D**. Lets the user `exit` a shell or signal EOF without summoning the keyboard.

## Priority 3: Reliability

1. Done: **Structured connection logs** in `AppModel`:
   - login, version probe, session list, session create, control WS open, terminal WS open, every close code with reason.
   - Diagnostics pane in Settings shows recent events and supports tap-to-copy for the last 50 events.
2. **Add test coverage for server close `4404`**. Runtime behavior already maps `4404` in `AppModel.onClose`; add a fixture/unit test so future refactors do not reintroduce the reconnect detour.
3. **Captured fixture tests** for the connection state machine:
   - missing session (server `4404` close frame),
   - HTTP 401 (token revoked),
   - cert trust required,
   - cert mismatch,
   - reconnect after foreground / network change.

## Priority 4: Performance

1. **Metal renderer (opt-in only)**: add a Settings toggle bound to `try view.setUseMetal(...)`. Default OFF. Surface `isUsingMetalRenderer` in the diagnostics pane. `setUseMetal` throws — wrap in try/catch and surface failure as a non-blocking diagnostics entry; do not silently leave the view in a half-state. Do not ship as default until verified glitch-free against a fixture set covering CC/Codex output, sixel images, and a CJK-heavy transcript.
2. **Coalesce `TerminalResize` sends** during keyboard show/hide and rotation. Today every `sizeChanged` callback hits the server; debounce ~150 ms with last-write-wins.
3. **Confirm `TerminalBuffer` cap** (120k characters) holds for multi-hour sessions. Bump to ~1 MB once review mode (Tier C, C3) lands so the offline buffer can hold a real agent reply.
4. **Connection-diagnostics ring (50 events)**: rate-limit or coalesce identical events to survive a reconnect storm without filling the buffer with duplicates.

## Priority 5: Upgrade Compatibility

1. **Fixture suite** (one file, multiple expectations):
   - login request shape.
   - `/sessions` with both legacy `[String]` and current `[{name,status}]`.
   - `SetConfig`.
   - `QueryTerminalSize`.
   - server close `4404` (session not found).
   - Terminal text frame replay through codec + SwiftTerm.
2. **Fixture regeneration script** at `ios/tools/regen-fixtures.sh`. Runs against a live `zellij web` and saves frames to a versioned folder (`fixtures/zellij-0.45/`, `fixtures/zellij-0.46/`, …). Tests reference latest folder; bumping zellij = regen + diff. Without this script, fixtures silently rot when the server changes wire shape and tests stop being meaningful.
3. **Document tested Zellij server versions** in `ios/README.md` and update on every Zellij bump.
4. **Capability detection** for future server-only endpoints (per-tab metadata, mobile actions). `/sessions` already gracefully degrades.
5. **Single-source-of-truth protocol layer** in `ZellijWebTransport` — never embed protocol assumptions in views.

## SwiftTerm Features Worth Adding Later

These are off the critical path but worth knowing exist:

- `setFonts(normal:bold:italic:boldItalic:)` — let users pick a separate italic font.
- `installColors([Color])` — bring full Zellij theme to SwiftTerm instead of just background / foreground from `SetConfig`.
- `linkReporting` / `linkHighlightMode` — match Zellij's hyperlink behavior; right now we open every URL via `UIApplication.open`.
- `hostCurrentDirectoryUpdate` — display the current working directory in the top bar (OSC 7 from the shell).
- `setTerminalTitle` — display tab/pane titles in the top bar.
- `changeScrollback(_:)` — make the local scrollback size a user setting.
- `customBlockGlyphs` / `antiAliasCustomBlockGlyphs` — already on by default; expose only if a glyph artifact appears.

## Test Before Next TestFlight

- iPhone portrait and landscape on a real device.
- Two-finger swipe up/down toggles keyboard. Single tap focuses without toggling. Long-press surfaces context menu.
- Two-finger tap interrupts a streaming agent reply.
- Three-finger tap kills `cat /dev/zero` style runaway commands.
- Two-finger swipe left/right walks shell history.
- One-finger drag scrolls scrollback through a long Claude / Codex response.
- iOS keyboard accessory bar shows Esc / Ctrl / Tab / arrows / F-keys; sticky Ctrl works.
- Long-press Copy / Paste, double-tap word select, triple-tap line select.
- iOS dictation; hardware keyboard if available.
- Kill Wi-Fi or switch to cellular mid-run; verify reconnect with no manual intervention.
- Delete the selected Zellij session on the Mac; reopen the app; verify the session picker appears with the missing-session message and does not silently recreate it.
- Switch `TouchMode` between Scroll / Select / Mouse and verify gesture behavior matches the table.
- Confirm the multi-client size negotiation behavior is understood: when a Mac terminal is also attached to the same tab, the pane is sized to the smaller of the two clients. Use independent sessions or independent tabs when phone-only viewing is desired.
- Cert rotation: replace the Mac's `cert.pem` while the app is connected; reconnect; verify the mismatch path surfaces both observed and expected SPKI hashes and the user can re-pin without resetting the profile.
- (Once Tier A ships) verify A1 detection only triggers on trailing-line idle ≥500 ms; tapping Y/N sends one byte and never repeats; rate-limit caps trigger when forced.
- (Once Tier A ships) verify A3 / A4 first-use confirmation per profile, allowlist persistence, audit log entries.
- (Once Tier B4 ships) open two iPad windows on the same profile; confirm a single cert-trust prompt across scenes, shared cookie state, no duplicate auth dialogs.
- (Once Tier C1 ships) wipe app on one device; re-install; profiles + snippets restore from iCloud; auth tokens are NOT present (must re-enter), confirming the security boundary holds.
