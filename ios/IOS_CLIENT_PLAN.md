# Zellij iOS Client Plan (Final Lean Core)

## Goal

A small SwiftUI app that remote-attaches an iPhone/iPad to Zellij sessions running on a Mac, so Claude Code or Codex CLI agents are usable on the go. Parity bar: switch agent sessions, type or paste a prompt, watch the agent run, interrupt with Esc/Ctrl-C, answer approvals, search recent prompts, and reconnect quickly. Keep v1 lightweight: one terminal, one active session, no server changes.

## Non-goals (explicitly cut)

- No push notifications, no Live Activities, no Dynamic Island.
- No companion Mac daemon, no Zellij plugin, no `/api/sessions` server changes.
- No voice dictation, file pickers, share extension, transcript review mode, or LLM-powered suggestions.
- No iPad-specific multi-pane UI. iPad just runs the iPhone layout bigger.

These are all worth doing later. They are not the core. The core is "open app → choose agent session → see agent → send prompt → see reply".

## Phone-first must-haves

- Fast session switcher for pinned/recent named sessions such as `proj-a`, `proj-b`, and `codex-zellij`.
- Full-view terminal mode with minimal chrome and a floating input/command pill.
- Shortcut row for keys that iOS lacks: Esc, Tab, sticky Ctrl, arrows, slash, pipe, tilde, Enter.
- Multi-line prompt composer that sends bracketed paste safely.
- Local prompt history and simple prefix search.
- Local deterministic prediction: slash commands, recent prompts, and user snippets. No network/LLM dependency.
- Reconnect on app foreground/path change without making the user re-enter credentials.

## Server side (Mac, no code changes)

```sh
# one-time
zellij web --create-token --token-name ios

# launch (LAN/Tailscale only, never public internet)
zellij web -d --ip 0.0.0.0 --port 8082 --cert cert.pem --key key.pem
```

Run agents inside named Zellij sessions, one per project:

```sh
zellij attach --create proj-a    # then run `claude` or `codex` in a pane
```

Recommended: Tailscale for transport. Self-signed cert is fine; iOS pins it (see Security).

## Wire protocol (already in tree, don't reinvent)

Endpoints in `zellij-client/src/web_client/`:

- `POST /command/login` — body `{"auth_token","remember_me":true}` → sets `session_token` cookie.
- `POST /session` — returns `{web_client_id, is_read_only}`.
- `GET /info/version` — returns the Zellij version; use this for compatibility checks and diagnostics.
- `GET /ws/control` — JSON control plane.
- `GET /ws/terminal/{session}?web_client_id=UUID` — bidirectional bytes (text or binary frames, both directions).

Control envelope:

```json
{ "web_client_id": "...", "payload": { "type": "TerminalResize", "rows": 32, "cols": 100 } }
```

Server → client control variants the app must at minimum tolerate (defined in `control_message.rs`):

- `SetConfig` — first frame; carries font/theme/`mac_option_is_meta`. App may ignore in v1 except `mac_option_is_meta` for keyboard mapping.
- `QueryTerminalSize` — reply with current `TerminalResize`.
- `SwitchedSession` — update titlebar.
- `Log` / `LogError` — drop in v1 (or write to console).

Bring-up order matters: open the control socket first and wait for the initial `SetConfig` frame before terminal bytes start flowing. Send `TerminalResize` after `/session` returns a `web_client_id`; the current client sends it immediately after terminal websocket attachment and retries on `QueryTerminalSize`.

## Upgrade compatibility

Design the iOS app as a small adapter over Zellij's public web surface, so upgrading the Mac's Zellij binary is low-risk:

- Check `GET /info/version` on every connection and show it in diagnostics/settings.
- Keep all protocol code behind `ZellijWebTransport`, not scattered through views.
- Treat unknown control JSON variants as non-fatal logs. Do not crash when newer Zellij adds messages.
- Ignore extra JSON fields in known messages and only require `web_client_id`, `is_read_only`, `rows`, and `cols`.
- Prefer terminal byte passthrough over structured Zellij actions. Terminal bytes are the most stable contract.
- Keep slash-command prediction fully client-side and configurable because Claude Code/Codex command sets change independently from Zellij.
- Add a tiny compatibility test suite with captured sample frames for login, session creation, `SetConfig`, `QueryTerminalSize`, and terminal text frames.
- Gate future server-only features, such as `/api/sessions`, behind capability detection. If the endpoint is absent, fall back to local pinned sessions.
- Maintain a migration path for local settings: version the saved profile JSON, and never store protocol assumptions only in UI code.

## App architecture

One screen, one active connection, small native types. All Swift, no UIKit beyond what SwiftTerm needs.

```
ZellijClient        // login, /session, owns cookies
ZellijWebTransport  // version check, endpoint paths, JSON compatibility layer
ControlSocket       // JSON in/out, resize + SetConfig handling
TerminalSocket      // raw bytes, feeds SwiftTerm
TerminalView        // SwiftTerm.TerminalView wrapped in UIViewRepresentable
ShortcutBar         // Esc, Tab, sticky Ctrl, ↑↓←→, slash, |, ~, Enter
PromptComposer      // multiline paste, snippets, prompt history, local prediction
SessionSwitcher     // pinned/recent session names; no server API needed in v1
RootView            // server picker + switcher + terminal + composer
```

Storage: Keychain for `auth_token` and base URL. `UserDefaults` or a small local JSON file for pinned sessions, prompt history, snippets, and font size. No database. No history sync.

Dependencies: `SwiftTerm` (SPM, MIT). Nothing else.

Deployment target: iOS 16 minimum. This keeps `URLSessionWebSocketTask`, `NWPathMonitor`, `scenePhase`, and `TextEditor` behavior on a modern baseline.

## Connection lifecycle

```
launch → load token from Keychain
       → POST /command/login                 (fail → settings sheet)
       → POST /session → web_client_id, is_read_only
       → open /ws/control                    (cookie attached via shared HTTPCookieStorage)
       → receive SetConfig, apply font/theme where useful
       → open /ws/terminal/{session}?web_client_id=...
       → send first TerminalResize on control WS
       → render terminal bytes in SwiftTerm
       → stream
```

Open the control websocket first because the server sends `SetConfig` immediately on control upgrade, before reading any client message. Applying font/theme before terminal bytes arrive prevents a visible restyle flash and avoids computing the first resize from default font metrics. Retry resize on `QueryTerminalSize` and after first terminal data as a harmless safety net.

Reconnect: on WS close or `NWPathMonitor` change, throw away the `web_client_id`, re-run from `/session`. Do not attempt to reuse stale IDs. Show a thin "reconnecting" bar; keep the input UI visible, but queue only composer text locally and do not send keystrokes while disconnected.

Backgrounding: WSs die when iOS suspends the app. On `scenePhase == .active` reconnect. No background task — keep it simple, accept the 1-second reconnect.

## Input

SwiftTerm handles the textual keyboard. The app adds a single horizontal shortcut row above the system keyboard:

```
[Esc] [Tab] [Ctrl] [↑] [↓] [←] [→] [/] [|] [~] [⏎]
```

`Ctrl` is sticky for one keypress; combined with the next letter sends the control byte. That covers `Ctrl-C`, `Ctrl-D`, `Ctrl-R`, `Ctrl-L`.

Multi-line prompt entry: a small expand-button opens a sheet with a `TextEditor`. Tap "Send" to transmit as bracketed paste:

```swift
"\u{1b}[200~" + text + "\u{1b}[201~\r"
```

Add a lightweight prediction strip above the composer:

- built-in slash commands: `/help`, `/clear`, `/compact`, `/resume`, `/fork`, `/memory`, `/cost`, `/model`;
- recent sent prompts, matched by prefix;
- user-defined snippets, stored locally.

This is deterministic local filtering, not an AI feature.

Read-only sessions (`is_read_only == true` from `/session`): hide shortcut bar and composer; render-only.

## Session switching

There is no session-list endpoint today, so v1 should use local pinned/recent session names. The user can add sessions manually:

```text
proj-a
proj-b
zellij-ios-test
```

Switching sessions means closing the current websockets, calling `/session` for a fresh `web_client_id`, then opening `/ws/terminal/{session}` and `/ws/control`. For writable tokens, `/ws/terminal/{session}` can create a missing Zellij session; read-only tokens can only attach to existing sessions.

## Resize policy

Send `TerminalResize` whenever:

- WSs first connect.
- Keyboard appears/disappears (`keyboardWillChange` notification).
- Device rotates.
- User pinches to change font size.

Compute cols/rows from SwiftTerm's reported cell size and the visible content area. Claude Code and Codex render OK down to ~70 cols on a phone in landscape with a 10pt font. In portrait, accept that the UI will wrap; do not fake the size.

## Security (small but non-negotiable)

- Auth token in Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- TLS: certificate pinning via `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`. On first connect, show the cert fingerprint and ask the user to trust. Store the SPKI hash; reject mismatch on later connects. This handles self-signed certs without `allowArbitraryLoads`.
- Same `URLSession` instance for HTTP and WebSocket so the `session_token` cookie auto-attaches to `/ws/...`.
- No background refresh of credentials. No analytics. No third-party SDKs.

## Out-of-the-box agent UX (free, no extra code)

Because the app is a faithful pipe, these work the moment the connection is up:

- Slash commands (`/help`, `/clear`, `/compact`, `/resume`, `/fork`, `/memory`, `/cost`, `/model`).
- `@`-file references in CC (typed manually).
- Tool-approval prompts (the `y`/`n` keys are on the keyboard; `Esc` is on the shortcut bar).
- Streaming output, true-color, emoji.
- Bracketed paste for multi-line.

That is exactly the v1 promise: parity, not augmentation.

## Milestones

1. SwiftUI app skeleton, settings sheet (host + token), Keychain.
2. Login + `/session` + cookie wiring with cert pinning prompt.
3. Control + terminal WSs; SwiftTerm rendering streamed bytes.
4. Resize on first connect, rotation, keyboard, font change.
5. Shortcut bar with sticky Ctrl.
6. Bracketed-paste composer sheet.
7. Local prompt history, prefix search, and deterministic prediction strip.
8. Pinned/recent session switcher.
9. Reconnect on path change and scene activation. Stress test Wi-Fi/cellular drops by killing the network mid-session repeatedly and watching Mac memory, because unclean websocket drops may leave old `web_client_id` entries server-side.
10. Read-only handling.
11. TestFlight build for self-use.

Estimate: 1 focused week to a usable build; 1.5 weeks if SwiftTerm integration or certificate pinning takes longer than expected.

## Later (only if v1 is not enough)

- Slash-command quick-pick row (purely client-side).
- Rich transcript review mode.
- Push notifications when the agent finishes (requires a small Mac helper + APNs key).
- File picker via a companion HTTP endpoint.
- Live Activity for "agent running".
- Zellij session-list endpoint with active pane metadata.

None of these are needed to ship a useful core.

## Resolved implementation assumptions

- `/ws/terminal/{session}` creates a missing session for writable clients because `zellij_server_listener` calls `spawn_session_if_needed` when the session does not exist. Read-only clients cannot create sessions.
- Always call `/session` again on reconnect or session switch. The server removes clients on clean terminal close and stale IDs are not worth preserving.
- `TerminalResize` uses plain integer `rows` and `cols`, matching `Size { rows: usize, cols: usize }`.
