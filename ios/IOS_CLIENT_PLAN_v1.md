# Zellij iOS Client Plan

## Goal

Build a lightweight SwiftUI iOS client for remote access to Zellij sessions running on a Mac, optimized for Claude Code/Codex-style agent CLI workflows. The phone UI should not assume a hardware keyboard: common commands, session switching, prompt reuse, history search, interrupt/resume, and full-screen output review must be one or two taps away.

## Current Zellij Support

Zellij already exposes the right remote transport through the web client:

- `POST /command/login` exchanges an auth token for a `session_token` cookie.
- `POST /session` creates a `web_client_id`.
- `GET /ws/terminal` or `/ws/terminal/{session}` streams terminal ANSI output and accepts stdin bytes.
- `GET /ws/control` handles resize/config/log/session-control messages.

This means the iOS app should reuse the existing web protocol instead of implementing local Unix socket IPC or protobuf messages directly.

## Product Principles

- Treat the app as an agent console, not a generic terminal emulator.
- Keep terminal rendering fast and simple; put mobile ergonomics in native SwiftUI controls.
- Prefer tap, swipe, search, and predictive command entry over key chords.
- Cache recent sessions, prompts, and command history locally so the app feels instant.
- Preserve raw terminal compatibility: every shortcut ultimately sends bytes to the terminal socket.

## Must-Have Mobile Experience

- Fast session switcher: show saved Mac profiles, recent Zellij sessions, active agent labels, and connection state.
- Full-view mode: hide chrome, maximize terminal output, keep a floating command/input pill.
- Agent command bar: `/resume`, `/fork`, `/memory`, `/compact`, `/clear`, `/help`, Ctrl-C, Esc, Enter, Tab, arrow keys, and paste.
- Predictive command input: autocomplete slash commands, recent prompts, file/path fragments copied from output, and reusable snippets.
- Prompt composer: multi-line editor with templates, paste cleanup, send as bracketed paste, and optional “send Enter after paste”.
- Searchable history: search sent prompts, slash commands, and locally buffered terminal output.
- Output review mode: readable text-first view for long agent responses, with copy/share and jump back to live terminal.
- Reconnect that preserves local history and restores the last selected session.
- Secure by default: Keychain storage, TLS, Face ID/passcode gate option, and no public internet exposure guidance.

## MVP Architecture

Create a native SwiftUI app with these modules:

- `AuthClient`: stores server URL and auth token, logs in with `URLSession`, persists cookies/keychain credentials.
- `SessionClient`: calls `/session`, stores `web_client_id`, and tracks recent session URLs locally.
- `TerminalSocket`: uses `URLSessionWebSocketTask` for `/ws/terminal/{session}?web_client_id=...`.
- `ControlSocket`: connects to `/ws/control` and sends resize JSON.
- `TerminalBuffer`: appends streamed ANSI/text output, keeps a bounded searchable local scrollback, and feeds the renderer.
- `TerminalView`: native terminal surface using `SwiftTerm` for MVP. Use `WKWebView` only as a quick compatibility spike, not the target UI.
- `AgentToolbar`: compact, configurable controls for agent commands and terminal control keys.
- `PromptComposer`: multi-line input, snippets, command prediction, history search, and bracketed paste send.
- `SessionSwitcher`: recent sessions, pinned sessions, active connection status, and fast reconnect.

## Protocol Details

Login:

```http
POST /command/login
Content-Type: application/json

{"auth_token":"TOKEN","remember_me":true}
```

Create client:

```http
POST /session
```

Terminal websocket URL:

```text
wss://host:8082/ws/terminal/session-name?web_client_id=UUID
```

Control websocket URL:

```text
wss://host:8082/ws/control
```

Resize message:

```json
{
  "web_client_id": "UUID",
  "payload": {
    "type": "TerminalResize",
    "rows": 32,
    "cols": 100
  }
}
```

Shortcut buttons send plain terminal input:

```swift
terminalSocket.sendString("/resume\r")
terminalSocket.sendString("/fork\r")
terminalSocket.sendString("/memory\r")
terminalSocket.sendString("/compact\r")
terminalSocket.sendString("\u{3}")  // Ctrl-C
terminalSocket.sendString("\u{1b}") // Esc
```

For multi-line prompts, send bracketed paste so CLIs receive the text safely:

```swift
terminalSocket.sendString("\u{1b}[200~" + prompt + "\u{1b}[201~")
terminalSocket.sendString("\r")
```

The app should send text as UTF-8 websocket text or binary bytes. Zellij already parses both paths server-side.

## iOS Interaction Design

Main screen layout:

- Top compact bar: server/session name, reconnect state, session switch button.
- Terminal area: full-screen by default, pinch/step font size controls, tap to focus input.
- Bottom command pill: one-line quick input with autocomplete.
- Expandable composer: multi-line prompt editor with send, paste, history, and snippets.
- Horizontal shortcut strip: agent commands and control keys, customizable per user.

Gestures:

- Swipe left/right: switch recent agent sessions.
- Pull down: command/search palette.
- Long press output: copy, search from selection, create snippet.
- Two-finger tap: Esc.
- Three-finger tap or visible button: Ctrl-C.

Prediction should be local and deterministic in the MVP: slash command list, recent sent commands, snippets, and simple prefix matching. Do not require an LLM call for suggestions.

## Session Switching

MVP session switching can use saved URLs like:

```text
https://mac:8082/project-a-agent
https://mac:8082/project-b-agent
```

Because the current web API does not expose a session list endpoint, the first version should store and pin recent session names locally. A follow-up Zellij server change should add:

- `GET /api/sessions`: live sessions, connected clients, created time, optional current tab/pane title.
- `POST /api/session/{name}/attach`: create/return a `web_client_id` for a selected session.
- Optional active pane metadata so the iOS UI can label sessions as `codex`, `claude`, `shell`, etc.

## Mac Setup

Create an auth token:

```sh
zellij web --create-token --token-name ios-agent
```

Run the web server. Binding to a non-loopback IP requires TLS:

```sh
zellij web -d --ip 0.0.0.0 --port 8082 --cert cert.pem --key key.pem
```

Prefer Tailscale, VPN, or LAN-only access. Do not expose the server directly to the public internet.

## MVP Milestones

1. Build a minimal SwiftUI app that logs in and stores the session cookie.
2. Connect both websockets and display terminal output in `SwiftTerm`.
3. Send plain input, Ctrl-C, Esc, Enter, Tab, and bracketed paste.
4. Add fixed terminal sizing, font controls, and resize messages.
5. Add the agent command toolbar and full-view mode.
6. Add prompt composer with snippets, local prediction, and sent-prompt history.
7. Add session switcher with pinned/recent session URLs.
8. Add searchable local output buffer and review mode.
9. Add reconnect handling, Keychain storage, and Face ID/passcode gate option.
10. Package a simple TestFlight build for daily use.

## Later Enhancements

- Add a Zellij endpoint for listing sessions instead of requiring typed session URLs.
- Add structured pane/tab metadata for mobile navigation.
- Add server-side mobile command actions for pane focus, tab switch, and prompt paste.
- Add push notifications or background refresh for completed agent turns.
- Add a compact “review mode” that streams only the active pane text for reading output.
- Add iPad keyboard shortcuts and hardware keyboard passthrough after the phone UI is solid.
