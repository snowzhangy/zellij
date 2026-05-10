# Zellij Agent iOS Follow-up Plan

## Current Baseline

The app can connect to Zellij Web, list/attach/create sessions, render through SwiftTerm, reconnect after lifecycle changes, resize around the iOS keyboard, toggle keyboard focus by tapping the terminal, and use SwiftTerm's built-in accessory row. This is enough for self-testing with Claude Code and Codex CLI.

## SwiftTerm Findings

SwiftTerm's iOS implementation already solves several terminal-specific mobile problems:

- `TerminalAccessory` provides Esc, Ctrl, Tab, arrows, symbols, a mouse/touch toggle, and an alternate terminal keyboard.
- `TerminalView` owns long-press, double-tap, triple-tap, selection, Copy, Paste, and Select All through UIKit menu actions.
- `paste(_:)` uses bracketed paste when the remote terminal enables it.
- `scrollUp(lines:)` and `scrollDown(lines:)` scroll local scrollback; `pageUp()`/`pageDown()` send paging keys when the terminal is in the alternate buffer.
- `allowMouseReporting` is the intended switch between sending touch/mouse events to the remote app and letting gestures select/scroll locally.
- `UITextInput` support handles composed input, dictation, emoji, and hardware keyboard special keys. We should preserve it.

## Priority 1: Terminal Interaction Polish

1. Replace custom single-finger scroll with a SwiftTerm-aligned mode:
   - Default: let SwiftTerm handle selection/copy/paste and local scrollback.
   - Agent mode: drag scrolls local scrollback when possible.
   - Mouse mode: pass gestures to Zellij for mouse-aware panes.
2. Keep tap-to-toggle keyboard, but avoid stealing taps that SwiftTerm uses for links, selection menus, and double/triple tap.
3. Expose a small "touch mode" setting mapped to `allowMouseReporting`, with clear states: Scroll, Select, Mouse.
4. Add a quick test checklist for keyboard shown/hidden, long-press copy, paste, double-tap word select, and scrollback.

## Priority 2: Agent UX

1. Add a compact command palette reachable from the profile/session menu:
   - `/resume`, `/fork`, `/memory`, `/compact`, `/clear`, `/help`
   - Codex shortcuts and common approvals.
2. Improve `PromptComposerView`:
   - Recent prompt search.
   - User snippets.
   - Send as bracketed paste, preserving multi-line formatting.
3. Add a lightweight "interrupt" affordance:
   - One-tap Esc.
   - Long-press for Ctrl-C / Ctrl-D.

## Priority 3: Reliability

1. Add structured connection logs in the app model:
   - login, version, session list, session create, control WS, terminal WS, close code.
2. Move startup retry policy into one small state machine:
   - one delayed startup attempt;
   - retry every 2 seconds for a small fixed count;
   - then return to session picker.
3. Add simulator tests for missing session, HTTP 401, typed close `4404`, cert trust, and reconnect after foreground.

## Priority 4: Performance

1. Test SwiftTerm's Metal renderer on device for long agent transcripts.
2. Keep terminal byte feeding as bytes, never string-decode terminal frames.
3. Coalesce resize sends during rotation/keyboard animation.
4. Cap local transcript buffers used outside SwiftTerm.

## Priority 5: Upgrade Compatibility

1. Keep Zellij Web protocol code isolated in `ZellijWebTransport`.
2. Continue tolerating unknown control messages and extra JSON fields.
3. Add captured fixture tests for:
   - login request shape;
   - `/sessions` legacy and status-aware responses;
   - `SetConfig`;
   - `QueryTerminalSize`;
   - session-not-found close `4404`.
4. Document the tested Zellij server versions in `ios/README.md`.

## Test Before Next TestFlight

- iPhone portrait and landscape on a real device.
- Keyboard tap toggle, hardware keyboard, and dictation.
- Long-press Copy/Paste and double-tap word selection.
- Scroll a long Claude/Codex response.
- Kill Wi-Fi or switch networks during a run and verify reconnect.
- Delete the selected Zellij session on Mac and verify the picker appears without recreating it.
