# Zellij Agent iOS Next-Level Plan

## Goal

Move the iOS client from a usable beta to a dependable daily driver for Claude Code, Codex CLI, and long-running Zellij sessions on a Mac. Target score: 9/10 for personal use and TestFlight-ready for trusted users.

## Research Inputs

- SwiftTerm supports the features we should lean on instead of rebuilding: selection, scrollback APIs, bracketed paste, mouse reporting, hyperlinks, terminal search APIs, configurable scrollback, and optional Metal rendering. Source: https://github.com/migueldeicaza/SwiftTerm
- Blink Shell's strongest mobile-terminal ideas are full-screen-first UI, smart keys, pinch-to-zoom, swipe/tap shell switching, selection mode, and context/snippet access without permanent chrome. Source: https://docs.blink.sh/
- Termix-SSH Mobile is a useful open-source mobile-terminal reference. Its README calls out multi-session SSH tabs, a switchable system/custom terminal keyboard, configurable key layouts, snippets, background keepalive, VoiceOver, dictation, Bluetooth/physical keyboards, and emoji handling. Source: https://github.com/Termix-SSH/Mobile
- Termix server also reinforces browser-like terminal tabs, split-screen, customizable themes/fonts, snippets, command history, persistent tabs, and full-screen terminal routes. Source: https://github.com/Termix-SSH/Termix
- Zellij Web is the correct server foundation. It requires auth tokens, recommends HTTPS for network use, supports mobile viewport resize/touch scroll, read-only tokens, session resurrection, and web sharing. Source: https://zellij.dev/documentation/web-client.html

## Priority 1: Reliability And Recovery

1. Add a **Connection Doctor** screen in Settings:
   - Show server URL, version, HTTPS/cert status, token status, `/sessions` result, web sharing hint, last close code, and last 50 connection events.
   - Add copyable diagnostics for bug reports.
2. Add a **Session Recovery** flow:
   - If attach fails but session metadata exists, show: "Retry", "Create new", "Attach another", and "Recovery instructions".
   - Detect stale socket / exited-session states from server errors where possible; never silently recreate a missing saved session.
3. Improve lifecycle:
   - Debounce reconnects; first retry immediately, second retry after 2 seconds, then show picker.
   - Preserve terminal output while reconnecting instead of clearing on every connect attempt.
4. Add tests:
   - HTTP 401 token failure.
   - TLS untrusted / mismatch.
   - Missing session and server close 4404.
   - Legacy `[String]` sessions and current `{name,status}` sessions.
   - Network drop while picker is open.

## Priority 2: Mobile Terminal UX

1. Add **Focus Mode**:
   - Hide top bar after a delay.
   - Single tap toggles keyboard only when configured; two-finger swipe still works.
   - Small edge handle restores controls.
2. Add **Pinch Font Zoom**:
   - Match Blink's pinch-to-resize behavior.
   - Resize terminal only after pinch ends or after a short debounce.
3. Finalize **Touch Modes**:
   - Scroll: one-finger scrollback, long-press selection still available.
   - Select: SwiftTerm selection gestures take priority.
   - Mouse: forward taps/pans to remote apps.
   - Expose current mode in a compact menu, not buried only in Settings.
4. Improve copy/search:
   - Use SwiftTerm selection APIs for copy, select all, clear selection.
   - Long-press menu must expose Paste, Copy, Select, Select All, and Copy Screen where applicable.
   - Selection drag should auto-scroll near terminal edges.
   - Add transcript search using SwiftTerm/local buffer where possible.
   - Add "Copy visible screen" and "Copy last agent reply".
5. Add a **Configurable Terminal Keyboard Layer**:
   - Keep the iOS system keyboard as the default typing surface.
   - Add a user-editable accessory row for Esc, Tab, Ctrl-C, Ctrl-D, arrows, slash, pipe, tilde, paste, and snippets.
   - Support Bluetooth/hardware keyboard shortcuts without showing touch controls.
   - Confirm dictation, emoji, and VoiceOver do not break terminal input.

## Priority 3: Agent Workflow

1. Add an **Agent Command Palette**:
   - Claude: `/resume`, `/fork`, `/memory`, `/compact`, `/clear`, `/help`, `/cost`, `/model`.
   - Codex: configurable snippets, not hard-coded guesses.
   - Send via bracketed paste.
2. Upgrade **Prompt Composer**:
   - Snippet add/edit/delete.
   - Search prompt history.
   - "Send", "Paste only", and "Append Enter" modes.
   - Local-only prediction from recent commands and snippets.
3. Add **Approval Buttons**:
   - Detect common approval prompts visually from recent output.
   - Offer quick `y`, `n`, Esc, Ctrl-C buttons in a temporary bottom strip.
4. Add **Session Switcher**:
   - Fast switch between Zellij sessions.
   - Pin favorite agent sessions.
   - Show status: Live, Saved, Available, Read-only.
   - Treat session tabs like Termix-style first-class navigation, not only a settings sheet.

## Priority 4: Zellij-Native Integration

1. Keep the protocol layer isolated in `ZellijWebTransport`.
2. Add capability detection:
   - Server version.
   - Session status support.
   - Read-only token support.
   - Future mobile actions support.
3. Investigate lightweight server additions after app UX stabilizes:
   - Mobile action endpoint for tab switch, pane focus, resize, and paste.
   - Structured tab metadata so iOS can switch tabs without parsing terminal pixels.
4. Document multi-client sizing:
   - Shared Mac+iPhone attachment uses the smaller visible grid.
   - Recommend phone-specific agent sessions for clean output.

## Priority 5: Performance

1. Enable SwiftTerm Metal renderer behind a setting, then default it on after real-device testing.
2. Debounce terminal resize sends by about 150 ms during keyboard, rotation, and pinch zoom.
3. Make scrollback size configurable: 5k, 20k, 100k lines.
4. Preserve background sessions:
   - Keep the WebSocket alive when iOS allows it.
   - On suspend/resume, reconnect quietly without clearing terminal output.
   - Show clear state when iOS background limits force a disconnect.
5. Add lightweight performance telemetry in diagnostics:
   - Terminal bytes received.
   - Render chunks drained.
   - Reconnect count.
   - Memory warning count.

## Priority 6: Security And Admin

1. Token management:
   - Show token present/missing/rejected state.
   - Add "Replace token" without recreating profile.
2. Certificate trust:
   - Keep SPKI pinning.
   - Improve mismatch language and show short fingerprints.
3. Read-only mode:
   - Make read-only profiles obvious.
   - Disable input paths and composer.

## TestFlight Gate

- Real iPhone portrait and landscape.
- iPad split view.
- Hardware keyboard attached.
- Network switch Wi-Fi to cellular 50 times.
- Long Claude/Codex response with scrollback and copy.
- Kill/restart Zellij web server.
- Delete selected session on Mac and confirm app does not recreate it silently.
- Attach to legacy server and patched server.
- Verify no app crash after replacing server certificate or token.

## Recommended Build Order

1. Resize debounce, preserve output during reconnect, and recovery diagnostics.
2. Focus Mode and pinch font zoom.
3. Command palette and snippet editor.
4. Session switcher polish.
5. Copy/search/selection improvements.
6. Metal renderer and performance diagnostics.
7. Capability detection and server-side mobile actions.
