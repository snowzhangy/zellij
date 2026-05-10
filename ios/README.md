# Zellij Agent iOS

This folder contains the first native iOS client scaffold for using a Zellij-hosted Claude Code or Codex CLI session from iPhone/iPad.

## Build

Generate the Xcode project from the checked-in XcodeGen spec:

```sh
cd ios
xcodegen generate
xcodebuild -project ZellijAgent.xcodeproj -scheme ZellijAgent -destination 'generic/platform=iOS Simulator' build
```

Run unit tests:

```sh
xcodebuild -project ZellijAgent.xcodeproj -scheme ZellijAgent -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Mac Setup

Create an auth token:

```sh
zellij web --create-token --token-name ios
```

Start the web server on a private network or Tailscale:

```sh
zellij web -d --ip 0.0.0.0 --port 8082 --cert cert.pem --key key.pem
```

Use one named Zellij session per agent/project:

```sh
zellij attach --create proj-a
```

## Current Scope

Implemented:

- HTTP login, version check, `/session`, control websocket, terminal websocket.
- Authenticated `/sessions` lookup before terminal attach, showing live and saved-resurrectable sessions while preventing stale deleted names from silently recreating sessions.
- Control-first connection order so `SetConfig` arrives before terminal output.
- SwiftTerm-backed terminal rendering with queued byte chunks and raw byte input passthrough.
- SwiftTerm-reported terminal resizing; no geometry-based fallback resize spam.
- Resize JSON, login JSON, session response, ANSI sanitizer, stream queue, and control-message tests.
- Keychain token storage and local JSON settings.
- Pinned/recent profile model, attach/create session picker, sheet-based prompt composer, keyboard hide control, local prompt history, and deterministic suggestions.
- Trust-on-first-use certificate prompt before login proceeds, persisted SPKI pin, readable fingerprints, and mismatch re-trust flow.
- `mac_option_is_meta` from Zellij `SetConfig` applied to SwiftTerm keyboard behavior.

Not yet implemented:

- Live validation against a Mac `zellij web` server from a physical iPhone.
